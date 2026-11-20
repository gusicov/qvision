import Foundation
import Observation
import RealityKit
import SwiftUI
import simd
import UniformTypeIdentifiers

/// The single app state object. Owns the stage, hand tracking and fly controller,
/// and persists every project mutation through `ProjectStore`.
///
/// v0.7 additions:
/// - Undo / Redo: snapshot history of the project's undoable state (items, layers, scene
///   scale), max 50, slider drags and two-handed gestures coalesced.
/// - Back / Forward: history of *places* (worldRoot poses): Recenter, the end of every fly
///   session and every camera jump record one.
/// - App flow: opening / leaving a project is serialized (one transition at a time), the
///   immersive space follows `currentProject`, and closing the last window leaves the project.
@MainActor
@Observable
final class AppModel {
    static let mainWindowID = "main"
    static let stageSpaceID = "stage"
    static let layersWindowID = "layers"
    static let inspectorWindowID = "inspector"
    /// The project panel: a real visionOS window (system move bar), opened from the palm button.
    static let panelWindowID = "panel"
    /// v0.8: the Rendered viewer (one baked scene, unlit, full immersion).
    static let renderedSpaceID = "rendered"

    /// The tabs of Home (v0.8 R1).
    enum HomeTab: String, Hashable {
        case projects, rendered, server, settings
    }

    /// v0.9 B1: the last thing opened, for the Continue card on Home.
    struct LastOpened: Codable, Equatable {
        enum Kind: String, Codable {
            case project, rendered, server
        }
        var kind: Kind
        /// Project UUID string, rendered scene id (folder name) or server UUID string.
        var id: String
        var title: String
        var date: Date
    }

