import Foundation
import Observation

/// Rendered scenes on this Vision Pro (Documents/Rendered) and the QVision Library on the PC
/// (`tools/library-server/qvision_library.py`, HTTP on port 8770, LAN only).
///
/// v0.9:
/// - the Rendered tab connects by itself (`poll`), quietly, every few seconds while visible;
/// - `GET /health` tells "library up" from "nothing there" from "something else answers";
/// - downloads resume: the USDZ is written to `Documents/Rendered/.resume-<id>/` and an
///   interrupted transfer continues with an HTTP Range request. The folder becomes a scene only
///   when the file is complete and its size verified (rename into place);
/// - sidecars of downloaded scenes are refreshed from the PC whenever the library is reachable
///   (they are tiny), so new viewpoints arrive without downloading the scene again.
@MainActor
@Observable
final class RenderedLibrary {
    static let port = 8770
    private static let hostKey = "rendered.libraryHost"

    struct Download: Equatable {
        enum Stage: Equatable { case preparing, downloading, finishing }
        var title: String
        var stage: Stage
        var received: Int64
        var expected: Int64

        var fraction: Double? {
            guard expected > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(expected)))
        }
    }

    enum IndexState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Scenes stored on this Vision Pro, newest first.
    private(set) var scenes: [RenderedScene] = []

    /// The PC library's index (last successful fetch) and where it came from.
    private(set) var entries: [LibraryEntry] = []
    private(set) var indexState: IndexState = .idle
    private(set) var indexHost: String? = nil
    /// The address of the last attempt (shown in the "can't reach" help).
    private(set) var triedAddress: String? = nil
    /// `version` from /health (nil = unknown / library version 1).
    private(set) var libraryVersion: Int? = nil

    /// Running downloads by library entry id.
    private(set) var downloads: [String: Download] = [:]
    /// v0.10: "Download the whole group" queue (one download at a time), by entry id.
    private(set) var queued: [String] = []
    /// v0.10: sidecars of the PC's entries (tiny), so Environments can be grouped before download.
    private(set) var remoteSidecars: [String: RenderedSidecar] = [:]
    /// Bytes already on this Vision Pro of interrupted downloads, by library entry id.
    private(set) var partials: [String: Int64] = [:]

    /// "Copying Casa.usdz…" while an import from Files runs.
    private(set) var importStatus: String? = nil

    var lastError: String? = nil

    /// The PC address typed in the Rendered tab. Empty = use the saved "My PC" server's address.
    var hostOverride: String = "" {
        didSet { UserDefaults.standard.set(hostOverride, forKey: Self.hostKey) }
    }

    @ObservationIgnored let rootFolder: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var userCancelled: Set<String> = []
    @ObservationIgnored private var indexTask: Task<Void, Never>? = nil
    @ObservationIgnored private var isFetchingIndex = false
    @ObservationIgnored private var lastSidecarSync: TimeInterval = 0
    /// Which version of each entry's sidecar `remoteSidecars` holds ("modified|size").
    @ObservationIgnored private var remoteSidecarKeys: [String: String] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let root = RenderedFiles.rootFolder()
        rootFolder = root
        RenderedFiles.removeLeftovers(in: root)
        hostOverride = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        refresh()
    }

    // MARK: - On this Vision Pro

    func refresh() {
        scenes = RenderedFiles.scan(root: rootFolder)
        var found: [String: Int64] = [:]
        for folder in RenderedFiles.resumeFolders(in: rootFolder) {
            guard let meta = Self.loadResumeMeta(folder) else { continue }
            let file = folder.appendingPathComponent(meta.file, isDirectory: false)
            if let size = RenderedFiles.fileSize(file), size > 0 {
                found[meta.id] = size
            }
        }
        partials = found
    }

    func scene(id: String) -> RenderedScene? {
        scenes.first { $0.id == id }
    }

    /// Deletes a stored scene (frees its space). The caller makes sure it isn't open.
    func delete(_ scene: RenderedScene) {
        do {
            try FileManager.default.removeItem(at: scene.folder)
            RenderedViewer.forgetLastPose(sceneID: scene.id)
        } catch {
            lastError = "“\(scene.title)” couldn't be deleted: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Settings › Free up space: every downloaded scene (they can be downloaded again).
    func deleteAllScenes(except keepID: String?) {
        for scene in scenes where scene.id != keepID {
            try? FileManager.default.removeItem(at: scene.folder)
            RenderedViewer.forgetLastPose(sceneID: scene.id)
        }
        refresh()
    }

    /// Settings › Free up space: interrupted downloads that aren't running now.
    func clearPartialDownloads() {
        let active = Set(downloads.keys.map(Self.resumeFolderName))
        for folder in RenderedFiles.resumeFolders(in: rootFolder) where !active.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
        refresh()
    }

    var totalBytes: Int64 {
        scenes.reduce(0) { $0 + $1.sizeBytes }
    }

    var partialBytes: Int64 {
        partials.values.reduce(0, +)
    }

    // MARK: - On my PC

    /// `host` or `host:port` -> (host, port), or nil if the host isn't a valid IPv4 / hostname.
    static func parseAddress(_ raw: String) -> (host: String, port: Int)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["http://", "https://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        var port = Self.port
        if let colon = text.lastIndex(of: ":") {
            let portText = text[text.index(after: colon)...]
            guard let value = Int(portText), (1...65_535).contains(value) else { return nil }
            port = value
            text = String(text[..<colon])
        }
        let host = StreamHostValidator.normalized(text)
        guard StreamHostValidator.isValid(host) else { return nil }
        return (host, port)
    }

    static func baseURL(for address: String) -> URL? {
        guard let parsed = parseAddress(address) else { return nil }
        return URL(string: "http://\(parsed.host):\(parsed.port)")
    }

    /// URL of a file served by the library at `address`.
    static func fileURL(address: String, name: String) -> URL? {
        guard let base = baseURL(for: address) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: base.absoluteString + "/files/" + encoded)
    }

    /// Called by the Rendered tab every few seconds while it is visible: connects, reconnects
    /// and refreshes without any spinner flicker.
    func poll(address: String) {
        guard !isFetchingIndex else { return }
        fetchIndex(address: address, quiet: indexState != .idle)
    }

    /// Fetches `GET /health` then `GET /index.json` from the library at `address`.
    /// `quiet`: keep showing what is shown now until the answer arrives.
    func fetchIndex(address: String, quiet: Bool = false) {
        indexTask?.cancel()
        triedAddress = address
        guard let base = Self.baseURL(for: address),
              let healthURL = URL(string: base.absoluteString + "/health"),
              let indexURL = URL(string: base.absoluteString + "/index.json") else {
            indexState = .failed("Enter the PC's IP address (for example 192.168.0.87).")
            return
        }
        if !quiet { indexState = .loading }
        isFetchingIndex = true
        indexTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isFetchingIndex = false }
            do {
                // 1. Is anything there, and is it the library?
                var health = URLRequest(url: healthURL)
                health.timeoutInterval = 4
                let (healthData, healthResponse) = try await self.session.data(for: health)
                try Task.checkCancellation()
                let healthStatus = (healthResponse as? HTTPURLResponse)?.statusCode ?? 0
                if healthStatus == 403 {
                    throw RenderedError.message("The QVision Library refused this headset (LAN clients only). Check that the headset and the PC are on the same network.")
                }
                var version: Int? = nil
                if healthStatus == 200,
                   let object = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any],
                   (object["name"] as? String) == "QVision Library" {
                    version = object["version"] as? Int
                } else if healthStatus != 404 {
                    // 404 = the first library version (no /health): the index decides.
                    throw RenderedError.message(Self.wrongProgramText(address))
                }

                // 2. The index.
                var request = URLRequest(url: indexURL)
                request.timeoutInterval = 8
                let (data, response) = try await self.session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) else {
                    throw RenderedError.message(Self.wrongProgramText(address))
                }
                let listed = decoded.filter { $0.file.lowercased().hasSuffix(".usdz") }
                // Sidecars first, so a new Environment appears in its group straight away.
                await self.fetchRemoteSidecars(listed, address: address)
                try Task.checkCancellation()
                if self.entries != listed { self.entries = listed }
                self.libraryVersion = version
                self.indexHost = address
                if self.indexState != .loaded { self.indexState = .loaded }
                await self.syncSidecars(address: address)
            } catch is CancellationError {
                // A newer fetch replaced this one.
            } catch let error as URLError where error.code == .cancelled {
                // Replaced.
            } catch {
                let message = Self.describeNetworkError(error, address: address)
                if self.indexState != .failed(message) { self.indexState = .failed(message) }
            }
        }
    }

    private static func wrongProgramText(_ address: String) -> String {
        let place = parseAddress(address).map { "\($0.host):\($0.port)" } ?? address
        return "Something answers at \(place), but it isn't the QVision Library. Check the address: it is the one shown in the QVision Library (PC) window."
    }

    /// The stored copy of a library entry, if any.
    func localScene(for entry: LibraryEntry) -> RenderedScene? {
        if let byOrigin = scenes.first(where: { $0.origin?.libraryID == entry.id }) {
            return byOrigin
        }
        return scenes.first { $0.id == RenderedFiles.sanitizedName(entry.id) }
    }

    /// The library entry a stored scene came from (if the PC lists it now).
    func entry(for scene: RenderedScene) -> LibraryEntry? {
        guard indexState == .loaded else { return nil }
        return entries.first { localScene(for: $0)?.id == scene.id }
    }

    /// true if the stored copy matches the PC's file (same size and date).
    func isUpToDate(_ entry: LibraryEntry) -> Bool {
        guard let local = localScene(for: entry) else { return false }
        guard let origin = local.origin, origin.source == "library" else { return true }
        return origin.sizeBytes == entry.sizeBytes && origin.modified == entry.modified
    }

    /// A stored scene whose PC copy changed since it was downloaded.
    func hasUpdate(_ scene: RenderedScene) -> Bool {
        guard let entry = entry(for: scene) else { return false }
        return !isUpToDate(entry)
    }

    /// Copies newer sidecars from the PC next to the scenes already downloaded (at most once a
    /// minute). A scene baked before viewpoints existed gets them this way.
    private func syncSidecars(address: String) async {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSidecarSync > 60 else { return }
        lastSidecarSync = now
        var changed = false
        for entry in entries {
            guard let listed = entry.sidecar, let name = RenderedFiles.safeFileName(listed),
                  let local = localScene(for: entry),
                  local.origin?.source == "library",
                  downloads[entry.id] == nil,
                  let url = Self.fileURL(address: address, name: name),
                  let data = try? await fetchData(url),
                  (try? JSONDecoder().decode(RenderedSidecar.self, from: data)) != nil else { continue }
            let stem = local.usdzURL.deletingPathExtension().lastPathComponent
            let target = local.sidecarURL ?? local.folder.appendingPathComponent(stem + ".json", isDirectory: false)
            if (try? Data(contentsOf: target)) != data {
                if (try? data.write(to: target, options: .atomic)) != nil {
                    changed = true
                }
            }
        }
        if changed { refresh() }
    }

    // MARK: - Downloads (resumable)

    private struct ResumeMeta: Codable {
        var id: String
        var file: String
        var modified: String?
        var sizeBytes: Int64
    }

    private static func resumeFolderName(_ entryID: String) -> String {
        RenderedFiles.resumePrefix + RenderedFiles.sanitizedName(entryID)
    }

    private static func loadResumeMeta(_ folder: URL) -> ResumeMeta? {
        let url = folder.appendingPathComponent(RenderedFiles.resumeMetaName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResumeMeta.self, from: data)
    }

    func download(_ entry: LibraryEntry) {
        guard downloads[entry.id] == nil, let address = indexHost else { return }
        let already = partials[entry.id] ?? 0
        downloads[entry.id] = Download(title: entry.title, stage: .preparing, received: already, expected: entry.sizeBytes)
        let id = entry.id
        userCancelled.remove(id)
        downloadTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performDownload(entry, address: address)
            } catch {
                let cancelled = (error is CancellationError) || ((error as? URLError)?.code == .cancelled)
                if cancelled || self.userCancelled.contains(id) {
                    if self.userCancelled.contains(id) {
                        // Cancel = discard what arrived. (An interruption keeps it for Resume.)
                        let folder = self.rootFolder.appendingPathComponent(Self.resumeFolderName(id), isDirectory: true)
                        try? FileManager.default.removeItem(at: folder)
                    }
                } else {
                    self.lastError = "“\(entry.title)” stopped downloading. " + Self.describeNetworkError(error, address: address)
                        + " What arrived is kept: tap Resume to continue."
                }
            }
            self.userCancelled.remove(id)
            self.downloads[id] = nil
            self.downloadTasks[id] = nil
            self.queued.removeAll { $0 == id }
            self.refresh()
            self.pumpQueue()
        }
    }

    func cancelDownload(_ id: String) {
        queued.removeAll { $0 == id }
        userCancelled.insert(id)
        downloadTasks[id]?.cancel()
    }

    // MARK: - Environments (v0.10)

    /// Environment scenes on this Vision Pro in `group`, by `order` then title.
    func rooms(inGroup group: String?) -> [RenderedScene] {
        guard let group else { return [] }
        return scenes
            .filter { $0.environment?.group == group }
            .sorted { lhs, rhs in
                let a = lhs.environment?.order ?? Int.max
                let b = rhs.environment?.order ?? Int.max
                return a != b ? a < b : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// The PC entry's sidecar says it is an Environment.
    func isEnvironment(_ entry: LibraryEntry) -> Bool {
        remoteSidecars[entry.id]?.isEnvironment ?? false
    }

    /// Downloads every entry of `entries` that isn't on this Vision Pro or is out of date, one
    /// after another (a group can be several GB; one transfer at a time keeps each one fast).
    func downloadAll(_ entries: [LibraryEntry]) {
        for entry in entries where !isUpToDate(entry) && downloads[entry.id] == nil && !queued.contains(entry.id) {
            queued.append(entry.id)
        }
        pumpQueue()
    }

    func isQueued(_ id: String) -> Bool { queued.contains(id) }

    private func pumpQueue() {
        // One queued download at a time (single downloads started by hand run alongside).
        guard !queued.contains(where: { downloads[$0] != nil }) else { return }
        while let next = queued.first {
            guard let entry = entries.first(where: { $0.id == next }), !isUpToDate(entry) else {
                queued.removeFirst()
                continue
            }
            download(entry)
            return
        }
    }

    private func fetchRemoteSidecars(_ listed: [LibraryEntry], address: String) async {
        var sidecars = remoteSidecars
        var changed = false
        let ids = Set(listed.map(\.id))
        for id in sidecars.keys where !ids.contains(id) {
            sidecars[id] = nil
            remoteSidecarKeys[id] = nil
            changed = true
        }
        for entry in listed {
            let key = "\(entry.modified ?? "")|\(entry.sizeBytes)"
            guard remoteSidecarKeys[entry.id] != key else { continue }
            guard let listedName = entry.sidecar, let name = RenderedFiles.safeFileName(listedName),
                  let url = Self.fileURL(address: address, name: name) else {
                remoteSidecarKeys[entry.id] = key
                if sidecars[entry.id] != nil { sidecars[entry.id] = nil; changed = true }
                continue
            }
            guard let data = try? await fetchData(url),
                  let sidecar = try? JSONDecoder().decode(RenderedSidecar.self, from: data) else { continue }
            remoteSidecarKeys[entry.id] = key
            if sidecars[entry.id] != sidecar {
                sidecars[entry.id] = sidecar
                changed = true
            }
        }
        if changed { remoteSidecars = sidecars }
    }

    var isDownloading: Bool { !downloads.isEmpty }

    private func performDownload(_ entry: LibraryEntry, address: String) async throws {
        let fm = FileManager.default
        guard let usdzName = RenderedFiles.safeFileName(entry.file),
              usdzName.lowercased().hasSuffix(".usdz"),
              let usdzURL = Self.fileURL(address: address, name: usdzName) else {
            throw RenderedError.message("The library listed an invalid file name.")
        }

        // Staging folder: reused if it holds the same file (same name, size and date).
        let staging = rootFolder.appendingPathComponent(Self.resumeFolderName(entry.id), isDirectory: true)
        if let meta = Self.loadResumeMeta(staging),
           meta.file != usdzName || meta.sizeBytes != entry.sizeBytes || meta.modified != entry.modified {
            try? fm.removeItem(at: staging)
        } else if fm.fileExists(atPath: staging.path), Self.loadResumeMeta(staging) == nil {
            try? fm.removeItem(at: staging)
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let meta = ResumeMeta(id: entry.id, file: usdzName, modified: entry.modified, sizeBytes: entry.sizeBytes)
        try JSONEncoder().encode(meta).write(to: staging.appendingPathComponent(RenderedFiles.resumeMetaName, isDirectory: false), options: .atomic)

        let destination = staging.appendingPathComponent(usdzName, isDirectory: false)
        var offset = RenderedFiles.fileSize(destination) ?? 0
        if entry.sizeBytes > 0, offset > entry.sizeBytes {
            try? fm.removeItem(at: destination)
            offset = 0
        }

        if let free = RenderedFiles.availableCapacity(at: rootFolder), entry.sizeBytes > 0 {
            let needed = entry.sizeBytes - offset
            if free < needed + 200_000_000 {
                throw RenderedError.message("Not enough free space on this Vision Pro: it needs \(RenderedFiles.byteText(needed)), \(RenderedFiles.byteText(max(free, 0))) is free. Delete a scene first (Settings › Storage).")
            }
        }

        // 1. Sidecar (required if listed: without it the start position would be wrong).
        if let listed = entry.sidecar, let name = RenderedFiles.safeFileName(listed),
           let url = Self.fileURL(address: address, name: name) {
            let data = try await fetchData(url)
            try data.write(to: staging.appendingPathComponent(name, isDirectory: false), options: .atomic)
        }
        // 2. Thumbnail (optional).
        if let listed = entry.thumbnail, let name = RenderedFiles.safeFileName(listed),
           let url = Self.fileURL(address: address, name: name),
           let data = try? await fetchData(url) {
            try? data.write(to: staging.appendingPathComponent(name, isDirectory: false), options: .atomic)
        }
        try Task.checkCancellation()

        // 3. The scene itself, continuing where a previous attempt stopped.
        let id = entry.id
        downloads[id]?.stage = .downloading
        downloads[id]?.received = offset
        if !(entry.sizeBytes > 0 && offset == entry.sizeBytes) {
            let transfer = ResumableTransfer(url: usdzURL, destination: destination, offset: offset)
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if let self, var state = self.downloads[id] {
                        let received = transfer.received
                        let total = transfer.total
                        if state.received != received || (total > 0 && state.expected != total) {
                            state.received = received
                            if total > 0 { state.expected = total }
                            self.downloads[id] = state
                        }
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { poll.cancel() }
            try await transfer.run()
        }
        try Task.checkCancellation()

        downloads[id]?.stage = .finishing
        let size = RenderedFiles.fileSize(destination) ?? 0
        if entry.sizeBytes > 0, size != entry.sizeBytes {
            // The file on the PC changed mid-download, or the data is wrong: start clean next time.
            try? fm.removeItem(at: staging)
            throw RenderedError.message("The file didn't arrive complete (\(RenderedFiles.byteText(size)) of \(RenderedFiles.byteText(entry.sizeBytes))). Tap Download to start again.")
        }

        try? fm.removeItem(at: staging.appendingPathComponent(RenderedFiles.resumeMetaName, isDirectory: false))
        try RenderedFiles.writeOrigin(RenderedOrigin(source: "library", libraryID: entry.id, host: address,
                                                     modified: entry.modified, sizeBytes: entry.sizeBytes,
                                                     title: entry.title, addedAt: Date()),
                                      into: staging)

        let existing = localScene(for: entry)?.id
        let folderName = existing ?? RenderedFiles.uniqueFolderName(RenderedFiles.sanitizedName(entry.id), in: rootFolder)
        try RenderedFiles.moveIntoPlace(staging: staging, final: rootFolder.appendingPathComponent(folderName, isDirectory: true))
    }

    private func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RenderedError.message("The library answered HTTP \(code) for \(url.lastPathComponent).")
        }
        return data
    }

    // MARK: - Import from Files

    /// Imports the picked files: every .usdz, each paired with the .json (sidecar) and
    /// .jpg/.png (thumbnail) of the same name. With one .usdz, a single .json / image is used
    /// whatever its name.
    func importFiles(_ urls: [URL]) async {
        let models = urls.filter { $0.pathExtension.lowercased() == "usdz" }
        guard !models.isEmpty else {
            lastError = "Pick a .usdz scene (you can select its .json sidecar together with it)."
            return
        }
        let sidecars = urls.filter { $0.pathExtension.lowercased() == "json" }
        let images = urls.filter { RenderedFiles.thumbnailExtensions.contains($0.pathExtension.lowercased()) }

        func partner(for model: URL, in candidates: [URL]) -> URL? {
            let stem = model.deletingPathExtension().lastPathComponent.lowercased()
            if let match = candidates.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == stem }) {
                return match
            }
            return (models.count == 1 && candidates.count == 1) ? candidates[0] : nil
        }

        var errors: [String] = []
        let root = rootFolder
        for model in models {
            let sidecar = partner(for: model, in: sidecars)
            let thumbnail = partner(for: model, in: images)
            if let size = RenderedFiles.fileSize(model), size > 0 {
                importStatus = "Copying \(model.lastPathComponent) (\(RenderedFiles.byteText(size)))…"
            } else {
                importStatus = "Copying \(model.lastPathComponent)…"
            }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try RenderedFiles.importPackage(usdz: model, sidecar: sidecar, thumbnail: thumbnail, root: root)
                }.value
            } catch {
                errors.append("“\(model.lastPathComponent)”: \(error.localizedDescription)")
            }
            refresh()
        }
        importStatus = nil
        refresh()
        if !errors.isEmpty {
            lastError = "Import failed. " + errors.joined(separator: "\n")
        }
    }

    // MARK: - Errors

    static func describeNetworkError(_ error: Error, address: String) -> String {
        if let rendered = error as? RenderedError {
            return rendered.localizedDescription
        }
        let place = parseAddress(address).map { "\($0.host):\($0.port)" } ?? address
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .dnsLookupFailed:
                return "No answer from \(place). Start “QVision Library (PC)” on your PC (Desktop › Vision Pro). It now also starts with Windows."
            case .notConnectedToInternet:
                return "No network. Check Wi-Fi, and allow QVision on the local network (Settings › Privacy & Security › Local Network)."
            case .appTransportSecurityRequiresSecureConnection:
                return "\(place) isn't a local network address. Use the PC's LAN IP address."
            default:
                return "Network error at \(place): \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}

/// One HTTP GET written straight to a file, continuing at `offset` with a Range request.
/// 206 = the server continues: append. 200 = it sends everything: start the file again.
/// Thread-safe counters are polled from the main actor for the progress bar.
private final class ResumableTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let offset: Int64

    private let lock = NSLock()
    private var receivedBytes: Int64
    private var totalBytes: Int64 = 0
    private var handle: FileHandle?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var isCancelled = false

    init(url: URL, destination: URL, offset: Int64) {
        self.url = url
        self.destination = destination
        self.offset = offset
        self.receivedBytes = offset
    }

    var received: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes
    }

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 6 * 60 * 60
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url)
                if offset > 0 {
                    request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                }
                let task = session.dataTask(with: request)
                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                let cancelled = isCancelled
                lock.unlock()
                if cancelled {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let fm = FileManager.default
        do {
            switch status {
            case 206:
                if !fm.fileExists(atPath: destination.path) {
                    fm.createFile(atPath: destination.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: destination)
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seek(toOffset: UInt64(offset))
                lock.lock()
                self.handle = handle
                receivedBytes = offset
                totalBytes = offset + max(response.expectedContentLength, 0)
                lock.unlock()
            case 200:
                fm.createFile(atPath: destination.path, contents: nil)
                let handle = try FileHandle(forWritingTo: destination)
                lock.lock()
                self.handle = handle
                receivedBytes = 0
                totalBytes = max(response.expectedContentLength, 0)
                lock.unlock()
            case 416:
                // Our partial file doesn't match the server's any more: start over next time.
                try? fm.removeItem(at: destination)
                throw RenderedError.message("The file on the PC changed. Tap Download to start again.")
            default:
                throw RenderedError.message("The library answered HTTP \(status).")
            }
            completionHandler(.allow)
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handle = self.handle
        lock.unlock()
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            lock.lock()
            receivedBytes += Int64(data.count)
            lock.unlock()
        } catch {
            lock.lock()
            if failure == nil { failure = error }
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let handle = self.handle
        self.handle = nil
        let continuation = self.continuation
        self.continuation = nil
        let stored = failure
        let cancelled = isCancelled
        self.task = nil
        self.session = nil
        lock.unlock()

        try? handle?.close()
        session.finishTasksAndInvalidate()

        if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let stored {
            continuation?.resume(throwing: stored)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
