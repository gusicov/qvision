import Foundation
import ModelIO

/// Errors thrown by `ProjectStore`. Messages are user-facing (shown in the global alert).
enum ProjectStoreError: LocalizedError {
    case usdcExportUnavailable
    case emptyModel(String)
    case conversionFailed(String, String)
    case readFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .usdcExportUnavailable:
            return "This device can't convert OBJ files (USDC export isn't available). Convert the model to USDZ on a Mac and import that instead."
        case .emptyModel(let name):
            return "“\(name)” doesn't contain any geometry that could be read."
        case .conversionFailed(let name, let reason):
            return "Couldn't convert “\(name)” to USD: \(reason)"
        case .readFailed(let name, let reason):
            return "Couldn't read “\(name)”: \(reason)"
        }
    }
}

/// Result of copying one picked file into a project's Assets folder.
struct ImportedAsset: Sendable, Hashable {
    /// File name inside the Assets folder (what `ProjectItem.assetFileName` stores).
    let fileName: String
    /// Size of the stored file in bytes (for a converted OBJ: the larger of .obj / .usdc).
    let byteSize: Int64
}

/// Disk persistence for projects.
///
/// Layout:
///   Documents/Projects/<uuid>/project.json
///   Documents/Projects/<uuid>/Assets/*
final class ProjectStore {
    let rootURL: URL

