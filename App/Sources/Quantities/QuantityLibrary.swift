import CryptoKit
import Foundation
import Observation

/// One quantity package listed by the QVision Library (`GET /quantities.json`, library v3).
struct QuantityIndexEntry: Codable, Identifiable, Hashable, Sendable {
    struct File: Codable, Hashable, Sendable {
        let bytes: Int64
        let sha256: String
    }

    /// Package folder relative to the PC's Quantities folder ("a/b", forward slashes).
    let folder: String
    let packageId: String
    let name: String
    let files: [String: File]
    let sizeBytes: Int64
    let modified: String?

    var id: String { packageId }
}

/// A package stored in `Documents/Quantities/<packageId>/` (relative paths kept as on the PC).
struct LocalQuantityPackage: Identifiable, Hashable, Sendable {
    let packageId: String
    let name: String
    let folder: URL
    let sizeBytes: Int64
    let addedAt: Date
    /// The PC listing it was downloaded from (nil for a package copied by hand).
    let origin: QuantityIndexEntry?
    /// v0.11.1 tap data (Data/pick.bin). Downloads from before v0.11.1 lack it and need an Update.
    let hasPickData: Bool

    var id: String { packageId }
}

/// Quantity packages on this Vision Pro and on the PC (v0.11 Q1). Same behaviour as the
/// Rendered library: progress, resume (HTTP Range, per file), Update when the PC's files changed.
/// Every file is checked against the PC's SHA-256 before the package is put in place;
/// `AVQPackage.open(at:)` then only checks sizes (v0.11.1: no second hash on every open).
@MainActor
@Observable
final class QuantityLibrary {
    static let folderName = "Quantities"
    private static let originName = ".qvision-origin.json"
    private static let resumeName = "resume.json"

    private struct Origin: Codable {
        var entry: QuantityIndexEntry
        var addedAt: Date
    }

    private struct ManifestName: Decodable {
        let packageId: String
        let projectName: String?
    }

    private(set) var packages: [LocalQuantityPackage] = []
    private(set) var entries: [QuantityIndexEntry] = []
    private(set) var indexState: RenderedLibrary.IndexState = .idle
    private(set) var indexHost: String? = nil
    /// The library on the PC answers but predates quantity packages.
    private(set) var libraryTooOld = false
    private(set) var downloads: [String: RenderedLibrary.Download] = [:]
    /// Bytes already here of interrupted downloads, by packageId.
    private(set) var partials: [String: Int64] = [:]
    var lastError: String? = nil

