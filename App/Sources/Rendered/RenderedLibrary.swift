import Foundation
import Observation

/// Rendered scenes on this Vision Pro (Documents/Rendered) and the QVision Library on the PC
/// (`tools/library-server/qvision_library.py`, HTTP on port 8770, LAN only).
///
/// Downloads go into a staging folder and are renamed into place only when every file arrived
/// complete; cancel or failure deletes the staging folder (no partial scene is ever listed).
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

    /// Running downloads by library entry id.
    private(set) var downloads: [String: Download] = [:]

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
    @ObservationIgnored private var indexTask: Task<Void, Never>? = nil

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
    }

    func scene(id: String) -> RenderedScene? {
        scenes.first { $0.id == id }
    }

    /// Deletes a stored scene (frees its space). The caller makes sure it isn't open.
    func delete(_ scene: RenderedScene) {
        do {
            try FileManager.default.removeItem(at: scene.folder)
        } catch {
            lastError = "“\(scene.title)” couldn't be deleted: \(error.localizedDescription)"
        }
        refresh()
    }

    var totalBytes: Int64 {
        scenes.reduce(0) { $0 + $1.sizeBytes }
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

    /// Fetches `GET /index.json` from the library at `address`.
    func fetchIndex(address: String) {
        indexTask?.cancel()
        guard let base = Self.baseURL(for: address),
              let url = URL(string: base.absoluteString + "/index.json") else {
            indexState = .failed("Enter the PC's IP address (for example 192.168.0.87).")
            return
        }
        indexState = .loading
        let host = address
        indexTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                let (data, response) = try await self.session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw RenderedError.message("The PC didn't answer with HTTP.")
                }
                guard http.statusCode == 200 else {
                    if http.statusCode == 403 {
                        throw RenderedError.message("The QVision Library refused this headset (LAN clients only). Check that the headset and the PC are on the same network.")
                    }
                    throw RenderedError.message("The QVision Library answered HTTP \(http.statusCode).")
                }
                let decoded: [LibraryEntry]
                do {
                    decoded = try JSONDecoder().decode([LibraryEntry].self, from: data)
                } catch {
                    throw RenderedError.message("The PC answered, but not with a QVision Library index. Is another program using port \(Self.port)?")
                }
                self.entries = decoded.filter { $0.file.lowercased().hasSuffix(".usdz") }
                self.indexHost = host
                self.indexState = .loaded
            } catch is CancellationError {
                // A newer fetch replaced this one.
            } catch let error as URLError where error.code == .cancelled {
                // Replaced.
            } catch {
                self.indexState = .failed(Self.describeNetworkError(error, address: address))
            }
        }
    }

    /// The stored copy of a library entry, if any.
    func localScene(for entry: LibraryEntry) -> RenderedScene? {
        if let byOrigin = scenes.first(where: { $0.origin?.libraryID == entry.id }) {
            return byOrigin
        }
        return scenes.first { $0.id == RenderedFiles.sanitizedName(entry.id) }
    }

    /// true if the stored copy matches the PC's file (same size and date).
    func isUpToDate(_ entry: LibraryEntry) -> Bool {
        guard let local = localScene(for: entry) else { return false }
        guard let origin = local.origin, origin.source == "library" else { return true }
        return origin.sizeBytes == entry.sizeBytes && origin.modified == entry.modified
    }

    // MARK: - Downloads

    func download(_ entry: LibraryEntry) {
        guard downloads[entry.id] == nil, let address = indexHost else { return }
        downloads[entry.id] = Download(title: entry.title, stage: .preparing, received: 0, expected: entry.sizeBytes)
        let id = entry.id
        downloadTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performDownload(entry, address: address)
            } catch is CancellationError {
                // Cancelled by the user: the staging folder is already gone.
            } catch let error as URLError where error.code == .cancelled {
                // Cancelled.
            } catch {
                self.lastError = "“\(entry.title)” couldn't be downloaded. " + Self.describeNetworkError(error, address: address)
            }
            self.downloads[id] = nil
            self.downloadTasks[id] = nil
            self.refresh()
        }
    }

    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    var isDownloading: Bool { !downloads.isEmpty }

    private func performDownload(_ entry: LibraryEntry, address: String) async throws {
        let fm = FileManager.default
        guard let usdzName = RenderedFiles.safeFileName(entry.file),
              usdzName.lowercased().hasSuffix(".usdz"),
              let usdzURL = Self.fileURL(address: address, name: usdzName) else {
            throw RenderedError.message("The library listed an invalid file name.")
        }

        if let free = RenderedFiles.availableCapacity(at: rootFolder),
           entry.sizeBytes > 0, free < entry.sizeBytes + 200_000_000 {
            throw RenderedError.message("Not enough free space on this Vision Pro: it needs \(RenderedFiles.byteText(entry.sizeBytes)), \(RenderedFiles.byteText(max(free, 0))) is free. Delete a scene first.")
        }

        let staging = rootFolder.appendingPathComponent(RenderedFiles.partialPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var completed = false
        defer {
            if !completed { try? fm.removeItem(at: staging) }
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

        // 3. The scene itself, with progress.
        downloads[entry.id]?.stage = .downloading
        let destination = staging.appendingPathComponent(usdzName, isDirectory: false)
        let id = entry.id
        try await downloadFile(from: usdzURL, to: destination) { [weak self] received, expected in
            guard let self, var state = self.downloads[id] else { return }
            state.received = received
            if expected > 0 { state.expected = expected }
            self.downloads[id] = state
        }
        try Task.checkCancellation()

        downloads[entry.id]?.stage = .finishing
        let size = RenderedFiles.fileSize(destination) ?? 0
        if entry.sizeBytes > 0, size != entry.sizeBytes {
            throw RenderedError.message("The file arrived incomplete (\(RenderedFiles.byteText(size)) of \(RenderedFiles.byteText(entry.sizeBytes))). Try again.")
        }

        try RenderedFiles.writeOrigin(RenderedOrigin(source: "library", libraryID: entry.id, host: address,
                                                     modified: entry.modified, sizeBytes: entry.sizeBytes,
                                                     title: entry.title, addedAt: Date()),
                                      into: staging)
        try Task.checkCancellation()

        let existing = localScene(for: entry)?.id
        let folderName = existing ?? RenderedFiles.uniqueFolderName(RenderedFiles.sanitizedName(entry.id), in: rootFolder)
        try RenderedFiles.moveIntoPlace(staging: staging, final: rootFolder.appendingPathComponent(folderName, isDirectory: true))
        completed = true
    }

    private func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RenderedError.message("The library answered HTTP \(code) for \(url.lastPathComponent).")
        }
        return data
    }

    /// Downloads `url` into `destination` with a download task (the system writes it to a
    /// temporary file, which is moved to `destination` before the handler returns).
    /// `progress` is called on the main actor about four times a second.
    private func downloadFile(from url: URL, to destination: URL,
                              progress: @escaping @MainActor (Int64, Int64) -> Void) async throws {
        let box = DownloadTaskBox()
        let session = self.session

        let poll = Task { @MainActor in
            while !Task.isCancelled {
                if let task = box.current {
                    progress(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poll.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url) { temporaryURL, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: RenderedError.message("The PC didn't answer with HTTP."))
                        return
                    }
                    guard http.statusCode == 200 else {
                        continuation.resume(throwing: RenderedError.message("The library answered HTTP \(http.statusCode)."))
                        return
                    }
                    guard let temporaryURL else {
                        continuation.resume(throwing: RenderedError.message("The download produced no file."))
                        return
                    }
                    do {
                        let fm = FileManager.default
                        if fm.fileExists(atPath: destination.path) {
                            try fm.removeItem(at: destination)
                        }
                        try fm.moveItem(at: temporaryURL, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.start(task)
            }
        } onCancel: {
            box.cancel()
        }
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
        let where_ = parseAddress(address).map { "\($0.host):\($0.port)" } ?? address
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .dnsLookupFailed:
                return "Can't reach the QVision Library at \(where_). On the PC, open “QVision Library (PC)” (Desktop › Vision Pro), check the address, and run add-library-firewall.ps1 once as administrator."
            case .notConnectedToInternet:
                return "No network connection. Check Wi-Fi, and allow QVision on the local network (Settings › Privacy & Security › Local Network)."
            case .appTransportSecurityRequiresSecureConnection:
                return "This address isn't a local network address. Use the PC's LAN IP address."
            default:
                return "Network error at \(where_): \(urlError.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}

/// Holds the running URLSessionDownloadTask so it can be cancelled from any thread and polled
/// for progress from the main actor.
private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var isCancelled = false

    var current: URLSessionDownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    func start(_ newTask: URLSessionDownloadTask) {
        lock.lock()
        task = newTask
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            newTask.cancel()
        } else {
            newTask.resume()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let running = task
        lock.unlock()
        running?.cancel()
    }
}
