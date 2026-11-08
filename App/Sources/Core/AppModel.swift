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

    enum StageState { case closed, transitioning, open }
    var stageState: StageState = .closed

    private(set) var projects: [Project] = []
    private(set) var currentProject: Project? = nil

    var selectedItemID: UUID? = nil {
        didSet { stage.setSelected(selectedItemID) }
    }

    var isLoading: Bool = false
    var lastError: String? = nil
    var isLayersPanelVisible: Bool = false

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

    @ObservationIgnored let stage: StageController
    @ObservationIgnored let hands: HandTrackingService
    @ObservationIgnored let fly: FlyController

    @ObservationIgnored private let store = ProjectStore()

    init() {
        let handService = HandTrackingService()
        self.stage = StageController()
        self.hands = handService
        self.fly = FlyController(hands: handService)
        self.projects = store.loadAll()
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

        if currentProject != nil, currentProject?.id != id {
            isFlyModeEnabled = false
        }
        currentProject = project
        selectedItemID = nil
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
    }

    func closeProject() {
        isFlyModeEnabled = false
        isLayersPanelVisible = false
        if let project = currentProject {
            persist(project)
            upsert(project)
        }
        selectedItemID = nil
        stage.clear()
        fly.resetOffset(worldRoot: stage.worldRoot)
        currentProject = nil
    }

    // MARK: - Items

    func importAssets(_ urls: [URL]) async {
        guard let project = currentProject, !urls.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        var errors: [String] = []
        var slot = 0

        for url in urls {
            // Stop if the project was closed or switched while we were awaiting.
            guard currentProject?.id == project.id else { break }

            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else {
                errors.append("“\(url.lastPathComponent)” isn't a supported format (USDZ, USD, Reality or OBJ).")
                continue
            }

            do {
                let fileName = try store.importAsset(from: url, into: project)
                let fileURL = store.assetsFolder(for: project).appendingPathComponent(fileName, isDirectory: false)

                var item = ProjectItem(
                    name: url.deletingPathExtension().lastPathComponent,
                    assetFileName: fileName,
                    layerID: currentProject?.defaultLayerID ?? project.defaultLayerID
                )

                let placement = stage.placementPoint(devicePose: hands.devicePose(), slot: slot)
                let t = try await stage.addItem(item, assetURL: fileURL, fit: true, placement: placement)

                guard currentProject?.id == project.id else {
                    stage.removeItem(item.id)
                    break
                }

                item.transform = StoredTransform(t)
                item.initialTransform = StoredTransform(t)
                let newItem = item
                mutate { $0.items.append(newItem) }
                slot += 1
            } catch {
                errors.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }

        pushLayersToStage()

        if !errors.isEmpty {
            lastError = "Some files couldn't be imported.\n" + errors.joined(separator: "\n")
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
            let t = try await stage.addItem(item, assetURL: nil, fit: true, placement: placement)

            guard currentProject?.id == project.id else {
                stage.removeItem(item.id)
                return
            }

            item.transform = StoredTransform(t)
            item.initialTransform = StoredTransform(t)
            let newItem = item
            mutate { $0.items.append(newItem) }
            pushLayersToStage()
        } catch {
            lastError = "Couldn't add the test cube: \(error.localizedDescription)"
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
                                            fit: false,
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
        } catch {
            lastError = "Couldn't duplicate “\(source.name)”: \(error.localizedDescription)"
        }
    }

    func removeItem(_ id: UUID) {
        guard currentProject?.items.contains(where: { $0.id == id }) == true else { return }
        if selectedItemID == id { selectedItemID = nil }
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
        body(&project)
        project.modifiedAt = Date()
        currentProject = project
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
}
