import SwiftUI
import RealityKit
import UniformTypeIdentifiers

/// A 3D file stored in the app's Documents/Models folder.
struct ModelFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
}

/// A model instance currently on the stage.
struct PlacedModel: Identifiable, Hashable {
    let id: UUID
    let file: ModelFile
}

@MainActor
@Observable
final class AppModel {
    static let panelWindowID = "panel"
    static let stageSpaceID = "stage"

    /// File types RealityKit can load natively on visionOS.
    static let supportedTypes: [UTType] = [.usdz, .usd, .realityFile]
    static let supportedExtensions: Set<String> = ["usdz", "usd", "usda", "usdc", "reality"]

    enum StageState { case closed, transitioning, open }

    var stageState: StageState = .closed
    var cubeVisible = true
    var realWorldScale = false
    var library: [ModelFile] = []
    var placed: [PlacedModel] = []
    var selectedID: UUID?
    var isLoading = false
    var lastError: String?

    /// Owns all RealityKit entities. Not observed: SwiftUI never needs to diff entities.
    @ObservationIgnored let stage = StageController()

    init() {
        refreshLibrary()
    }

    // MARK: Library (files on disk)

    var modelsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func refreshLibrary() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: modelsFolder, includingPropertiesForKeys: nil)) ?? []
        library = urls
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map(ModelFile.init(url:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Copies picked files (e.g. from iCloud Drive) into the app's own folder.
    func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = modelsFolder.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                lastError = "Import failed for \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        refreshLibrary()
    }

    func deleteFromLibrary(_ file: ModelFile) {
        for p in placed where p.file == file { removeFromStage(p.id) }
        try? FileManager.default.removeItem(at: file.url)
        refreshLibrary()
    }

    // MARK: Stage

    func place(_ file: ModelFile) async {
        isLoading = true
        defer { isLoading = false }
        let id = UUID()
        do {
            try await stage.addModel(
                id: id, file: file, realWorldScale: realWorldScale, slot: placed.count)
            placed.append(PlacedModel(id: id, file: file))
            selectedID = id
        } catch {
            lastError = "Could not load \(file.name): \(error.localizedDescription)"
        }
    }

    func removeFromStage(_ id: UUID) {
        stage.removeModel(id: id)
        placed.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func clearStage() {
        for p in placed { stage.removeModel(id: p.id) }
        placed.removeAll()
        selectedID = nil
    }

    func setCubeVisible(_ visible: Bool) {
        cubeVisible = visible
        stage.cube.isEnabled = visible
    }

    /// Puts every object back where it first appeared and shows the cube again.
    func resetScene() {
        stage.resetAllTransforms()
        setCubeVisible(true)
        selectedID = nil
    }

    func select(_ id: UUID?) { selectedID = id }

    var selectedName: String? {
        guard let id = selectedID else { return nil }
        return placed.first { $0.id == id }?.file.name
    }
}