    @ObservationIgnored let rootFolder: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var userCancelled: Set<String> = []
    @ObservationIgnored private var indexTask: Task<Void, Never>? = nil
    @ObservationIgnored private var isFetching = false

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootFolder = documents.appendingPathComponent(Self.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: rootFolder, withIntermediateDirectories: true)
        // Backups left by an interrupted "move into place".
        if let names = try? FileManager.default.contentsOfDirectory(atPath: rootFolder.path) {
            for name in names where name.hasPrefix(RenderedFiles.partialPrefix) {
                try? FileManager.default.removeItem(at: rootFolder.appendingPathComponent(name, isDirectory: true))
            }
        }
        refresh()
    }

    // MARK: - On this Vision Pro

    func refresh() {
        let fm = FileManager.default
        var found: [LocalQuantityPackage] = []
        var partial: [String: Int64] = [:]
        let names = (try? fm.contentsOfDirectory(atPath: rootFolder.path)) ?? []
        for name in names {
            let folder = rootFolder.appendingPathComponent(name, isDirectory: true)
            if name.hasPrefix(RenderedFiles.resumePrefix) {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(Self.resumeName)),
                   let entry = try? JSONDecoder().decode(QuantityIndexEntry.self, from: data) {
                    partial[entry.packageId] = RenderedFiles.directorySize(folder)
                }
                continue
            }
            guard !name.hasPrefix("."),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(ManifestName.self, from: data) else { continue }
            let origin = (try? Data(contentsOf: folder.appendingPathComponent(Self.originName)))
                .flatMap { try? JSONDecoder().decode(Origin.self, from: $0) }
            let title = manifest.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(LocalQuantityPackage(
                packageId: manifest.packageId,
                name: (title?.isEmpty == false ? title : nil) ?? manifest.packageId,
                folder: folder,
                sizeBytes: origin?.entry.sizeBytes ?? RenderedFiles.directorySize(folder),
                addedAt: origin?.addedAt ?? Date(),
                origin: origin?.entry,
                hasPickData: QuantityPickIndex.isPresent(in: folder)
            ))
        }
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if packages != found { packages = found }
        // Running downloads report their own progress.
        for id in downloads.keys { partial[id] = nil }
        if partials != partial { partials = partial }
    }

    func local(for entry: QuantityIndexEntry) -> LocalQuantityPackage? {
        packages.first { $0.packageId == entry.packageId }
    }

    func entry(for package: LocalQuantityPackage) -> QuantityIndexEntry? {
        guard indexState == .loaded else { return nil }
        return entries.first { $0.packageId == package.packageId }
    }

    /// Same files (by SHA-256) as the PC's listing.
    func isUpToDate(_ entry: QuantityIndexEntry) -> Bool {
        guard let local = local(for: entry), local.hasPickData else { return false }
        guard let origin = local.origin else { return true }
        return origin.files == entry.files
    }

    func hasUpdate(_ package: LocalQuantityPackage) -> Bool {
        if !package.hasPickData { return true }
        guard let entry = entry(for: package) else { return false }
        return !isUpToDate(entry)
    }

    func delete(_ package: LocalQuantityPackage) {
        try? FileManager.default.removeItem(at: package.folder)
        refresh()
    }

    var totalBytes: Int64 { packages.reduce(0) { $0 + $1.sizeBytes } }

    // MARK: - On my PC

    func poll(address: String) {
        guard !isFetching else { return }
        fetchIndex(address: address, quiet: indexState != .idle)
    }

    func fetchIndex(address: String, quiet: Bool = false) {
        indexTask?.cancel()
        guard let base = RenderedLibrary.baseURL(for: address),
              let healthURL = URL(string: base.absoluteString + "/health"),
              let indexURL = URL(string: base.absoluteString + "/quantities.json") else {
            indexState = .failed("Enter the PC's IP address (for example 192.168.0.87).")
            return
        }
        if !quiet { indexState = .loading }
        isFetching = true
        indexTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isFetching = false }
            do {
                var health = URLRequest(url: healthURL)
                health.timeoutInterval = 4
                let (healthData, healthResponse) = try await self.session.data(for: health)
                try Task.checkCancellation()
                let status = (healthResponse as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200,
                      let object = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any],
                      (object["name"] as? String) == "QVision Library" else {
                    if status == 403 {
                        throw RenderedError.message("The QVision Library refused this headset (LAN clients only). Check that the headset and the PC are on the same network.")
                    }
                    throw RenderedError.message("Something answers at \(address), but it isn't the QVision Library. Use the address shown in the QVision Library (PC) window.")
                }
                guard object["quantities"] != nil else {
                    self.libraryTooOld = true
                    self.entries = []
                    self.indexHost = address
                    self.indexState = .loaded
                    return
                }
                self.libraryTooOld = false
                var request = URLRequest(url: indexURL)
                request.timeoutInterval = 30   // the PC hashes new files on the first listing
                let (data, response) = try await self.session.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let decoded = try? JSONDecoder().decode([QuantityIndexEntry].self, from: data) else {
                    throw RenderedError.message("The QVision Library sent an unreadable quantities list.")
                }
                if self.entries != decoded { self.entries = decoded }
                self.indexHost = address
                if self.indexState != .loaded { self.indexState = .loaded }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                let message = RenderedLibrary.describeNetworkError(error, address: address)
                if self.indexState != .failed(message) { self.indexState = .failed(message) }
            }
        }
    }

    /// `http://host:port/q/<folder>/<relative path>`, each segment percent-encoded.
    static func memberURL(address: String, folder: String, path: String) -> URL? {
        guard let base = RenderedLibrary.baseURL(for: address) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%;")
        let segments = (folder + "/" + path).split(separator: "/", omittingEmptySubsequences: false)
        var encoded: [String] = []
        for segment in segments {
            guard let value = String(segment).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            encoded.append(value)
        }
        return URL(string: base.absoluteString + "/q/" + encoded.joined(separator: "/"))
    }

    /// A relative member path that stays inside its package folder.
    nonisolated static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    // MARK: - Downloads

    var isDownloading: Bool { !downloads.isEmpty }

    func download(_ entry: QuantityIndexEntry) {
        guard downloads[entry.packageId] == nil, let address = indexHost else { return }
        let id = entry.packageId
        downloads[id] = RenderedLibrary.Download(title: entry.name, stage: .preparing,
                                                 received: partials[id] ?? 0, expected: entry.sizeBytes)
        userCancelled.remove(id)
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performDownload(entry, address: address)
            } catch {
                let cancelled = (error is CancellationError) || ((error as? URLError)?.code == .cancelled)
                if self.userCancelled.contains(id) {
                    try? FileManager.default.removeItem(at: self.stagingFolder(id))
                } else if !cancelled {
                    self.lastError = "“\(entry.name)” stopped downloading. "
                        + RenderedLibrary.describeNetworkError(error, address: address)
                        + " What arrived is kept: tap Resume to continue."
                }
            }
            self.userCancelled.remove(id)
            self.downloads[id] = nil
            self.tasks[id] = nil
            self.refresh()
        }
    }

    func cancelDownload(_ id: String) {
        userCancelled.insert(id)
        tasks[id]?.cancel()
    }

    private func stagingFolder(_ packageId: String) -> URL {
        rootFolder.appendingPathComponent(RenderedFiles.resumePrefix + RenderedFiles.sanitizedName(packageId), isDirectory: true)
    }

    private func performDownload(_ entry: QuantityIndexEntry, address: String) async throws {
        let fm = FileManager.default
        let id = entry.packageId
        guard entry.files["manifest.json"] != nil,
              entry.files.keys.allSatisfy(Self.isSafeRelative) else {
            throw RenderedError.message("The library listed an invalid package.")
        }
        let staging = stagingFolder(id)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // A file staged for another revision is dropped; the rest continues where it stopped.
        let metaURL = staging.appendingPathComponent(Self.resumeName)
        if let data = try? Data(contentsOf: metaURL),
           let previous = try? JSONDecoder().decode(QuantityIndexEntry.self, from: data) {
            for (path, file) in previous.files where entry.files[path] != file {
                try? fm.removeItem(at: staging.appendingPathComponent(path))
            }
        }
        try JSONEncoder().encode(entry).write(to: metaURL, options: .atomic)

        let installed = local(for: entry)
        let ordered = entry.files.sorted { $0.value.bytes < $1.value.bytes }   // the small files first
        var staged: Int64 = 0
        for (path, file) in ordered {
            staged += min(RenderedFiles.fileSize(staging.appendingPathComponent(path)) ?? 0, file.bytes)
        }
        if let free = RenderedFiles.availableCapacity(at: rootFolder) {
            let needed = entry.sizeBytes - staged
            if free < needed + 200_000_000 {
                throw RenderedError.message("Not enough free space on this Vision Pro: it needs \(RenderedFiles.byteText(needed)), \(RenderedFiles.byteText(max(free, 0))) is free.")
            }
        }

        var done: Int64 = 0
        downloads[id]?.stage = .downloading
        for (path, file) in ordered {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Already here: complete and verified, or unchanged in the installed copy (Update).
            if RenderedFiles.fileSize(destination) == file.bytes,
               (try? await Self.hash(destination)) == file.sha256.lowercased() {
                done += file.bytes
                downloads[id]?.received = done
                continue
            }
            if let installed, installed.origin?.files[path] == file {
                let source = installed.folder.appendingPathComponent(path)
                if RenderedFiles.fileSize(source) == file.bytes {
                    try? fm.removeItem(at: destination)
                    if (try? fm.copyItem(at: source, to: destination)) != nil {
                        done += file.bytes
                        downloads[id]?.received = done
                        continue
                    }
                }
            }

            var offset = RenderedFiles.fileSize(destination) ?? 0
            if offset >= file.bytes {
                try? fm.removeItem(at: destination)
                offset = 0
            }
            guard let url = Self.memberURL(address: address, folder: entry.folder, path: path) else {
                throw RenderedError.message("The library listed an invalid file name.")
            }
            let transfer = ResumableTransfer(url: url, destination: destination, offset: offset)
            let base = done
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let self, self.downloads[id] != nil {
                        let received = base + transfer.received
                        if self.downloads[id]?.received != received { self.downloads[id]?.received = received }
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { poll.cancel() }
            try await transfer.run()
            try Task.checkCancellation()
            let size = RenderedFiles.fileSize(destination) ?? 0
            let hash = try await Self.hash(destination)
            guard size == file.bytes, hash == file.sha256.lowercased() else {
                try? fm.removeItem(at: destination)
                throw RenderedError.message("\(path) didn't arrive intact. Tap Download to fetch it again.")
            }
            done += file.bytes
            downloads[id]?.received = done
        }

        downloads[id]?.stage = .finishing
        // Nothing but the listed files goes into place.
        let listed = Set(entry.files.keys)
        if let enumerator = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey]) {
            let prefix = staging.standardizedFileURL.path + "/"
            for case let url as URL in enumerator.allObjects {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                if !listed.contains(relative) { try? fm.removeItem(at: url) }
            }
        }
        let origin = Origin(entry: entry, addedAt: Date())
        try JSONEncoder().encode(origin).write(to: staging.appendingPathComponent(Self.originName), options: .atomic)
        let target = installed?.folder
            ?? rootFolder.appendingPathComponent(RenderedFiles.sanitizedName(id), isDirectory: true)
        try RenderedFiles.moveIntoPlace(staging: staging, final: target)
    }

    /// SHA-256 of a file, read in 4 MB chunks off the main actor.
    nonisolated static func hash(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
