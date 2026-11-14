// This software contains source code provided by NVIDIA Corporation.
// Adapted from NVIDIA's CloudXR generic viewer sample (MIT):
// github.com/NVIDIA/cloudxr-apple-generic-viewer (SessionConfigView.doConnect, ViewerApp).

import Foundation
import Observation
import CloudXRKit

/// "Server" mode: one CloudXR session to a PC or the office server, reached by IP on the local
/// network (`.local(ip:)`, no GDN, no login).
///
/// The CloudXR `Session` is kept out of observation; its `state` is mirrored into `phase` by a
/// small polling task (~0.2 s) that runs only while a connection is in progress or alive.
/// A single session object is reused: every connect calls `configure(config:)` then `connect()`,
/// exactly as the sample does.
@MainActor
@Observable
final class ServerSessionController {
    static let streamSpaceID = "stream"

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case disconnecting
        case failed(String)
    }

    // MARK: - Observed state (contract)

    private(set) var servers: [StreamServer] = []
    private(set) var activeServerID: UUID? = nil
    private(set) var phase: Phase = .idle

    var quality: StreamQuality = .standard {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Keys.quality) }
    }

    var handTrackingEnabled: Bool = true {
        didSet { UserDefaults.standard.set(handTrackingEnabled, forKey: Keys.handTracking) }
    }

    /// false → Full immersion (default), true → Mixed (your room around the stream).
    var showRoom: Bool = false {
        didSet { UserDefaults.standard.set(showRoom, forKey: Keys.showRoom) }
    }

    /// Maintained by StreamImmersiveView (onAppear / onDisappear) and by ServerHomeView right
    /// after its open / dismiss calls return.
    var isStreamSpaceOpen: Bool = false

    // MARK: - Observed state (beyond the contract)

    /// `connect()` returned without throwing for the current attempt. This is the point where the
    /// sample's LaunchView opens the immersive space (its connect completion handler).
    private(set) var connectCallReturned: Bool = false

    /// Whether the stream ImmersiveSpace should be open right now. Mirrors both of the sample's
    /// open points: after `connect()` returns (LaunchView completion handler) and on `.connected`
    /// (WindowStateManager.handleConnectionEstablished), whichever comes first.
    var wantsStreamSpace: Bool {
        switch phase {
        case .connected:
            return true
        case .connecting:
            return connectCallReturned
        default:
            return false
        }
    }

    /// The CloudXR session for StreamImmersiveView's `CloudXRSessionComponent` (not observed;
    /// created on the first connect and reused afterwards).
    var streamSession: Session? { session }

    var activeServer: StreamServer? {
        guard let id = activeServerID else { return nil }
        return servers.first { $0.id == id }
    }

    // MARK: - Private

    private enum Keys {
        static let servers = "server.savedServers"
        static let quality = "server.quality"
        static let handTracking = "server.handTracking"
        static let showRoom = "server.showRoom"
    }

    @ObservationIgnored private var session: Session? = nil
    @ObservationIgnored private var pollTask: Task<Void, Never>? = nil
    /// Identifies the current connect attempt; nil after disconnect / failure (cancels stale work).
    @ObservationIgnored private var attemptID: UUID? = nil
    /// The session reported a live state during this attempt (so a `.disconnected` is not stale).
    @ObservationIgnored private var sawLiveState = false
    @ObservationIgnored private var reachedConnected = false
    @ObservationIgnored private var userRequestedDisconnect = false
    /// Shown as `.failed` once a disconnect requested with an error completes.
    @ObservationIgnored private var pendingFailure: String? = nil

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.servers),
           let list = try? JSONDecoder().decode([StreamServer].self, from: data) {
            servers = list
        }
        quality = defaults.string(forKey: Keys.quality).flatMap(StreamQuality.init(rawValue:)) ?? .standard
        handTrackingEnabled = (defaults.object(forKey: Keys.handTracking) as? Bool) ?? true
        showRoom = (defaults.object(forKey: Keys.showRoom) as? Bool) ?? false
    }

    // MARK: - Saved servers

    func addServer(name: String, host: String) {
        let cleanHost = StreamHostValidator.normalized(host)
        guard StreamHostValidator.isValid(cleanHost) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        servers.append(StreamServer(name: trimmedName.isEmpty ? cleanHost : trimmedName, host: cleanHost))
        saveServers()
    }

    func updateServer(_ server: StreamServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let cleanHost = StreamHostValidator.normalized(server.host)
        guard StreamHostValidator.isValid(cleanHost) else { return }
        var updated = server
        updated.host = cleanHost
        let trimmedName = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmedName.isEmpty ? cleanHost : trimmedName
        servers[index] = updated
        saveServers()
    }

    func deleteServer(_ id: UUID) {
        if activeServerID == id {
            switch phase {
            case .connecting, .connected, .disconnecting:
                disconnect()
            default:
                break
            }
            activeServerID = nil
            if case .failed = phase { phase = .idle }
        }
        servers.removeAll { $0.id == id }
        saveServers()
    }

    // MARK: - Connection

    /// Validates the host, builds the CloudXR config, creates (once) / configures the session
    /// and connects. Errors end up in `phase` as `.failed(message)`.
    func connect(to id: UUID) async {
        guard let server = servers.first(where: { $0.id == id }) else { return }

        if activeServerID == id {
            switch phase {
            case .connecting, .connected:
                return // already on it
            default:
                break
            }
        }

        // Switching servers (or a session left alive): end it first, as the sample does
        // ("To be safe, disconnect from previous session"), and wait for it to settle.
        if let existing = session, Self.isLive(existing.state) {
            await endLiveSession()
        }

        let attempt = UUID()
        attemptID = attempt
        activeServerID = id
        userRequestedDisconnect = false
        pendingFailure = nil
        sawLiveState = false
        reachedConnected = false
        connectCallReturned = false
        phase = .connecting

        let host = StreamHostValidator.normalized(server.host)
        guard StreamHostValidator.isValid(host) else {
            fail("Invalid address “\(server.host)”. Enter an IPv4 address (e.g. 192.168.0.87) or a hostname.")
            return
        }

        // CloudXR's local connection takes an IP: resolve hostnames ourselves.
        let ip: String
        if StreamHostValidator.isIPv4(host) {
            ip = host
        } else {
            let resolved = await Self.resolveIPv4(host)
            guard attemptID == attempt else { return }
            guard let resolved else {
                fail("Couldn't find “\(host)” on the network. Check the name, or enter the PC's IP address instead.")
                return
            }
            ip = resolved
        }
        guard attemptID == attempt else { return }

        var config = CloudXRKit.Config()
        config.resolutionPreset = (quality == .performance) ? .performancePreset : .standardPreset
        #if targetEnvironment(simulator)
        config.handTrackingMode = handTrackingEnabled ? .simulated : .disabled
        #else
        config.handTrackingMode = handTrackingEnabled ? .prediction : .disabled
        #endif
        config.connectionType = .local(ip: ip)

        // Same calls, through the stored optional, as the sample's doConnect().
        if session == nil {
            session = CloudXRSession(config: config)
        }
        session?.configure(config: config)

        startPolling()

        do {
            try await session?.connect()
            guard attemptID == attempt else {
                // Cancelled (Disconnect / Cancel) while connect() was running: don't leave it alive.
                if let current = session, Self.isLive(current.state) {
                    session?.disconnect()
                }
                return
            }
            connectCallReturned = true
            startPolling()
        } catch {
            guard attemptID == attempt, !userRequestedDisconnect else { return }
            fail(Self.message(forThrown: error))
        }
    }

    /// Ends the stream (or cancels a connect in progress). Returns to `.idle`.
    func disconnect() {
        requestDisconnect(failure: nil)
    }

    // MARK: - Beyond the contract

    /// Ends the stream and shows `message` as `.failed` once it's down (e.g. the stream view
    /// couldn't be opened).
    func disconnect(withError message: String) {
        requestDisconnect(failure: message)
    }

    /// Reconnects to the last server (the Retry button).
    func retry() async {
        guard let id = activeServerID else { return }
        await connect(to: id)
    }

    /// Clears a `.failed` message (back to `.idle`).
    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// Headset taken off / app backgrounded while streaming (sample's iOS scenePhase branch).
    func pauseForBackground() {
        switch session?.state {
        case .connecting, .connected:
            session?.pause()
        default:
            break
        }
    }

    /// Back to `.active`: resume a paused stream.
    func resumeIfPaused() {
        guard session?.state == .paused else { return }
        do {
            try session?.resume()
        } catch {
            disconnect(withError: "Couldn't resume the stream: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: lifecycle

    private func requestDisconnect(failure: String?) {
        attemptID = nil // cancels an attempt that is still resolving / connecting
        userRequestedDisconnect = true
        pendingFailure = failure
        connectCallReturned = false

        guard let current = session, Self.isLive(current.state) else {
            stopPolling()
            if let failure {
                phase = .failed(failure)
            } else {
                phase = .idle
            }
            pendingFailure = nil
            return
        }

        phase = .disconnecting
        if current.state != .disconnecting {
            session?.disconnect()
        }
        startPolling()
    }

    private func endLiveSession() async {
        stopPolling()
        attemptID = nil
        userRequestedDisconnect = true
        connectCallReturned = false
        phase = .disconnecting
        if session?.state != .disconnecting {
            session?.disconnect()
        }
        // Up to ~5 s for the old session to settle.
        for _ in 0..<50 {
            guard let current = session, Self.isLive(current.state) else { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func fail(_ message: String) {
        attemptID = nil
        connectCallReturned = false
        if let current = session, Self.isLive(current.state) {
            // Make sure nothing keeps running behind the error.
            userRequestedDisconnect = true
            session?.disconnect()
        }
        stopPolling()
        phase = .failed(message)
    }

    // MARK: - Private: state mirroring

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.refreshPhase() else { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Mirrors `session.state` into `phase`. Returns false when polling should stop.
    private func refreshPhase() -> Bool {
        guard let session else {
            finishDisconnected(errorText: nil)
            return false
        }

        switch session.state {
        case .connecting, .authenticating, .authenticated:
            sawLiveState = true
            if !userRequestedDisconnect { setPhase(.connecting) }
            return true

        case .connected:
            sawLiveState = true
            reachedConnected = true
            if !userRequestedDisconnect { setPhase(.connected) }
            return true

        case .paused, .pausing, .resuming:
            // Still a live stream (headset off / app in background): keep the current phase.
            sawLiveState = true
            return true

        case .disconnecting:
            sawLiveState = true
            setPhase(.disconnecting)
            return true

        case .disconnected(let result):
            if !userRequestedDisconnect, !sawLiveState, !connectCallReturned {
                // Left over from a previous attempt: connect() hasn't moved the state yet.
                return true
            }
            var errorText: String? = nil
            switch result {
            case .failure(let error):
                let detail = error.localizedDescription
                switch error {
                case .failedConnectionAttempt:
                    errorText = "Server not reachable: check the IP, that CloudXR Runtime is running, and the firewall. (\(detail))"
                case .invalidServerURL:
                    errorText = "Invalid address. (\(detail))"
                case .dns:
                    errorText = "Couldn't resolve the server name: check the headset's network connection. (\(detail))"
                case .pauseTimeout:
                    errorText = "The stream was paused too long and the server ended it. Connect again. (\(detail))"
                case .sessionTerminatedUnknownReason:
                    errorText = "The server ended the session: check that the OpenXR app is still running. (\(detail))"
                default:
                    errorText = "\(detail) (\(error.kind))"
                }
            default:
                break
            }
            finishDisconnected(errorText: errorText)
            return false

        case .initialized:
            if case .connecting = phase { return true } // connect() is about to move it
            finishDisconnected(errorText: nil)
            return false

        default:
            return true
        }
    }

    private func finishDisconnected(errorText: String?) {
        stopPolling()
        attemptID = nil
        connectCallReturned = false

        if let pending = pendingFailure {
            phase = .failed(pending)
        } else if userRequestedDisconnect {
            phase = .idle
        } else if let errorText {
            phase = .failed(errorText)
        } else if reachedConnected {
            phase = .failed("The server ended the stream.")
        } else {
            phase = .failed("The server closed the connection before the stream started: check that the OpenXR app (Unreal) is running on the PC.")
        }
        pendingFailure = nil
        userRequestedDisconnect = false
    }

    private func setPhase(_ newPhase: Phase) {
        if phase != newPhase { phase = newPhase }
    }

    private func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Keys.servers)
        }
    }

    // MARK: - Private: helpers

    private static func isLive(_ state: SessionState) -> Bool {
        switch state {
        case .initialized, .disconnected:
            return false
        default:
            return true
        }
    }

    private static func message(forThrown error: Error) -> String {
        let detail = error.localizedDescription
        let raw = String(describing: error)
        if raw.contains("failedConnectionAttempt") {
            return "Server not reachable: check the IP, that CloudXR Runtime is running, and the firewall. (\(detail))"
        }
        if raw.contains("invalidServerURL") {
            return "Invalid address. (\(detail))"
        }
        return "Couldn't connect: \(detail)"
    }

    /// First IPv4 address of `host` (DNS or mDNS ".local"), off the main actor.
    private nonisolated static func resolveIPv4(_ host: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>? = nil
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
            defer { freeaddrinfo(first) }

            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                if info.pointee.ai_family == AF_INET, let address = info.pointee.ai_addr {
                    var inAddr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                        if !text.isEmpty { return text }
                    }
                }
                cursor = info.pointee.ai_next
            }
            return nil
        }.value
    }
}
