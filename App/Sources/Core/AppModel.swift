import Foundation
import Observation
import RealityKit
import UniformTypeIdentifiers

/// The single app state object. Owns the stage, hand tracking and fly controller,
/// and persists every project mutation through `ProjectStore`.
@MainActor
@Observable
final class AppModel {
    static let mainWindowID = "main"
    static let stageSpaceID = "stage"
    static let layersWindowID = "layers"
    static let inspectorWindowID = "inspector"
    /// The project panel: a real visionOS window (system move bar), opened from the palm button.
    static let panelWindowID = "panel"

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
            mutate { $0.viewMode = newValue }
            stage.setEnvironment(environment, mode: newValue)
        }
    }

    var environment: EnvironmentPreset {
        get { currentProject?.environment ?? .studio }
        set {
            guard let project = currentProject, project.environment != newValue else { return }
            mutate { $0.environment = newValue }
            stage.setEnvironment(newValue, mode: viewMode)
        }
    }

    var isFlyModeEnabled: Bool = false {
        didSet { fly.isEnabled = isFlyModeEnabled }
    }

    // MARK: v0.3 state

    /// Edit = move / scale / rotate. Inspect = nothing moves, tap shows information.
    var interactionMode: InteractionMode = .edit {
        didSet {
            guard oldValue != interactionMode else { return }
            stage.setInspectMode(interactionMode == .inspect)
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
    var sceneScalePercent: Double {
        get { currentProject?.scenePercent ?? 100 }
        set {
            guard let project = currentProject else { return }
            let clamped = min(max(newValue, 1), 100)
            guard clamped != project.scenePercent else { return }
            mutateDeferred { $0.sceneScalePercent = clamped }
            applySceneScale()
        }
    }

    /// Lift scaled content to table height (only has an effect below 100 %).
    var isTabletop: Bool {
        get { currentProject?.tabletop ?? false }
        set {
            guard let project = currentProject, project.tabletop != newValue else { return }
            mutateDeferred { $0.isTabletop = newValue }
            applySceneScale()
        }
    }

    /// Magnetic floor while dragging (default on).
    var snapToFloor: Bool {
        get { currentProject?.snapsToFloor ?? true }
        set {
            guard let project = currentProject, project.snapsToFloor != newValue else { return }
            mutate { $0.snapToFloor = newValue }
        }
    }

    /// Fly speed multiplier, 0.25...4 (the panel's slider keeps it in range; the controller
    /// gets a clamped value either way).
    var flySpeed: Float = 1 {
        didSet { fly.speed = min(max(flySpeed, 0.25), 4) }
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

    @ObservationIgnored let stage: StageController
    @ObservationIgnored let hands: HandTrackingService
    @ObservationIgnored let fly: FlyController

    @ObservationIgnored private let store = ProjectStore()
    @ObservationIgnored private var pendingSave: Task<Void, Never>? = nil

    init() {
        let handService = HandTrackingService()
        self.stage = StageController()
        self.hands = handService
        self.fly = FlyController(hands: handService)
        self.projects = store.loadAll()
        self.fly.speed = 1
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
        }
        do {
            try store.delete(id: id)
        } catch {
            lastError = "Couldn't delete the project: \(error.localizedDescription)"
        }
        projects.removeAll { $0.id == id }
    }

    func openProject(_ id: UUID) async {
        guard let project = projects.first(where: { $0.id == id }) else { return }

        if currentProject != nil {
            flushPendingSave()
        }
        if currentProject != nil, currentProject?.id != id {
            isFlyModeEnabled = false
        }
        if currentProject?.id != id {
            mainWindowHandedOffProjectID = nil
        }
        currentProject = project
        interactionMode = .edit
        selectedItemID = nil
        selectedPartID = nil
        inspection = nil
        importProgress = nil
        fly.resetOffset(worldRoot: stage.worldRoot)

        isLoading = true
        defer { isLoading = false }

        let folder = store.assetsFolder(for: project)
        await stage.load(project: project, assetURL: { item in
            guard let fileName = item.assetFileName else { return nil }
            return folder.appendingPathComponent(fileName, isDirectory: false)
        })

        // The user may have left the project while it was loading.
        guard currentProject?.id == id else { return }
        stage.setEnvironment(project.environment, mode: project.viewMode)
        stage.setInspectMode(false)
        applySceneScale()
    }

    func closeProject() {
        isFlyModeEnabled = false
        interactionMode = .edit
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
        isProjectPanelVisible = false
        isImportPickerRequested = false
        mainWindowHandedOffProjectID = nil
        stage.clear()
        fly.resetOffset(worldRoot: stage.worldRoot)
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

            // 2. Load and place (native size, bottom on the floor).
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

                item.transform = StoredTransform(t)
                item.initialTransform = StoredTransform(t)
                let newItem = item
                mutate { $0.items.append(newItem) }
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

    func itemTransformChanged(_ id: UUID, transform: Transform) {
        guard currentProject?.items.contains(where: { $0.id == id }) == true else { return }
        let stored = StoredTransform(transform)
        mutate { project in
            if let index = project.items.firstIndex(where: { $0.id == id }) {
                project.items[index].transform = stored
            }
        }
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

    func recenter() {
        fly.resetOffset(worldRoot: stage.worldRoot)
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

    // MARK: - Inspect + floor (v0.3)

    /// Selects an item and one of its internal parts (nil = the whole item) and refreshes `inspection`.
    func selectPart(itemID: UUID, partID: String?) {
        if selectedItemID != itemID {
            selectedItemID = itemID
        }
        selectedPartID = partID
        inspection = stage.inspect(itemID: itemID, partID: partID)
    }

    /// Hides / shows one internal part of an item (persisted in `hiddenPartPaths`).
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
            itemTransformChanged(id, transform: t)
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

    // MARK: - Private helpers

    /// The one path for changing the open project: apply, bump `modifiedAt`, save, refresh `projects`.
    private func mutate(_ body: (inout Project) -> Void) {
        guard var project = currentProject else { return }
        // This save includes any pending (debounced) change.
        pendingSave?.cancel()
        pendingSave = nil
        body(&project)
        project.modifiedAt = Date()
        currentProject = project
        persist(project)
        upsert(project)
    }

    /// Like `mutate`, but the disk write is debounced (~0.4 s). For slider-driven settings.
    private func mutateDeferred(_ body: (inout Project) -> Void) {
        guard var project = currentProject else { return }
        body(&project)
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
            mutate(body)
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

    private func pushLayersToStage() {
        guard let project = currentProject else { return }
        stage.apply(layers: project.layers, items: project.items)
    }

    private func applySceneScale() {
        guard let project = currentProject else { return }
        stage.setSceneScale(Float(project.scenePercent / 100), tabletop: project.tabletop)
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
}
