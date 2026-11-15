import Foundation
import simd

// v0.8 "Rendered" mode: data types and file helpers (docs/v0.8-REQUIREMENTS.md R2, R3).
//
// On the headset every downloaded / imported scene is one folder:
//   Documents/Rendered/<id>/<Name>.usdz            the baked scene (required)
//   Documents/Rendered/<id>/<Name>.json            sidecar (optional)
//   Documents/Rendered/<id>/<Name>.jpg|.jpeg|.png  thumbnail (optional)
//   Documents/Rendered/<id>/.qvision-origin.json   where it came from (library id, size, date)
// Downloads and imports are staged in Documents/Rendered/.partial-<uuid>/ and renamed into place
// only when complete, so a failed or cancelled transfer never leaves a partial scene.

/// Sidecar `<Name>.json` of a QVision Rendered package. Every field is optional and decoded
/// tolerantly (a wrong type in one field doesn't discard the others).
///
/// `start.position` is a floor-level point in USDZ coordinates (Y-up, metres): the user's feet
/// go there. `start.yawDegrees` is the direction the user faces, as a right-handed rotation about
/// +Y of the scene's -Z axis: 0 = looking along -Z, 90 = along -X, -90 = along +X, 180 = along +Z.
/// If `eyeHeightIncluded` is true, `start.position` is at eye height instead, and the user's
/// eyes go there. `hasSky` (QVision extension): true = the scene contains its own sky geometry,
/// so no sky dome is added; false = always add the dome; missing = detect it by object name.
struct RenderedSidecar: Codable, Equatable {
    struct Start: Codable, Equatable {
        var position: [Float]?
        var yawDegrees: Float?

        init(position: [Float]? = nil, yawDegrees: Float? = nil) {
            self.position = position
            self.yawDegrees = yawDegrees
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            position = try? c.decodeIfPresent([Float].self, forKey: .position)
            yawDegrees = try? c.decodeIfPresent(Float.self, forKey: .yawDegrees)
        }
    }

    var title: String?
    var version: Int?
    var start: Start?
    var eyeHeightIncluded: Bool?
    var notes: String?
    var hasSky: Bool?

    init(title: String? = nil, version: Int? = nil, start: Start? = nil,
         eyeHeightIncluded: Bool? = nil, notes: String? = nil, hasSky: Bool? = nil) {
        self.title = title
        self.version = version
        self.start = start
        self.eyeHeightIncluded = eyeHeightIncluded
        self.notes = notes
        self.hasSky = hasSky
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        start = try? c.decodeIfPresent(Start.self, forKey: .start)
        eyeHeightIncluded = try? c.decodeIfPresent(Bool.self, forKey: .eyeHeightIncluded)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        hasSky = try? c.decodeIfPresent(Bool.self, forKey: .hasSky)
    }

    /// `start.position` if it is three finite numbers.
    var startPosition: SIMD3<Float>? {
        guard let p = start?.position, p.count >= 3 else { return nil }
        let v = SIMD3<Float>(p[0], p[1], p[2])
        guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
        return v
    }

    var startYawDegrees: Float {
        guard let yaw = start?.yawDegrees, yaw.isFinite else { return 0 }
        return yaw
    }

    var trimmedTitle: String? {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// One entry of the PC library's `GET /index.json`.
struct LibraryEntry: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var file: String
    var sizeBytes: Int64
    var modified: String?
    var thumbnail: String?
    var sidecar: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        let fallbackID = (file as NSString).deletingPathExtension
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? fallbackID
        let rawTitle = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        title = rawTitle?.isEmpty == false ? rawTitle! : RenderedFiles.prettyTitle(fallbackID)
        sizeBytes = (try? c.decodeIfPresent(Int64.self, forKey: .sizeBytes)) ?? 0
        modified = (try? c.decodeIfPresent(String.self, forKey: .modified)) ?? nil
        thumbnail = (try? c.decodeIfPresent(String.self, forKey: .thumbnail)) ?? nil
        sidecar = (try? c.decodeIfPresent(String.self, forKey: .sidecar)) ?? nil
    }

    /// `modified` (ISO 8601) as a date.
    var modifiedDate: Date? {
        guard let modified else { return nil }
        return ISO8601DateFormatter().date(from: modified)
    }
}