    private static let homeTabKey = "qvision.homeTab"
    private static let lastOpenedKey = "qvision.lastOpened"
    private static let comfortVignetteKey = "qvision.comfortVignette"

    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.usdz, .usd, .realityFile]
        for ext in ["usda", "usdc", "obj"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()

    static let supportedExtensions: Set<String> = ["usdz", "usd", "usda", "usdc", "reality", "obj"]

    /// Files bigger than this get the "Large model" hint when they fail to load.
    private static let largeModelBytes: Int64 = 50_000_000

    /// Fly speed multiplier range (L3).
    static let flySpeedRange: ClosedRange<Float> = 0.25...10
    private static let flySpeedDefaultsKey = "qvision.flySpeed"

    /// Undo / place history depth.
    private static let maxHistory = 50

    enum StageState { case closed, transitioning, open }
    var stageState: StageState = .closed

    private(set) var projects: [Project] = []
    private(set) var currentProject: Project? = nil

    var selectedItemID: UUID? = nil {
        didSet {
            stage.setSelected(selectedItemID)
            if selectedItemID == nil {
                selectedPartID = nil
                inspection = nil
            }
        }
    }

    var isLoading: Bool = false
    var lastError: String? = nil

    var viewMode: ViewMode {
        get { currentProject?.viewMode ?? .mixed }
        set {
            guard let project = currentProject, project.viewMode != newValue else { return }
            mutate(undo: .skip) { $0.viewMode = newValue }
            stage.setEnvironment(environment, mode: newValue)
        }
    }

    var environment: EnvironmentPreset {
        get { currentProject?.environment ?? .studio }
        set {
            guard let project = currentProject, project.environment != newValue else { return }
            mutate(undo: .skip) { $0.environment = newValue }
            stage.setEnvironment(newValue, mode: viewMode)
        }
    }

    /// While fly mode is on, models are never hit-testable (clenched fists trigger the system
    /// pinch, which would otherwise grab whatever model is under the hands).
    var isFlyModeEnabled: Bool = false {
        didSet {
            fly.isEnabled = isFlyModeEnabled
            guard oldValue != isFlyModeEnabled else { return }
            applyInteractionToStage()
            if isFlyModeEnabled {
                recordPlace()
                startFlyWatch()
            } else {
                stopFlyWatch()
                // cancelFlight stopped the motion: wherever we are now is a place.
                recordPlace()
            }
        }
    }

    // MARK: v0.3 state

    /// View = locked (models can't be targeted). Edit = move / scale / rotate.
    /// Inspect = nothing moves, tap shows information. Every project opens in View.
    var interactionMode: InteractionMode = .view {
        didSet {
            guard oldValue != interactionMode else { return }
            applyInteractionToStage()
            selectedPartID = nil
            if interactionMode == .inspect, let id = selectedItemID {
                // Something is already selected: show it right away.
                inspection = stage.inspect(itemID: id, partID: nil)
            } else {
                inspection = nil
            }
        }
    }

    /// Whole-project scene scale in percent (1...100, 100 = real size). Applied to the stage
    /// immediately; persisted with a short debounce so dragging the slider stays cheap.
    /// Undoable; a whole slider drag is one undo step.
    var sceneScalePercent: Double {
        get { currentProject?.scenePercent ?? 100 }
        set {
            guard let project = currentProject else { return }
            let clamped = min(max(newValue, 1), 100)
            guard clamped != project.scenePercent else { return }
            mutateDeferred(undo: .record(key: "sceneScale", window: 1.5)) { $0.sceneScalePercent = clamped }
            applySceneScale()
        }
    }

    /// Lift scaled content to table height (only has an effect below 100 %).
    var isTabletop: Bool {
        get { currentProject?.tabletop ?? false }
        set {
            guard let project = currentProject, project.tabletop != newValue else { return }
            mutateDeferred(undo: .record(key: nil, window: 0)) { $0.isTabletop = newValue }
            applySceneScale()
        }
    }

    /// Magnetic floor while dragging (default on). A preference, not undoable.
    var snapToFloor: Bool {
        get { currentProject?.snapsToFloor ?? true }
        set {
            guard let project = currentProject, project.snapsToFloor != newValue else { return }
            mutate(undo: .skip) { $0.snapToFloor = newValue }
        }
    }

    /// Fly speed multiplier, 0.25...10 (L3). Remembered across launches.
    var flySpeed: Float = 1 {
        didSet {
            let clamped = Self.clampFlySpeed(flySpeed)
            fly.speed = clamped
            UserDefaults.standard.set(Double(clamped), forKey: Self.flySpeedDefaultsKey)
        }
    }

    /// The project panel window is open. Maintained by ProjectPanelWindowView
    /// (onAppear / onDisappear); the palm button opens/dismisses that window.
    var isProjectPanelVisible: Bool = false

    /// Maintained by the window roots (onAppear / onDisappear).
    var isLayersWindowOpen: Bool = false
    var isInspectorWindowOpen: Bool = false
    /// Maintained by RootView (onAppear / onDisappear). Used to avoid opening a second main window.
    var isMainWindowOpen: Bool = false

    /// Set by the hand panel's "Import models" button; RootView (main window) presents the file
    /// picker and clears it. File pickers are presented from a window, not from the immersive
    /// space's attachments.
    var isImportPickerRequested: Bool = false

    /// The project id for which RootView already handed off from the main window to the hand
    /// panel (so it dismisses the main window only once per project open).
    @ObservationIgnored var mainWindowHandedOffProjectID: UUID? = nil

    private(set) var inspection: InspectionInfo? = nil
    private(set) var selectedPartID: String? = nil

    /// Human-readable status while importing / loading, nil otherwise.
    var importProgress: String? = nil

    // MARK: v0.7 state

    /// One unit-detection note per imported item (L2 banner), newest last.
    struct ImportNote: Identifiable, Equatable {
        let id = UUID()
        let itemID: UUID
        let itemName: String
        let text: String
    }

    private(set) var importNotes: [ImportNote] = []

    /// Undo / redo stacks: snapshots of the whole project (only the undoable parts are restored).
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    /// true while an undo / redo re-adds models to the stage (async).
    private(set) var isRestoringHistory = false
    @ObservationIgnored private var lastUndoKey: String? = nil
    @ObservationIgnored private var lastUndoTime: TimeInterval = 0

    var canUndo: Bool { currentProject != nil && !undoStack.isEmpty && !isRestoringHistory && !isLoading }
    var canRedo: Bool { currentProject != nil && !redoStack.isEmpty && !isRestoringHistory && !isLoading }

    /// Back / Forward: visited places (worldRoot transforms) and the current position in them.
    private(set) var placeHistory: [StoredTransform] = []
    private(set) var placeIndex: Int = 0
    @ObservationIgnored private var isAnimatingPlace = false
    @ObservationIgnored private var placeAnimationToken = 0
    /// History index recorded when the last fly grab ended (amended once the glide settles).
    @ObservationIgnored private var releaseRecordIndex: Int? = nil
    @ObservationIgnored private var flyWatchTask: Task<Void, Never>? = nil

    var canGoBack: Bool { currentProject != nil && placeIndex > 0 }
    var canGoForward: Bool { currentProject != nil && placeIndex < placeHistory.count - 1 }

    /// Number of open / leave / stage transitions queued or running. While > 0, project cards
    /// and Leave are disabled and the "no project" windows don't redirect themselves.
    private(set) var pendingTransitions: Int = 0
    var isTransitioning: Bool { pendingTransitions > 0 }
    /// The project being opened (Home shows a spinner on its card).
    private(set) var openingProjectID: UUID? = nil

    @ObservationIgnored let stage: StageController
    @ObservationIgnored let hands: HandTrackingService
    @ObservationIgnored let fly: FlyController

    // MARK: v0.8 state (Rendered mode)

    /// Selected Home tab. Leaving a rendered scene comes back to `.rendered`.
    /// v0.9 B2: remembered, so Home opens on the tab used last.
    var homeTab: HomeTab = .projects {
        didSet {
            guard oldValue != homeTab else { return }
            UserDefaults.standard.set(homeTab.rawValue, forKey: Self.homeTabKey)
        }
    }

    /// v0.9 B1: what the Continue card reopens (nil = nothing opened yet).
    private(set) var lastOpened: LastOpened? = nil

    /// v0.9 D4: soft vignette while flying fast (comfort). Default on; toggle in Settings.
    var comfortVignette: Bool = true {
        didSet { UserDefaults.standard.set(comfortVignette, forKey: Self.comfortVignetteKey) }
    }

    /// The baked-scene viewer (observable itself: phase, speed).
    @ObservationIgnored let rendered: RenderedViewer
    /// The "rendered" ImmersiveSpace, kept in sync by the serialized flow like `stageState`.
    var renderedState: StageState = .closed
    /// The scene the rendered space shows; nil = not in Rendered mode.
    private(set) var currentRenderedScene: RenderedScene? = nil
    /// The scene id for which RootView already handed off (dismissed) the main window.
    @ObservationIgnored var renderedHandedOffSceneID: String? = nil
    /// Server mode, so the flow can end a stream before opening another immersive space
    /// (only one ImmersiveSpace can be open). Set by RootView.
    @ObservationIgnored private weak var server: ServerSessionController? = nil

    @ObservationIgnored private let store = ProjectStore()
    @ObservationIgnored private var pendingSave: Task<Void, Never>? = nil

    // App flow plumbing.
    @ObservationIgnored private var sceneActions: SceneActions? = nil
    @ObservationIgnored private var flowTail: Task<Void, Never>? = nil
    @ObservationIgnored private var mainDismissExpectedUntil: TimeInterval = 0
    @ObservationIgnored private var panelDismissExpectedUntil: TimeInterval = 0
    /// Bumped by every project open / close; a project load only finishes for its own token.
    @ObservationIgnored private var loadToken = 0

    init() {
        let handService = HandTrackingService()
        self.stage = StageController()
        self.hands = handService
        self.fly = FlyController(hands: handService)
        self.rendered = RenderedViewer(hands: handService)
        self.projects = store.loadAll()

        let stored = UserDefaults.standard.object(forKey: Self.flySpeedDefaultsKey) as? Double
        let speed = Self.clampFlySpeed(Float(stored ?? 1))
        self.flySpeed = speed
        self.fly.speed = speed

        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.homeTabKey), let tab = HomeTab(rawValue: raw), tab != .settings {
            self.homeTab = tab
        }
        if let data = defaults.data(forKey: Self.lastOpenedKey),
           let record = try? JSONDecoder().decode(LastOpened.self, from: data) {
            self.lastOpened = record
        }
        self.comfortVignette = (defaults.object(forKey: Self.comfortVignetteKey) as? Bool) ?? true
        applyInteractionToStage()
    }

    // MARK: - Continue (v0.9 B1)

    /// Records what was opened last (persisted) for the Continue card.
    func noteOpened(_ kind: LastOpened.Kind, id: String, title: String) {
        let record = LastOpened(kind: kind, id: id, title: title, date: Date())
        lastOpened = record
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: Self.lastOpenedKey)
        }
    }

    func clearLastOpened() {
        lastOpened = nil
        UserDefaults.standard.removeObject(forKey: Self.lastOpenedKey)
    }

    // MARK: - Projects

    @discardableResult
    func createProject(named name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project.new(name: trimmed.isEmpty ? "Project \(projects.count + 1)" : trimmed)
        persist(project)
        upsert(project)
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateProject(id) { $0.name = trimmed }
    }

    func duplicateProject(_ id: UUID) {
        if currentProject?.id == id { flushPendingSave() }
        guard let source = (currentProject?.id == id ? currentProject : nil)
                ?? projects.first(where: { $0.id == id }) else { return }
        do {
            let copy = try store.duplicate(source)
            upsert(copy)
        } catch {
            lastError = "Couldn't duplicate “\(source.name)”: \(error.localizedDescription)"
        }
    }

    func deleteProject(_ id: UUID) {
        if currentProject?.id == id {
            closeProject()
            requestStageSync()
        }
        do {
            try store.delete(id: id)
        } catch {
            lastError = "Couldn't delete the project: \(error.localizedDescription)"
        }
        projects.removeAll { $0.id == id }
        if lastOpened?.kind == .project, lastOpened?.id == id.uuidString {
            clearLastOpened()
        }
    }

    /// Opens a project (serialized with every other open / leave) and the stage with it.
    /// Opening the project that is already open just makes sure the stage is open.
    func requestOpenProject(_ id: UUID) {
        enqueueFlow { [weak self] in
            await self?.performOpen(id)
        }
    }

    /// Async form of `requestOpenProject`: returns once the project is loaded.
    func openProject(_ id: UUID) async {
        await enqueueFlow { [weak self] in
            await self?.performOpen(id)
        }.value
    }

    /// Saves and closes the open project (synchronous part only: the stage space is closed by
    /// the flow that called this, or by `requestStageSync`).
    func closeProject() {
        isFlyModeEnabled = false
        interactionMode = .view
        pendingSave?.cancel()
        pendingSave = nil
        if let project = currentProject {
            persist(project)
            upsert(project)
        }
        selectedItemID = nil
        selectedPartID = nil
        inspection = nil
        importProgress = nil
        importNotes = []
        isProjectPanelVisible = false
        isImportPickerRequested = false
        mainWindowHandedOffProjectID = nil
        stage.clear()
        // v0.9 audit M1: environments (sky, floor, IBL textures) don't outlive the project.
        stage.releaseEnvironments()
        fly.resetOffset(worldRoot: stage.worldRoot)
        resetHistories()
        // Cancels a running project load (its completion is ignored).
        loadToken += 1
        isLoading = false
        openingProjectID = nil
        currentProject = nil
    }

    // MARK: - Items

    func importAssets(_ urls: [URL]) async {
        guard let project = currentProject, !urls.isEmpty else { return }

        isLoading = true
        defer {
            isLoading = false
            importProgress = nil
        }

        let assetsFolder = store.assetsFolder(for: project)
        var errors: [String] = []
        var slot = 0
        // One undo step for the whole batch.
        let batchKey = "import:\(UUID().uuidString)"

        for url in urls {
            // Stop if the project was closed or switched while we were awaiting.
            guard currentProject?.id == project.id else { break }

            let displayName = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else {
                errors.append("“\(displayName)” isn't a supported format (USDZ, USD, Reality or OBJ).")
                continue
            }

            // 1. Copy (coordinated read, so iCloud files download first), off the main actor.
            let sourceBytes = ProjectStore.fileSize(of: url)
            if let sourceBytes = sourceBytes, sourceBytes > 0 {
                importProgress = "Copying \(displayName) (\(DisplayFormat.megabytes(sourceBytes)) MB)…"
            } else {
                importProgress = "Copying \(displayName)…"
            }

            let imported: ImportedAsset
            do {
                imported = try await Task.detached(priority: .userInitiated) {
                    try ProjectStore.importAsset(from: url, intoAssetsFolder: assetsFolder)
                }.value
            } catch {
                errors.append("“\(displayName)” couldn't be copied into the project: \(Self.reason(for: error))")
                continue
            }

            guard currentProject?.id == project.id else {
                ProjectStore.removeImportedAsset(imported.fileName, from: assetsFolder)
                break
            }

            // 2. Load and place (bottom on the floor, units auto-detected by the stage).
            let totalBytes = max(imported.byteSize, sourceBytes ?? 0)
            importProgress = "Loading \(displayName)…"
            let fileURL = assetsFolder.appendingPathComponent(imported.fileName, isDirectory: false)

            var item = ProjectItem(
                name: url.deletingPathExtension().lastPathComponent,
                assetFileName: imported.fileName,
                layerID: currentProject?.defaultLayerID ?? project.defaultLayerID
            )

            do {
                let placement = stage.placementPoint(devicePose: hands.devicePose(), slot: slot)
                let t = try await stage.addItem(item, assetURL: fileURL, freshPlacement: true, placement: placement)

                guard currentProject?.id == project.id else {
                    stage.removeItem(item.id)
                    break
                }

                // L2: the reload never re-detects, so the detected factor must be stored.
                item.unitScale = stage.lastImportUnitScale
                item.transform = StoredTransform(t)
                item.initialTransform = StoredTransform(t)
                let newItem = item
                mutate(undo: .record(key: batchKey, window: .infinity)) { $0.items.append(newItem) }
                if let note = stage.lastImportUnitNote, !note.isEmpty {
                    addImportNote(ImportNote(itemID: newItem.id, itemName: newItem.name, text: note))
                }
                slot += 1
            } catch is CancellationError {
                // The project was closed while the model was loading: nothing to report.
                ProjectStore.removeImportedAsset(imported.fileName, from: assetsFolder)
                break
            } catch {
                ProjectStore.removeImportedAsset(imported.fileName, from: assetsFolder)
                var message = "“\(displayName)” couldn't be loaded: \(Self.reason(for: error))"
                if totalBytes > Self.largeModelBytes {
                    message += " Large model: try a smaller texture size or split the model."
                }
                errors.append(message)
            }
        }

        pushLayersToStage()

        if !errors.isEmpty, currentProject?.id == project.id {
            let title = (urls.count == 1) ? "The file couldn't be imported." : "Some files couldn't be imported."
            lastError = title + "\n" + errors.joined(separator: "\n")
        }
    }

    func addTestCube() async {
        guard let project = currentProject else { return }

        isLoading = true
        defer { isLoading = false }

        let cubeCount = project.items.filter { $0.primitive == .cube }.count
        var item = ProjectItem(
            name: "Cube \(cubeCount + 1)",
            primitive: .cube,
            layerID: project.defaultLayerID
        )

        do {
            let placement = stage.placementPoint(devicePose: hands.devicePose(), slot: 0)
            let t = try await stage.addItem(item, assetURL: nil, freshPlacement: true, placement: placement)

            guard currentProject?.id == project.id else {
                stage.removeItem(item.id)
                return
            }

            item.unitScale = stage.lastImportUnitScale
            item.transform = StoredTransform(t)
            item.initialTransform = StoredTransform(t)
            let newItem = item
            mutate { $0.items.append(newItem) }
            pushLayersToStage()
        } catch is CancellationError {
            // Project closed mid-load.
        } catch {
            lastError = "Couldn't add the test cube: \(Self.reason(for: error))"
        }
    }

    func duplicateItem(_ id: UUID) async {
        guard let project = currentProject,
              let source = project.items.first(where: { $0.id == id }) else { return }

        var copy = source
        copy.id = UUID()
        copy.name = source.name + " copy"
        copy.transform.position.x += 0.3
        copy.initialTransform = copy.transform

        do {
            let t = try await stage.addItem(copy,
                                            assetURL: assetURL(for: copy),
                                            freshPlacement: false,
                                            placement: copy.transform.position)

            guard currentProject?.id == project.id else {
                stage.removeItem(copy.id)
                return
            }

            copy.transform = StoredTransform(t)
            copy.initialTransform = StoredTransform(t)
            let newItem = copy
            mutate { $0.items.append(newItem) }
            pushLayersToStage()
            select(newItem.id)
        } catch is CancellationError {
            // Project closed mid-load.
        } catch {
            lastError = "Couldn't duplicate “\(source.name)”: \(Self.reason(for: error))"
        }
    }

    func removeItem(_ id: UUID) {
        guard currentProject?.items.contains(where: { $0.id == id }) == true else { return }
        if selectedItemID == id { selectedItemID = nil }
        if inspection?.itemID == id {
            inspection = nil
            selectedPartID = nil
        }
        stage.removeItem(id)
        importNotes.removeAll { $0.itemID == id }
        // The asset file stays in the project folder, so Undo can bring the model back.
        mutate { $0.items.removeAll { $0.id == id } }
    }

    func setItemHidden(_ id: UUID, _ hidden: Bool) {
        mutate { project in
            if let index = project.items.firstIndex(where: { $0.id == id }) {
                project.items[index].isHidden = hidden
            }
        }
        pushLayersToStage()
    }

    func moveItem(_ id: UUID, toLayer layerID: UUID) {
        guard currentProject?.layer(layerID) != nil else { return }
        mutate { project in
            if let index = project.items.firstIndex(where: { $0.id == id }) {
                project.items[index].layerID = layerID
            }
        }
        pushLayersToStage()
    }

    /// Called at the end of every gesture. Simultaneous gestures on one item (scale + rotate
    /// ending together) coalesce into one undo step.
    func itemTransformChanged(_ id: UUID, transform: Transform) {
        storeTransform(id, transform, undo: .record(key: "transform:\(id.uuidString)", window: 0.8))
    }

    func resetScene() {
        guard currentProject != nil else { return }
        mutate { project in
            for index in project.items.indices {
                project.items[index].transform = project.items[index].initialTransform
            }
        }
        for item in currentProject?.items ?? [] {
            stage.setTransform(item.id, item.transform.transform)
        }
        recenter()
    }

    func select(_ id: UUID?) {
        selectedItemID = id
        selectedPartID = nil
        if interactionMode == .inspect, let id = id {
            inspection = stage.inspect(itemID: id, partID: nil)
        } else {
            inspection = nil
        }
    }

    func isItemLocked(_ id: UUID) -> Bool {
        guard let project = currentProject,
              let item = project.items.first(where: { $0.id == id }) else { return false }
        return project.layer(item.layerID)?.isLocked ?? false
    }

    func assetURL(for item: ProjectItem) -> URL? {
        guard let project = currentProject, let fileName = item.assetFileName else { return nil }
        return store.assetsFolder(for: project).appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Units (L2)

    /// The unit the item is currently interpreted in (closest preset to its factor).
    func unit(of item: ProjectItem) -> ModelUnit {
        ModelUnit.closest(to: stage.unitScale(of: item.id) ?? item.unitFactor)
    }

    /// Size of the item at `unit` (file numbers read in that unit, item scale included,
    /// scene scale excluded), or nil if the stage doesn't know the native size.
    func size(of item: ProjectItem, in unit: ModelUnit) -> SIMD3<Float>? {
        guard let native = stage.nativeSize(of: item.id) else { return nil }
        let itemScale = item.transform.scale
        return native * unit.factor * SIMD3<Float>(abs(itemScale.x), abs(itemScale.y), abs(itemScale.z))
    }

    /// Units fix menu: rescales the item to `unit` × its native size. Undoable, persisted.
    func setItemUnit(_ id: UUID, _ unit: ModelUnit) {
        guard let item = currentProject?.items.first(where: { $0.id == id }),
              !isItemLocked(id) else { return }
        let factor = unit.factor
        guard abs(item.unitFactor - factor) > 0.000_001 || stage.unitScale(of: id) != factor else { return }
        let newTransform = stage.setItemUnitScale(id, factor)
        mutate { project in
            guard let index = project.items.firstIndex(where: { $0.id == id }) else { return }
            project.items[index].unitScale = factor
            if let t = newTransform {
                project.items[index].transform = StoredTransform(t)
            }
        }
        importNotes.removeAll { $0.itemID == id }
        stage.refreshSelectionIndicator()
        if interactionMode == .inspect, selectedItemID == id {
            inspection = stage.inspect(itemID: id, partID: selectedPartID)
        }
    }

    func dismissImportNote(_ id: UUID) {
        importNotes.removeAll { $0.id == id }
    }

    func dismissAllImportNotes() {
        importNotes = []
    }

    private func addImportNote(_ note: ImportNote) {
        var notes = importNotes
        notes.append(note)
        if notes.count > 5 { notes.removeFirst(notes.count - 5) }
        importNotes = notes
    }

    // MARK: - Inspect + floor (v0.3)

    /// Selects an item and one of its internal parts (nil = the whole item) and refreshes `inspection`.
    func selectPart(itemID: UUID, partID: String?) {
        if selectedItemID != itemID {
            selectedItemID = itemID
        }
        selectedPartID = partID
        inspection = stage.inspect(itemID: itemID, partID: partID)
    }

    /// Hides / shows one internal part of an item (persisted in `hiddenPartPaths`). Undoable.
    func setPartHidden(itemID: UUID, partID: String, hidden: Bool) {
        guard currentProject?.items.contains(where: { $0.id == itemID }) == true else { return }
        mutate { project in
            guard let index = project.items.firstIndex(where: { $0.id == itemID }) else { return }
            var parts = project.items[index].hiddenParts
            if hidden {
                parts.insert(partID)
            } else {
                parts.remove(partID)
            }
            project.items[index].hiddenPartPaths = parts.isEmpty ? nil : parts.sorted()
        }
        stage.setPartHidden(itemID: itemID, partID: partID, hidden: hidden)
        refreshInspectionPart(itemID: itemID, partID: partID, hidden: hidden)
    }

    func dropSelectedToFloor() {
        guard let id = selectedItemID else { return }
        dropItemToFloor(id)
    }

    /// Moves one item down (or up) so its bottom sits on the floor. Skipped on locked layers.
    func dropItemToFloor(_ id: UUID) {
        guard !isItemLocked(id) else { return }
        if let t = stage.dropToFloor(id) {
            storeTransform(id, t, undo: .record(key: nil, window: 0))
        }
    }

    // MARK: - Layers

    func addLayer(named name: String) {
        guard let project = currentProject else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let layer = Layer(name: trimmed.isEmpty ? "Layer \(project.layers.count + 1)" : trimmed)
        mutate { $0.layers.append(layer) }
        pushLayersToStage()
    }

    func renameLayer(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { project in
            if let index = project.layers.firstIndex(where: { $0.id == id }) {
                project.layers[index].name = trimmed
            }
        }
        pushLayersToStage()
    }

    func deleteLayer(_ id: UUID) {
        guard let project = currentProject,
              project.layers.count > 1,
              project.layer(id) != nil else { return }
        mutate { project in
            project.layers.removeAll { $0.id == id }
            guard let fallback = project.layers.first?.id else { return }
            for index in project.items.indices where project.items[index].layerID == id {
                project.items[index].layerID = fallback
            }
        }
        pushLayersToStage()
    }

    func setLayerVisible(_ id: UUID, _ visible: Bool) {
        mutate { project in
            if let index = project.layers.firstIndex(where: { $0.id == id }) {
                project.layers[index].isVisible = visible
            }
        }
        pushLayersToStage()
    }

    func setLayerLocked(_ id: UUID, _ locked: Bool) {
        mutate { project in
            if let index = project.layers.firstIndex(where: { $0.id == id }) {
                project.layers[index].isLocked = locked
            }
        }
        pushLayersToStage()
    }

    // MARK: - Undo / Redo (L1)

    func undo() {
        guard canUndo, let current = currentProject, let snapshot = undoStack.popLast() else { return }
        redoStack.append(current)
        trim(&redoStack)
        lastUndoKey = nil
        restore(snapshot, over: current)
    }

    func redo() {
        guard canRedo, let current = currentProject, let snapshot = redoStack.popLast() else { return }
        undoStack.append(current)
        trim(&undoStack)
        lastUndoKey = nil
        restore(snapshot, over: current)
    }

    private enum UndoPolicy {
        /// Not an edit (view settings, preferences).
        case skip
        /// Record the state before the change. Changes with the same non-nil `key` within
        /// `window` seconds of the previous one coalesce into one step.
        case record(key: String?, window: TimeInterval)
    }

    private func registerUndo(before: Project, after: Project, policy: UndoPolicy) {
        guard case .record(let key, let window) = policy,
              !Self.sameUndoableState(before, after) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let key, key == lastUndoKey, now - lastUndoTime <= window, !undoStack.isEmpty {
            // Same continuous edit: keep the older snapshot.
            lastUndoTime = now
            if !redoStack.isEmpty { redoStack.removeAll() }
            return
        }
        undoStack.append(before)
        trim(&undoStack)
        if !redoStack.isEmpty { redoStack.removeAll() }
        lastUndoKey = key
        lastUndoTime = now
    }

    private func trim(_ stack: inout [Project]) {
        if stack.count > Self.maxHistory {
            stack.removeFirst(stack.count - Self.maxHistory)
        }
    }

    /// Items, layers and scene scale are undoable; name, view mode, environment and snapping
    /// are not (they stay as they are when undoing).
    private static func sameUndoableState(_ a: Project, _ b: Project) -> Bool {
        a.items == b.items
            && a.layers == b.layers
            && a.sceneScalePercent == b.sceneScalePercent
            && a.isTabletop == b.isTabletop
    }

    /// Applies the undoable state of `snapshot` to the open project and the stage.
    private func restore(_ snapshot: Project, over current: Project) {
        var restored = current
        restored.items = snapshot.items
        restored.layers = snapshot.layers
        restored.sceneScalePercent = snapshot.sceneScalePercent
        restored.isTabletop = snapshot.isTabletop
        restored.modifiedAt = Date()

        pendingSave?.cancel()
        pendingSave = nil
        currentProject = restored
        persist(restored)
        upsert(restored)

        // Stage diff: removed, changed, added.
        var oldByID: [UUID: ProjectItem] = [:]
        for item in current.items { oldByID[item.id] = item }
        let newIDs = Set(restored.items.map(\.id))

        for item in current.items where !newIDs.contains(item.id) {
            stage.removeItem(item.id)
            importNotes.removeAll { $0.itemID == item.id }
        }
        if let selected = selectedItemID, !newIDs.contains(selected) {
            selectedItemID = nil
        }

        var toAdd: [ProjectItem] = []
        for item in restored.items {
            guard let old = oldByID[item.id] else {
                toAdd.append(item)
                continue
            }
            if old.unitFactor != item.unitFactor {
                stage.setItemUnitScale(item.id, item.unitFactor)
            }
            if old.transform != item.transform {
                stage.setTransform(item.id, item.transform.transform)
            }
            let oldParts = old.hiddenParts
            let newParts = item.hiddenParts
            if oldParts != newParts {
                for part in oldParts.symmetricDifference(newParts) {
                    stage.setPartHidden(itemID: item.id, partID: part, hidden: newParts.contains(part))
                }
            }
        }

        pushLayersToStage()
        applySceneScale()
        stage.refreshSelectionIndicator()
        refreshInspectionAfterRestore()

        guard !toAdd.isEmpty else { return }
        isRestoringHistory = true
        let projectID = restored.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRestoringHistory = false }
            var failed: [String] = []
            for item in toAdd {
                guard self.currentProject?.id == projectID else { return }
                // Skip it if a later change removed it again.
                guard self.currentProject?.items.contains(where: { $0.id == item.id }) == true else { continue }
                do {
                    _ = try await self.stage.addItem(item,
                                                     assetURL: self.assetURL(for: item),
                                                     freshPlacement: false,
                                                     placement: item.transform.position)
                } catch is CancellationError {
                    return
                } catch {
                    failed.append(item.name)
                }
            }
            guard self.currentProject?.id == projectID else { return }
            self.pushLayersToStage()
            self.applySceneScale()
            self.applyInteractionToStage()
            if let selected = self.selectedItemID {
                self.stage.setSelected(selected)
            }
            if !failed.isEmpty {
                self.lastError = "Couldn't bring back: " + failed.joined(separator: ", ")
            }
        }
    }

    private func refreshInspectionAfterRestore() {
        guard interactionMode == .inspect, let id = selectedItemID else { return }
        inspection = stage.inspect(itemID: id, partID: selectedPartID)
    }

    private func resetHistories() {
        undoStack = []
        redoStack = []
        lastUndoKey = nil
        isRestoringHistory = false
        placeHistory = [.identity]
        placeIndex = 0
        releaseRecordIndex = nil
        isAnimatingPlace = false
        placeAnimationToken += 1
    }

    // MARK: - Places: Back / Forward (L1)

    /// Recenter: back to where the project started (recorded as a place, so Back returns).
    func recenter() {
        guard currentProject != nil else {
            fly.resetOffset(worldRoot: stage.worldRoot)
            return
        }
        if !isAnimatingPlace { recordPlace() }
        releaseRecordIndex = nil
        applyPlace(.identity, animated: true)
        recordPlace(.identity)
    }

    func goBack() {
        guard currentProject != nil else { return }
        // Somewhere not recorded yet (for example mid-glide): record it so Forward returns.
        if !isAnimatingPlace { recordPlace() }
        guard placeIndex > 0 else { return }
        placeIndex -= 1
        releaseRecordIndex = nil
        applyPlace(placeHistory[placeIndex], animated: true)
    }

    func goForward() {
        guard currentProject != nil, placeIndex < placeHistory.count - 1 else { return }
        placeIndex += 1
        releaseRecordIndex = nil
        applyPlace(placeHistory[placeIndex], animated: true)
    }

    /// Records the current place (or `explicit`). Public so camera jumps / teleports elsewhere can
    /// record one too. A place equal to the current history entry is ignored; recording after
    /// going Back drops the Forward entries, as in a browser.
    func recordPlace(_ explicit: StoredTransform? = nil) {
        guard currentProject != nil else { return }
        if explicit == nil && isAnimatingPlace { return }
        let place = explicit ?? StoredTransform(stage.worldRoot.transform)
        if placeHistory.isEmpty {
            placeHistory = [.identity]
            placeIndex = 0
        }
        if placeHistory.indices.contains(placeIndex), Self.samePlace(placeHistory[placeIndex], place) {
            return
        }
        var history = placeHistory
        if placeIndex < history.count - 1 {
            history.removeSubrange((placeIndex + 1)...)
        }
        history.append(place)
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
        placeHistory = history
        placeIndex = history.count - 1
    }

    /// Moves worldRoot to `place`, stopping any fly glide first.
    private func applyPlace(_ place: StoredTransform, animated: Bool) {
        let worldRoot = stage.worldRoot
        let current = worldRoot.transform
        // Stops the glide (this also resets worldRoot to identity), then put it back so the
        // animation starts where the user is.
        fly.resetOffset(worldRoot: worldRoot)
        worldRoot.transform = current

        let target = place.transform
        placeAnimationToken += 1
        let token = placeAnimationToken
        let duration: TimeInterval = 0.45

        guard animated, stageState == .open, worldRoot.scene != nil else {
            worldRoot.transform = target
            isAnimatingPlace = false
            return
        }
        isAnimatingPlace = true
        _ = worldRoot.move(to: target, relativeTo: worldRoot.parent, duration: duration, timingFunction: .easeInOut)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.1) * 1_000_000_000))
            guard let self, self.placeAnimationToken == token else { return }
            self.isAnimatingPlace = false
        }
    }

    /// Watches fly mode: a place is recorded when a grab ends, and amended once the glide
    /// after the release has settled.
    private func startFlyWatch() {
        flyWatchTask?.cancel()
        flyWatchTask = Task { @MainActor [weak self] in
            var wasFlying = false
            var releasedAt: TimeInterval? = nil
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self else { return }
                let flying = self.fly.isFlying
                let now = ProcessInfo.processInfo.systemUptime
                if flying && !wasFlying {
                    // Where the flight started (usually already recorded: deduplicated).
                    releasedAt = nil
                    self.releaseRecordIndex = nil
                } else if !flying && wasFlying {
                    self.recordPlace()
                    self.releaseRecordIndex = self.placeIndex
                    releasedAt = now
                } else if !flying, let released = releasedAt, now - released > 1.2 {
                    releasedAt = nil
                    self.amendReleasedPlace()
                }
                wasFlying = flying
            }
        }
    }

    private func stopFlyWatch() {
        flyWatchTask?.cancel()
        flyWatchTask = nil
        releaseRecordIndex = nil
    }

    /// Replaces the place recorded at release with the settled pose (the glide carried on).
    private func amendReleasedPlace() {
        guard let index = releaseRecordIndex,
              index == placeIndex, index == placeHistory.count - 1,
              !isAnimatingPlace else { return }
        releaseRecordIndex = nil
        let settled = StoredTransform(stage.worldRoot.transform)
        if index > 0, Self.samePlace(placeHistory[index - 1], settled) {
            // Glided back onto the previous place: drop the duplicate.
            placeHistory.removeLast()
            placeIndex = placeHistory.count - 1
        } else {
            placeHistory[index] = settled
        }
    }

    private static func samePlace(_ a: StoredTransform, _ b: StoredTransform) -> Bool {
        guard simd_distance(a.position, b.position) < 0.05 else { return false }
        let dot = abs(simd_dot(simd_normalize(a.rotation), simd_normalize(b.rotation)))
        let angle = 2 * acos(min(dot, 1))
        return angle < 0.035   // ~2°
    }

    // MARK: - App flow (L6)

    /// SwiftUI scene actions, captured from whichever QVision scene appeared last (they act on
    /// the app's scenes, not on the view they were read from).
    struct SceneActions {
        let openWindow: OpenWindowAction
        let dismissWindow: DismissWindowAction
        let openImmersiveSpace: OpenImmersiveSpaceAction
        let dismissImmersiveSpace: DismissImmersiveSpaceAction
    }

    func installSceneActions(_ actions: SceneActions) {
        sceneActions = actions
    }

    /// Converges the stage ImmersiveSpace to "open iff a project is open" (serialized).
    func requestStageSync() {
        enqueueFlow { [weak self] in
            await self?.syncStage()
        }
    }

    /// Leave: saves, closes the project, its windows and the stage, and shows Home.
    func requestLeave() {
        guard currentProject != nil || stageState != .closed else { return }
        enqueueFlow { [weak self] in
            await self?.performLeave(toHome: true)
        }
    }

    /// The palm button (or any code that hides the panel without leaving) calls this right
    /// before `dismissWindow(id: panelWindowID)`, so the close isn't taken as "close the app".
    func notePanelHideRequested() {
        panelDismissExpectedUntil = ProcessInfo.processInfo.systemUptime + 2
    }

    /// Call right before dismissing the main window on purpose (handoff to the panel window).
    func noteMainWindowDismissRequested() {
        mainDismissExpectedUntil = ProcessInfo.processInfo.systemUptime + 2
    }

    func mainWindowDidAppear() {
        isMainWindowOpen = true
    }

    func mainWindowDidDisappear() {
        isMainWindowOpen = false
        let expected = ProcessInfo.processInfo.systemUptime < mainDismissExpectedUntil
        mainDismissExpectedUntil = 0
        guard !expected else { return }
        leaveIfNoWindowRemains()
        leaveRenderedIfUncontrollable()
    }

    func panelWindowDidAppear() {
        isProjectPanelVisible = true
    }

    func panelWindowDidDisappear() {
        isProjectPanelVisible = false
        let expected = ProcessInfo.processInfo.systemUptime < panelDismissExpectedUntil
        panelDismissExpectedUntil = 0
        guard !expected else { return }
        // The palm button toggles the panel: a hide, not a close. (Belt and braces in case the
        // palm button doesn't call `notePanelHideRequested`: it can only be tapped while the left
        // palm faces the user.)
        if hands.left.isTracked && hands.left.palmFacingUser { return }
        leaveIfNoWindowRemains()
    }

    /// The stage space went away (also when the user exits it with the Digital Crown).
    func stageDidAppear() {
        stageState = .open
    }

    func stageDidDisappear() {
        stageState = .closed
        guard !isTransitioning, currentProject != nil else { return }
        if !isMainWindowOpen && !isProjectPanelVisible && !isLayersWindowOpen && !isInspectorWindowOpen {
            // Nothing of QVision is left on screen: don't keep a half-open project around,
            // so the next launch starts cleanly at Home.
            closeProject()
        }
    }

    /// The user closed a project window. If no QVision window is left, the user closed
    /// everything: save, close the stage and end (no Home window is opened).
    private func leaveIfNoWindowRemains() {
        guard currentProject != nil, !isTransitioning else { return }
        Task { @MainActor [weak self] in
            // Let a window that is opening right now (handoff, file picker) report itself.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self,
                  self.currentProject != nil,
                  !self.isTransitioning,
                  !self.isMainWindowOpen,
                  !self.isProjectPanelVisible,
                  !self.isLayersWindowOpen,
                  !self.isInspectorWindowOpen else { return }
            self.enqueueFlow { [weak self] in
                await self?.performLeave(toHome: false)
            }
        }
    }

    /// Runs `operation` after every previously queued flow operation has finished.
    @discardableResult
    private func enqueueFlow(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = flowTail
        pendingTransitions += 1
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await operation()
            self?.pendingTransitions -= 1
        }
        flowTail = task
        return task
    }

    private func performOpen(_ id: UUID) async {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        // Only one ImmersiveSpace at a time (v0.8): rendered scene and stream go first.
        await closeRenderedSpace()
        await endStreamIfNeeded()

        // Double tap / already open: just make sure the stage is there.
        if currentProject?.id == id {
            await syncStage()
            return
        }
        // Switching projects: save and close the previous one first (the stage space stays open).
        if currentProject != nil {
            flushPendingSave()
            closeProject()
        }

        openingProjectID = id
        mainWindowHandedOffProjectID = nil
        currentProject = project
        homeTab = .projects
        noteOpened(.project, id: id.uuidString, title: project.name)
        interactionMode = .view
        selectedItemID = nil
        selectedPartID = nil
        inspection = nil
        importProgress = nil
        importNotes = []
        fly.resetOffset(worldRoot: stage.worldRoot)
        resetHistories()

        isLoading = true
        loadToken += 1
        let token = loadToken
        let folder = store.assetsFolder(for: project)
        // The models load while the immersive space opens. The load is not part of the flow
        // chain, so Leave (or opening another project) never waits for a big model.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stage.load(project: project, assetURL: { item in
                guard let fileName = item.assetFileName else { return nil }
                return folder.appendingPathComponent(fileName, isDirectory: false)
            })
            // Left or switched while loading: closeProject already reset the state.
            guard self.loadToken == token else { return }
            self.isLoading = false
            self.openingProjectID = nil
            guard self.currentProject?.id == id else { return }
            self.stage.setEnvironment(project.environment, mode: project.viewMode)
            self.applyInteractionToStage()
            self.applySceneScale()
        }
        await syncStage()
    }

    private func performLeave(toHome: Bool) async {
        let actions = sceneActions
        let layersOpen = isLayersWindowOpen
        let inspectorOpen = isInspectorWindowOpen
        let panelOpen = isProjectPanelVisible

        // Home first, so the app always keeps a window while the others close.
        if toHome, !isMainWindowOpen, let actions {
            actions.openWindow(id: Self.mainWindowID)
        }
        if currentProject != nil {
            closeProject()   // saves
        }
        if let actions {
            if layersOpen {
                actions.dismissWindow(id: Self.layersWindowID)
            }
            if inspectorOpen {
                actions.dismissWindow(id: Self.inspectorWindowID)
            }
            if panelOpen {
                panelDismissExpectedUntil = ProcessInfo.processInfo.systemUptime + 2
                actions.dismissWindow(id: Self.panelWindowID)
            }
        }
        await syncStage()
    }

    /// Opens / dismisses the stage space until it matches `currentProject`. Only called from
    /// flow operations, so never concurrently.
    private func syncStage() async {
        guard let actions = sceneActions else { return }
        for _ in 0..<12 {
            let wantsStage = currentProject != nil
            switch (wantsStage, stageState) {
            case (true, .closed):
                stageState = .transitioning
                let result = await actions.openImmersiveSpace(id: Self.stageSpaceID)
                switch result {
                case .opened:
                    stageState = .open
                case .userCancelled:
                    stageState = .closed
                    return
                case .error:
                    stageState = .closed
                    lastError = "The 3D stage couldn't be opened. Close any other immersive view (for example a server stream) and use “Open Stage” to try again."
                    return
                @unknown default:
                    stageState = .closed
                    return
                }

            case (false, .open):
                stageState = .transitioning
                await actions.dismissImmersiveSpace()
                stageState = .closed

            case (_, .transitioning):
                // A system transition (onAppear / onDisappear pending): give it a moment.
                try? await Task.sleep(nanoseconds: 200_000_000)

            default:
                return
            }
        }
        // Never leave the state stuck in `.transitioning`.
        if stageState == .transitioning { stageState = .closed }
    }

    // MARK: - Rendered mode flow (v0.8 R4, L6 rules)

    func attach(server: ServerSessionController) {
        self.server = server
    }

    /// Opens a rendered scene in the "rendered" ImmersiveSpace (serialized with every other open /
    /// leave). An open project is saved and closed first, and a server stream is ended, so two
    /// immersive spaces are never open at once.
    func requestOpenRendered(_ scene: RenderedScene) {
        enqueueFlow { [weak self] in
            await self?.performOpenRendered(scene)
        }
    }

    /// v0.10 E3: another room of the same Environment group, inside the open rendered space:
    /// fade out, unload, load, fade in (the space stays open).
    func requestSwitchRoom(to next: RenderedScene) {
        enqueueFlow { [weak self] in
            guard let self else { return }
            guard self.currentRenderedScene != nil, self.renderedState == .open else {
                await self.performOpenRendered(next)
                return
            }
            guard self.currentRenderedScene?.id != next.id else { return }
            self.currentRenderedScene = next
            if !self.isMainWindowOpen {
                // The palm menu is in charge: don't run the main-window handoff again.
                self.renderedHandedOffSceneID = next.id
            }
            self.noteOpened(.rendered, id: next.id, title: next.title)
            self.rendered.switchRoom(to: next)
        }
    }

    /// Exit: closes the rendered space, releases the scene and shows Home › Rendered.
    func requestLeaveRendered() {
        guard currentRenderedScene != nil || renderedState != .closed else { return }
        enqueueFlow { [weak self] in
            await self?.performLeaveRendered(toHome: true)
        }
    }

    /// Server tab: before connecting, close the stage or the rendered space (serialized).
    func releaseImmersiveSpacesForStream() async {
        guard currentRenderedScene != nil || renderedState != .closed
                || currentProject != nil || stageState != .closed else { return }
        await enqueueFlow { [weak self] in
            guard let self else { return }
            await self.closeRenderedSpace()
            if self.currentProject != nil || self.stageState != .closed {
                await self.performLeave(toHome: true)
            }
        }.value
    }

    func renderedDidAppear() {
        renderedState = .open
    }

    /// The rendered space went away. If that wasn't our own Exit (Digital Crown, system), the
    /// scene is released and Home › Rendered is what the main window shows next.
    func renderedDidDisappear() {
        renderedState = .closed
        // A late onDisappear while the flow is already opening the next scene must not release it.
        if currentRenderedScene == nil || !isTransitioning {
            rendered.release()
        }
        guard !isTransitioning, currentRenderedScene != nil else { return }
        currentRenderedScene = nil
        renderedHandedOffSceneID = nil
        homeTab = .rendered
    }

    private func performOpenRendered(_ scene: RenderedScene) async {
        // Already showing it: nothing to do.
        if currentRenderedScene?.id == scene.id, renderedState == .open {
            return
        }
        // A project (and its windows / stage) closes first; Home stays.
        if currentProject != nil || stageState != .closed {
            await performLeave(toHome: true)
        }
        await endStreamIfNeeded()
        // Another rendered scene is open: close it first (one scene in memory at a time).
        if currentRenderedScene != nil || renderedState != .closed {
            await closeRenderedSpace()
        }

        homeTab = .rendered
        renderedHandedOffSceneID = nil
        currentRenderedScene = scene
        noteOpened(.rendered, id: scene.id, title: scene.title)
        rendered.begin(scene)
        await syncRendered()
        if currentRenderedScene == nil {
            rendered.release()
        }
    }

    private func performLeaveRendered(toHome: Bool) async {
        homeTab = .rendered
        // Home first, so the app always keeps a window while the space closes.
        if toHome, !isMainWindowOpen, let actions = sceneActions {
            actions.openWindow(id: Self.mainWindowID)
        }
        await closeRenderedSpace()
    }

    /// Dismisses the rendered space (if open) and releases the scene.
    private func closeRenderedSpace() async {
        guard currentRenderedScene != nil || renderedState != .closed else { return }
        currentRenderedScene = nil
        renderedHandedOffSceneID = nil
        await syncRendered()
        rendered.release()
    }

    /// Opens / dismisses the rendered space until it matches `currentRenderedScene`. Only called
    /// from flow operations, so never concurrently.
    private func syncRendered() async {
        guard let actions = sceneActions else {
            if currentRenderedScene != nil {
                currentRenderedScene = nil
                lastError = "The rendered view couldn't be opened. Try again."
            }
            return
        }
        for _ in 0..<12 {
            let wantsSpace = currentRenderedScene != nil
            switch (wantsSpace, renderedState) {
            case (true, .closed):
                renderedState = .transitioning
                let result = await actions.openImmersiveSpace(id: Self.renderedSpaceID)
                switch result {
                case .opened:
                    renderedState = .open
                case .userCancelled:
                    renderedState = .closed
                    currentRenderedScene = nil
                    return
                case .error:
                    renderedState = .closed
                    currentRenderedScene = nil
                    lastError = "The rendered view couldn't be opened. Close any other immersive view (a project or a server stream) and try again."
                    return
                @unknown default:
                    renderedState = .closed
                    currentRenderedScene = nil
                    return
                }

            case (false, .open):
                renderedState = .transitioning
                await actions.dismissImmersiveSpace()
                renderedState = .closed

            case (_, .transitioning):
                try? await Task.sleep(nanoseconds: 200_000_000)

            default:
                return
            }
        }
        if renderedState == .transitioning { renderedState = .closed }
    }

    /// Ends a server stream (and waits for its space to close) before another space opens.
    private func endStreamIfNeeded() async {
        guard let server else { return }
        let streaming = server.isStreamSpaceOpen || server.wantsStreamSpace
        switch server.phase {
        case .connecting, .connected:
            server.disconnect()
        default:
            break
        }
        guard streaming || server.isStreamSpaceOpen else { return }
        // StreamImmersiveView / ServerHomeView dismiss the space once the stream is down.
        for _ in 0..<30 {
            if !server.isStreamSpaceOpen { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if server.isStreamSpaceOpen, let actions = sceneActions {
            await actions.dismissImmersiveSpace()
            server.isStreamSpaceOpen = false
        }
    }

    /// The main window closed while a rendered scene is open. Without hand tracking there is no
    /// palm menu to leave with, so leave the scene too (the app ends cleanly).
    private func leaveRenderedIfUncontrollable() {
        guard currentRenderedScene != nil, !isTransitioning else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self,
                  self.currentRenderedScene != nil,
                  !self.isTransitioning,
                  !self.isMainWindowOpen,
                  self.hands.status != .running else { return }
            self.enqueueFlow { [weak self] in
                await self?.performLeaveRendered(toHome: false)
            }
        }
    }


    // MARK: - Private helpers

    private func storeTransform(_ id: UUID, _ transform: Transform, undo: UndoPolicy) {
        guard currentProject?.items.contains(where: { $0.id == id }) == true else { return }
        let stored = StoredTransform(transform)
        mutate(undo: undo) { project in
            if let index = project.items.firstIndex(where: { $0.id == id }) {
                project.items[index].transform = stored
            }
        }
    }

    /// The one path for changing the open project: apply, record undo, bump `modifiedAt`,
    /// save, refresh `projects`.
    private func mutate(undo: UndoPolicy = .record(key: nil, window: 0), _ body: (inout Project) -> Void) {
        guard var project = currentProject else { return }
        // This save includes any pending (debounced) change.
        pendingSave?.cancel()
        pendingSave = nil
        let before = project
        body(&project)
        registerUndo(before: before, after: project, policy: undo)
        project.modifiedAt = Date()
        currentProject = project
        persist(project)
        upsert(project)
    }

    /// Like `mutate`, but the disk write is debounced (~0.4 s). For slider-driven settings.
    private func mutateDeferred(undo: UndoPolicy = .skip, _ body: (inout Project) -> Void) {
        guard var project = currentProject else { return }
        let before = project
        body(&project)
        registerUndo(before: before, after: project, policy: undo)
        project.modifiedAt = Date()
        currentProject = project
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    /// Writes the open project now if a debounced save is pending.
    private func flushPendingSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        guard let project = currentProject else { return }
        persist(project)
        upsert(project)
    }

    /// Changes a project that may or may not be open (e.g. rename from the Home screen).
    private func updateProject(_ id: UUID, _ body: (inout Project) -> Void) {
        if currentProject?.id == id {
            mutate(undo: .skip, body)
            return
        }
        guard var project = projects.first(where: { $0.id == id }) else { return }
        body(&project)
        project.modifiedAt = Date()
        persist(project)
        upsert(project)
    }

    private func persist(_ project: Project) {
        do {
            try store.save(project)
        } catch {
            lastError = "Couldn't save “\(project.name)”: \(error.localizedDescription)"
        }
    }

    /// Replaces or inserts `project` in `projects`, keeping newest-first order.
    private func upsert(_ project: Project) {
        var list = projects
        if let index = list.firstIndex(where: { $0.id == project.id }) {
            list[index] = project
        } else {
            list.append(project)
        }
        list.sort { $0.modifiedAt > $1.modifiedAt }
        projects = list
    }

    /// Pushes the hit-testing state to the stage: items are targetable only in Edit / Inspect,
    /// and never while fly mode is on.
    private func applyInteractionToStage() {
        stage.setInteraction(inspect: interactionMode == .inspect,
                             itemsTargetable: interactionMode != .view && !isFlyModeEnabled)
    }

    private func pushLayersToStage() {
        guard let project = currentProject else { return }
        stage.apply(layers: project.layers, items: project.items)
    }

    private func applySceneScale() {
        guard let project = currentProject else { return }
        stage.setSceneScale(Float(project.scenePercent / 100), tabletop: project.tabletop)
    }

    private static func clampFlySpeed(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return min(max(value, flySpeedRange.lowerBound), flySpeedRange.upperBound)
    }

    /// Cheap refresh after a part's visibility changed: patch the one part in the current
    /// inspection instead of re-walking a model that may have thousands of parts.
    private func refreshInspectionPart(itemID: UUID, partID: String, hidden: Bool) {
        guard let info = inspection, info.itemID == itemID else { return }
        var parts = info.parts
        guard let index = parts.firstIndex(where: { $0.id == partID }) else {
            inspection = stage.inspect(itemID: itemID, partID: selectedPartID)
            return
        }
        parts[index].isHidden = hidden
        inspection = InspectionInfo(
            itemID: info.itemID,
            itemName: info.itemName,
            fileName: info.fileName,
            fileSizeBytes: info.fileSizeBytes,
            size: info.size,
            triangleCount: info.triangleCount,
            vertexCount: info.vertexCount,
            meshCount: info.meshCount,
            materialCount: info.materialCount,
            animationCount: info.animationCount,
            parts: parts,
            selectedPartID: info.selectedPartID
        )
    }

    /// A user-facing reason for an error, with the technical description when the localized
    /// one is only the generic "The operation couldn't be completed".
    private static func reason(for error: Error) -> String {
        let nsError = error as NSError
        var text = error.localizedDescription
        if let failure = nsError.localizedFailureReason, !failure.isEmpty, !text.contains(failure) {
            text += " " + failure
        }
        let lower = text.lowercased()
        if lower.contains("couldn’t be completed") || lower.contains("couldn't be completed") {
            text += " (\(String(describing: error)))"
        }
        return text
    }
}

