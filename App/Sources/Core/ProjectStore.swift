import Foundation
import ModelIO

/// Errors thrown by `ProjectStore`. Messages are user-facing (shown in the global alert).
enum ProjectStoreError: LocalizedError {
    case usdcExportUnavailable
    case emptyModel(String)
    case conversionFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .usdcExportUnavailable:
            return "This device can't convert OBJ files (USDC export isn't available). Convert the model to USDZ on a Mac and import that instead."
        case .emptyModel(let name):
            return "“\(name)” doesn't contain any geometry that could be read."
        case .conversionFailed(let name, let reason):
            return "Couldn't convert “\(name)” to USD: \(reason)"
        }
    }
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

    /// Copies `url` into the project's Assets folder and returns the stored file name
    /// (the file the stage should load). OBJ files are converted to USDC with ModelIO;
    /// the original .obj is kept next to the .usdc.
    func importAsset(from url: URL, into project: Project) throws -> String {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let assets = assetsFolder(for: project)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)

        let ext = url.pathExtension.lowercased()
        var base = url.deletingPathExtension().lastPathComponent
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { base = "Model" }

        if ext == "obj" {
            return try importOBJ(from: url, baseName: base, into: assets)
        }

        let name = uniqueBaseName(base, extensions: [ext], in: assets)
        let fileName = ext.isEmpty ? name : name + "." + ext
        let destination = assets.appendingPathComponent(fileName, isDirectory: false)
        try fileManager.copyItem(at: url, to: destination)
        return fileName
    }

    private func importOBJ(from url: URL, baseName: String, into assets: URL) throws -> String {
        guard MDLAsset.canExportFileExtension("usdc") else {
            throw ProjectStoreError.usdcExportUnavailable
        }

        let name = uniqueBaseName(baseName, extensions: ["obj", "usdc"], in: assets)
        let objURL = assets.appendingPathComponent(name + ".obj", isDirectory: false)
        let usdcURL = assets.appendingPathComponent(name + ".usdc", isDirectory: false)

        try fileManager.copyItem(at: url, to: objURL)

        // Best effort: a sibling material file with the same base name (often not accessible
        // from the sandboxed picker, which is fine; the model then loads untextured).
        let mtlSource = url.deletingPathExtension().appendingPathExtension("mtl")
        let mtlDestination = assets.appendingPathComponent(mtlSource.lastPathComponent, isDirectory: false)
        if !fileManager.fileExists(atPath: mtlDestination.path) {
            try? fileManager.copyItem(at: mtlSource, to: mtlDestination)
        }

        let asset = MDLAsset(url: objURL)
        guard asset.count > 0 else {
            try? fileManager.removeItem(at: objURL)
            throw ProjectStoreError.emptyModel(url.lastPathComponent)
        }

        do {
            try asset.export(to: usdcURL)
        } catch {
            try? fileManager.removeItem(at: usdcURL)
            try? fileManager.removeItem(at: objURL)
            throw ProjectStoreError.conversionFailed(url.lastPathComponent, error.localizedDescription)
        }

        guard fileManager.fileExists(atPath: usdcURL.path) else {
            try? fileManager.removeItem(at: objURL)
            throw ProjectStoreError.conversionFailed(url.lastPathComponent, "no output file was written.")
        }
        return name + ".usdc"
    }

    /// "Chair", "Chair-2", "Chair-3", ... : the first base name for which none of
    /// `<base>.<ext>` exists yet in `folder`.
    private func uniqueBaseName(_ base: String, extensions: [String], in folder: URL) -> String {
        func taken(_ candidate: String) -> Bool {
            extensions.contains { ext in
                let fileName = ext.isEmpty ? candidate : candidate + "." + ext
                return fileManager.fileExists(atPath: folder.appendingPathComponent(fileName, isDirectory: false).path)
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