/// `.qvision-origin.json` in a scene folder: where the scene came from.
struct RenderedOrigin: Codable, Equatable {
    /// "library" (downloaded from the PC) or "files" (imported from the Files app).
    var source: String
    var libraryID: String?
    var host: String?
    var modified: String?
    var sizeBytes: Int64?
    var title: String?
    var addedAt: Date?
}

/// A scene stored on this Vision Pro.
struct RenderedScene: Identifiable, Hashable {
    /// Folder name inside Documents/Rendered.
    let id: String
    let title: String
    let folder: URL
    let usdzURL: URL
    let sidecarURL: URL?
    let thumbnailURL: URL?
    /// Bytes of the whole package (USDZ + sidecar + thumbnail).
    let sizeBytes: Int64
    let addedAt: Date
    let origin: RenderedOrigin?

    static func == (lhs: RenderedScene, rhs: RenderedScene) -> Bool {
        lhs.id == rhs.id && lhs.usdzURL == rhs.usdzURL && lhs.sizeBytes == rhs.sizeBytes && lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum RenderedError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// File-system helpers for the Rendered folder. Not actor-bound: safe off the main actor.
enum RenderedFiles {
    static let folderName = "Rendered"
    static let originFileName = ".qvision-origin.json"
    static let partialPrefix = ".partial-"
    static let thumbnailExtensions = ["jpg", "jpeg", "png"]

    /// Documents/Rendered (created if missing).
    static func rootFolder() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = documents.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Removes staging folders left over by an interrupted download or import.
    static func removeLeftovers(in root: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(partialPrefix) {
            try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Every complete scene folder (one containing a .usdz), newest first.
    static func scan(root: URL) -> [RenderedScene] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var scenes: [RenderedScene] = []
        for name in names where !name.hasPrefix(".") {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let scene = scene(in: folder, id: name) {
                scenes.append(scene)
            }
        }
        scenes.sort { $0.addedAt > $1.addedAt }
        return scenes
    }

    static func scene(in folder: URL, id: String) -> RenderedScene? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        let visible = files.filter { !$0.hasPrefix(".") }.sorted()
        guard let usdzName = visible.first(where: { ($0 as NSString).pathExtension.lowercased() == "usdz" }) else { return nil }
        let stem = (usdzName as NSString).deletingPathExtension.lowercased()

        func match(_ extensions: [String]) -> String? {
            let candidates = visible.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            return candidates.first(where: { ($0 as NSString).deletingPathExtension.lowercased() == stem }) ?? candidates.first
        }

        let usdzURL = folder.appendingPathComponent(usdzName, isDirectory: false)
        let sidecarURL = match(["json"]).map { folder.appendingPathComponent($0, isDirectory: false) }
        let thumbnailURL = match(thumbnailExtensions).map { folder.appendingPathComponent($0, isDirectory: false) }
        let origin = loadOrigin(folder.appendingPathComponent(originFileName, isDirectory: false))
        let sidecar = sidecarURL.flatMap(loadSidecar)

        var total: Int64 = 0
        for url in [usdzURL, sidecarURL, thumbnailURL].compactMap({ $0 }) {
            total += fileSize(url) ?? 0
        }
        let attributes = try? fm.attributesOfItem(atPath: usdzURL.path)
        let added = origin?.addedAt
            ?? (attributes?[.creationDate] as? Date)
            ?? (attributes?[.modificationDate] as? Date)
            ?? Date.distantPast

        let title = sidecar?.trimmedTitle
            ?? origin?.title
            ?? prettyTitle((usdzName as NSString).deletingPathExtension)

        return RenderedScene(
            id: id,
            title: title,
            folder: folder,
            usdzURL: usdzURL,
            sidecarURL: sidecarURL,
            thumbnailURL: thumbnailURL,
            sizeBytes: total,
            addedAt: added,
            origin: origin
        )
    }

    static func loadSidecar(_ url: URL) -> RenderedSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RenderedSidecar.self, from: data)
    }