/// Small number formatters shared by the panels (file sizes, counts, meters).
enum DisplayFormat {
    /// Decimal megabytes, as the Files app shows them: "0.4", "12", "110".
    static func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb < 10 {
            return String(format: "%.1f", mb)
        }
        return String(format: "%.0f", mb)
    }

    /// "980", "12.4 K", "1.2 M".
    static func count(_ value: Int) -> String {
        let v = Double(value)
        if value < 1_000 { return "\(value)" }
        if value < 1_000_000 { return String(format: "%.1f K", v / 1_000) }
        return String(format: "%.1f M", v / 1_000_000)
    }

    /// Meters with sensible precision: "120", "12.5", "1.25", "0.035".
    static func meters(_ value: Float) -> String {
        let v = Double(abs(value))
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        if v >= 0.1 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }

    /// "W × D × H m" from a size vector (x = width, z = depth, y = height).
    static func dimensions(_ size: SIMD3<Float>) -> String {
        "\(meters(size.x)) × \(meters(size.z)) × \(meters(size.y)) m"
    }

    /// N in "1:N" for a scene scale percent.
    static func scaleDenominator(percent: Double) -> Int {
        let p = min(max(percent, 1), 100)
        return max(1, Int((100 / p).rounded()))
    }

    /// "1×", "2.5×", "0.25×".
    static func multiplier(_ value: Float) -> String {
        let v = Double(value)
        if (v * 10).rounded() == v * 10 {
            return (v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.1f", v)) + "×"
        }
        return String(format: "%.2f", v) + "×"
    }
}