    private let fileManager = FileManager.default

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        rootURL = documents.appendingPathComponent("Projects", isDirectory: true)
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    func projectFolder(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func assetsFolder(for project: Project) -> URL {
        projectFolder(for: project.id).appendingPathComponent("Assets", isDirectory: true)
    }

    private func projectFile(for id: UUID) -> URL {
        projectFolder(for: id).appendingPathComponent("project.json", isDirectory: false)
    }

    // MARK: - Projects

    /// Every readable project, newest `modifiedAt` first. Unreadable folders are skipped.
    func loadAll() -> [Project] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [Project] = []
        for folder in folders {
            let file = folder.appendingPathComponent("project.json", isDirectory: false)
            guard let data = try? Data(contentsOf: file),
                  let project = try? decoder.decode(Project.self, from: data) else { continue }
            result.append(project)
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func save(_ project: Project) throws {
        try fileManager.createDirectory(at: assetsFolder(for: project), withIntermediateDirectories: true)
        let data = try encoder.encode(project)
        try data.write(to: projectFile(for: project.id), options: .atomic)
    }

    func delete(id: UUID) throws {
        let folder = projectFolder(for: id)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
    }

    /// Copies the whole project folder (assets included) under a new id, named "<name> copy".
    /// Items get new ids; layers keep theirs (they are per-project anyway).
    func duplicate(_ project: Project) throws -> Project {
        var copy = project
        copy.id = UUID()
        copy.name = project.name + " copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        copy.items = project.items.map { item in
            var newItem = item
            newItem.id = UUID()
            return newItem
        }

        let source = projectFolder(for: project.id)
        let destination = projectFolder(for: copy.id)
        if fileManager.fileExists(atPath: source.path) {
            try fileManager.copyItem(at: source, to: destination)
        }
        try save(copy)   // overwrites the copied project.json with the new id/name
        return copy
    }

    // MARK: - Assets
    //
    // Everything below is static, nonisolated and pure FileManager work, so `AppModel` can run it
    // on a background task (`Task.detached`) while the UI keeps showing progress.

    /// Size of a picked file in bytes, if the system knows it (may be nil for iCloud files that
    /// aren't downloaded yet). Cheap metadata read; fine to call from the main actor.
    nonisolated static func fileSize(of url: URL) -> Int64? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey]) else {
            return nil
        }
        if let size = values.fileSize { return Int64(size) }
        if let size = values.totalFileSize { return Int64(size) }
        return nil
    }

    /// Copies `url` into `assets` (the project's Assets folder) and returns the stored file name
    /// (the file the stage should load) plus its size in bytes. OBJ files are converted to USDC
    /// with ModelIO; the original .obj is kept next to the .usdc.
    ///
    /// The read goes through `NSFileCoordinator` inside security-scoped access, so files that live
    /// in iCloud Drive (or another file provider) are fully downloaded before they are copied.
    /// Blocking: call it off the main actor.
    nonisolated static func importAsset(from url: URL, intoAssetsFolder assets: URL) throws -> ImportedAsset {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        var copyResult: Result<ImportedAsset, Error>?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            do {
                let imported = try copyIntoAssets(readURL: readURL, originalURL: url, assets: assets)
                copyResult = .success(imported)
            } catch {
                copyResult = .failure(error)
            }
        }

        if let copyResult = copyResult {
            return try copyResult.get()
        }
        if let coordinationError = coordinationError {
            throw ProjectStoreError.readFailed(url.lastPathComponent, coordinationError.localizedDescription)
        }
        throw ProjectStoreError.readFailed(url.lastPathComponent, "the file couldn't be accessed.")
    }

    /// Removes a stored asset again (used when the model copied fine but then failed to load).
    /// For a converted OBJ (`<name>.usdc`) the kept `<name>.obj` is removed too.
    nonisolated static func removeImportedAsset(_ fileName: String, from assets: URL) {
        let fm = FileManager.default
        let stored = assets.appendingPathComponent(fileName, isDirectory: false)
        try? fm.removeItem(at: stored)
        if stored.pathExtension.lowercased() == "usdc" {
            let obj = stored.deletingPathExtension().appendingPathExtension("obj")
            if fm.fileExists(atPath: obj.path) {
                try? fm.removeItem(at: obj)
            }
        }
    }

    /// Runs inside the coordinated read. `readURL` is the URL to read from (usually equal to
    /// `originalURL`); names are derived from `originalURL`.
    private nonisolated static func copyIntoAssets(readURL: URL, originalURL: URL, assets: URL) throws -> ImportedAsset {
        let ext = originalURL.pathExtension.lowercased()
        var base = originalURL.deletingPathExtension().lastPathComponent
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { base = "Model" }

        if ext == "obj" {
            return try importOBJ(readURL: readURL, originalURL: originalURL, baseName: base, into: assets)
        }

        let name = uniqueBaseName(base, extensions: [ext], in: assets)
        let fileName = ext.isEmpty ? name : name + "." + ext
        let destination = assets.appendingPathComponent(fileName, isDirectory: false)
        try FileManager.default.copyItem(at: readURL, to: destination)
        return ImportedAsset(fileName: fileName, byteSize: byteSize(of: destination))
    }

    private nonisolated static func importOBJ(readURL: URL, originalURL: URL, baseName: String, into assets: URL) throws -> ImportedAsset {
        guard MDLAsset.canExportFileExtension("usdc") else {
            throw ProjectStoreError.usdcExportUnavailable
        }

        let fm = FileManager.default
        let name = uniqueBaseName(baseName, extensions: ["obj", "usdc"], in: assets)
        let objURL = assets.appendingPathComponent(name + ".obj", isDirectory: false)
        let usdcURL = assets.appendingPathComponent(name + ".usdc", isDirectory: false)

        try fm.copyItem(at: readURL, to: objURL)
        let objBytes = byteSize(of: objURL)

        // Best effort: a sibling material file with the same base name (often not accessible
        // from the sandboxed picker, which is fine; the model then loads untextured).
        let mtlSource = originalURL.deletingPathExtension().appendingPathExtension("mtl")
        let mtlDestination = assets.appendingPathComponent(mtlSource.lastPathComponent, isDirectory: false)
        if !fm.fileExists(atPath: mtlDestination.path) {
            try? fm.copyItem(at: mtlSource, to: mtlDestination)
        }

        let asset = MDLAsset(url: objURL)
        guard asset.count > 0 else {
            try? fm.removeItem(at: objURL)
            throw ProjectStoreError.emptyModel(originalURL.lastPathComponent)
        }

        do {
            try asset.export(to: usdcURL)
        } catch {
            try? fm.removeItem(at: usdcURL)
            try? fm.removeItem(at: objURL)
            throw ProjectStoreError.conversionFailed(originalURL.lastPathComponent, error.localizedDescription)
        }

        guard fm.fileExists(atPath: usdcURL.path) else {
            try? fm.removeItem(at: objURL)
            throw ProjectStoreError.conversionFailed(originalURL.lastPathComponent, "no output file was written.")
        }
        return ImportedAsset(fileName: name + ".usdc", byteSize: max(objBytes, byteSize(of: usdcURL)))
    }

    private nonisolated static func byteSize(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// "Chair", "Chair-2", "Chair-3", ... : the first base name for which none of
    /// `<base>.<ext>` exists yet in `folder`.
    private nonisolated static func uniqueBaseName(_ base: String, extensions: [String], in folder: URL) -> String {
        let fm = FileManager.default
        func taken(_ candidate: String) -> Bool {
            extensions.contains { ext in
                let fileName = ext.isEmpty ? candidate : candidate + "." + ext
                return fm.fileExists(atPath: folder.appendingPathComponent(fileName, isDirectory: false).path)
            }
        }

        var candidate = base
        var counter = 2
        while taken(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }
}