    static func loadOrigin(_ url: URL) -> RenderedOrigin? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RenderedOrigin.self, from: data)
    }

    static func writeOrigin(_ origin: RenderedOrigin, into folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(origin)
        try data.write(to: folder.appendingPathComponent(originFileName, isDirectory: false), options: .atomic)
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// "Casa_SUA" -> "Casa SUA".
    static func prettyTitle(_ stem: String) -> String {
        let text = stem.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Rendered scene" : text
    }

    /// A safe folder / file name: no separators, no leading dot, no "..".
    static func sanitizedName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\0")
        var cleaned = raw.components(separatedBy: forbidden).joined(separator: "_")
        cleaned = cleaned.replacingOccurrences(of: "..", with: "_")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Scene" : cleaned
    }

    /// A bare file name taken from the server index, or nil if it isn't one.
    static func safeFileName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains(".."),
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else { return nil }
        return name
    }

    /// `name`, or `name-2`, `name-3`... so that root/<result> doesn't exist yet.
    static func uniqueFolderName(_ name: String, in root: URL) -> String {
        let fm = FileManager.default
        var candidate = name
        var counter = 2
        while fm.fileExists(atPath: root.appendingPathComponent(candidate, isDirectory: true).path) {
            candidate = "\(name)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// Renames a complete staging folder to its final name. An existing folder with that name
    /// (an older download of the same scene) is replaced; if the rename fails it is put back.
    static func moveIntoPlace(staging: URL, final: URL) throws {
        let fm = FileManager.default
        var backup: URL? = nil
        if fm.fileExists(atPath: final.path) {
            let old = final.deletingLastPathComponent()
                .appendingPathComponent(partialPrefix + "old-" + UUID().uuidString, isDirectory: true)
            try fm.moveItem(at: final, to: old)
            backup = old
        }
        do {
            try fm.moveItem(at: staging, to: final)
        } catch {
            if let backup { try? fm.moveItem(at: backup, to: final) }
            throw error
        }
        if let backup { try? fm.removeItem(at: backup) }
    }

    /// Copies a file picked in the Files app (security-scoped, coordinated so iCloud files
    /// download first).
    static func coordinatedCopy(from source: URL, to destination: URL) throws {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinationError) { readURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let copyError { throw copyError }
        if let coordinationError { throw coordinationError }
    }

    /// Imports one package picked in Files into Documents/Rendered/<unique stem>/ (staged).
    /// Returns the folder name.
    @discardableResult
    static func importPackage(usdz: URL, sidecar: URL?, thumbnail: URL?, root: URL) throws -> String {
        let fm = FileManager.default
        let stem = sanitizedName(usdz.deletingPathExtension().lastPathComponent)
        let staging = root.appendingPathComponent(partialPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var done = false
        defer { if !done { try? fm.removeItem(at: staging) } }

        let usdzDestination = staging.appendingPathComponent(stem + ".usdz", isDirectory: false)
        try coordinatedCopy(from: usdz, to: usdzDestination)
        guard (fileSize(usdzDestination) ?? 0) > 0 else {
            throw RenderedError.message("the file is empty.")
        }

        var title: String? = nil
        if let sidecar {
            let destination = staging.appendingPathComponent(stem + ".json", isDirectory: false)
            try coordinatedCopy(from: sidecar, to: destination)
            guard let parsed = loadSidecar(destination) else {
                throw RenderedError.message("“\(sidecar.lastPathComponent)” isn't a valid QVision sidecar (JSON).")
            }
            title = parsed.trimmedTitle
        }
        if let thumbnail {
            let ext = thumbnail.pathExtension.lowercased()
            let destination = staging.appendingPathComponent(stem + "." + ext, isDirectory: false)
            try? coordinatedCopy(from: thumbnail, to: destination)
        }

        try writeOrigin(RenderedOrigin(source: "files", libraryID: nil, host: nil, modified: nil,
                                       sizeBytes: fileSize(usdzDestination), title: title, addedAt: Date()),
                        into: staging)
        let folderName = uniqueFolderName(stem, in: root)
        try moveIntoPlace(staging: staging, final: root.appendingPathComponent(folderName, isDirectory: true))
        done = true
        return folderName
    }

    /// Free space for large files on the Documents volume, or nil if unknown.
    static func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }

    /// "1.2 GB", "340 MB", "12 KB".
    static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
