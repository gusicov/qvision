// This software contains source code provided by NVIDIA Corporation.
// The connect → open-space sequence mirrors NVIDIA's CloudXR generic viewer sample (MIT):
// github.com/NVIDIA/cloudxr-apple-generic-viewer (WindowStateManager, LaunchView).

import SwiftUI

/// The "Server" tab of the main window: saved servers, stream settings, connection status.
///
/// Also owns opening / dismissing the stream ImmersiveSpace. Order (as in the sample): connect
/// first, then open the space once the session is up (`connect()` returned, or `.connected`);
/// dismiss it as soon as the stream ends. If the space can't be opened, the stream is stopped
/// and the reason shown.
struct ServerHomeView: View {
    @Environment(ServerSessionController.self) private var server
    /// v0.8: a project stage or a rendered scene is closed before a stream opens (one space at a time).
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var editorTarget: ServerEditorTarget?
    @State private var deleteTarget: StreamServer?
    @State private var isConfirmingDelete = false
    @State private var isShowingHowTo = false

    /// Serializes open / dismiss calls (a phase change during an open re-runs the sync).
    @State private var isSyncingSpace = false
    @State private var needsSpaceResync = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 30)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ContinueCard()
                    statusArea
                    serversSection
                    settingsSection
                    howToSection
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editorTarget) { target in
            ServerEditorSheet(existing: target.existing) { name, host in
                if var server = target.existing {
                    server.name = name
                    server.host = host
                    self.server.updateServer(server)
                } else {
                    self.server.addServer(name: name, host: host)
                }
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("Delete", role: .destructive) {
                server.deleteServer(target.id)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { target in
            if target.id == server.activeServerID, server.wantsStreamSpace {
                Text("This also ends the current stream.")
            } else {
                Text("The server is removed from this list. The PC itself isn't affected.")
            }
        }
        .onChange(of: server.wantsStreamSpace, initial: true) { _, _ in
            Task { await syncStreamSpace() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            BrandHeader {
                Button {
                    editorTarget = ServerEditorTarget(existing: nil)
                } label: {
                    Label("Add server", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Breadcrumb(components: ["Home", "Server"])
                    Spacer(minLength: 8)
                    phasePill
                }
                Text("Stream Unreal Engine from your PC or the office server with NVIDIA CloudXR.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Connection state at a glance, next to the breadcrumb.
    @ViewBuilder
    private var phasePill: some View {
        switch server.phase {
        case .idle:
            InfoPill(text: "Not connected", systemImage: "circle")
        case .connecting:
            InfoPill(text: "Connecting", systemImage: "antenna.radiowaves.left.and.right")
        case .connected:
            InfoPill(text: "Streaming", systemImage: "dot.radiowaves.left.and.right", tint: .green)
        case .disconnecting:
            InfoPill(text: "Disconnecting", systemImage: "antenna.radiowaves.left.and.right")
        case .failed:
            InfoPill(text: "Failed", systemImage: "exclamationmark.triangle.fill", tint: .red)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusArea: some View {
        switch server.phase {
        case .idle:
            EmptyView()

        case .connecting:
            statusCard {
                HStack(spacing: 16) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connecting to \(activeServerName)…")
                            .font(.headline)
                        Text("The stream opens as soon as the server answers.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Cancel") {
                        server.disconnect()
                    }
                }
            }

        case .connected:
            statusCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Streaming")
                                .font(.title2.weight(.semibold))
                            Text(activeServerName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        server.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle.fill")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.extraLarge)
                    Text("Lost this window while streaming? Triple-tap anywhere in the stream to bring it back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

        case .disconnecting:
            statusCard {
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Disconnecting…")
                        .font(.headline)
                }
            }

        case .failed(let message):
            statusCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Couldn't stream from \(activeServerName)")
                                .font(.headline)
                            Text(message)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)

                    HStack(spacing: 12) {
                        if server.activeServer != nil {
                            Button {
                                Task {
                                    await model.releaseImmersiveSpacesForStream()
                                    await server.retry()
                                }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Dismiss") {
                            server.clearFailure()
                        }
                    }
                }
            }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .qvCard()
    }

    // MARK: - Saved servers

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Servers", systemImage: "desktopcomputer")

            if server.servers.isEmpty {
                EmptyStateCard(
                    systemImage: "desktopcomputer",
                    title: "No servers yet",
                    message: "Tap Add server (top right) and type your PC's IP address. The same address is used by the Rendered tab to find the QVision Library."
                )
            } else {
                ForEach(server.servers) { item in
                    serverRow(item)
                }
            }
        }
    }

    private func serverRow(_ item: StreamServer) -> some View {
        let isActive = item.id == server.activeServerID
        let isLive = isActive && (server.phase == .connected || server.phase == .connecting)

        return HStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.host)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isActive && server.phase == .connected {
                Label("Streaming", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else if isActive && server.phase == .connecting {
                ProgressView()
            } else {
                Button("Connect") {
                    model.noteOpened(.server, id: item.id.uuidString, title: item.name)
                    Task {
                        await model.releaseImmersiveSpacesForStream()
                        await server.connect(to: item.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: isLive ? 3 : 2)
        }
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
        .hoverEffect()
        .contextMenu {
            Button {
                editorTarget = ServerEditorTarget(existing: item)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = item
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Stream settings", systemImage: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Quality", selection: qualityBinding) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(server.quality.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .disabled(isSessionActive)

                Toggle("Hand tracking", isOn: handTrackingBinding)
                    .disabled(isSessionActive)

                Toggle("Show my room (mixed)", isOn: showRoomBinding)

                if isSessionActive {
                    Text("Quality and hand tracking apply to the next connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .qvCard()
        }
    }

    // MARK: - How to test

    private var howToSection: some View {
        DisclosureGroup(isExpanded: $isShowingHowTo) {
            VStack(alignment: .leading, spacing: 10) {
                howToStep(1, "Run CloudXR Runtime and an OpenXR app on the PC (for example NVIDIA's LÖVR sample, or Unreal Engine).")
                howToStep(2, "Allow CloudXR Runtime through the PC's firewall.")
                howToStep(3, "Add the PC's IP address here (on Windows: ipconfig, IPv4 Address).")
                howToStep(4, "The headset and the PC must be on the same network.")
                Text("The first time, visionOS asks to allow QVision on the local network: allow it, then tap Retry if the first attempt failed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.top, 10)
        } label: {
            Label("How to test", systemImage: "questionmark.circle")
                .font(.headline)
        }
        .qvCard()
    }

    private func howToStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.body.monospacedDigit().weight(.semibold))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Immersive space

    /// Opens the stream space when the session is up, dismisses it when the stream ends.
    @MainActor
    private func syncStreamSpace() async {
        if isSyncingSpace {
            needsSpaceResync = true
            return
        }
        isSyncingSpace = true
        defer { isSyncingSpace = false }

        repeat {
            needsSpaceResync = false

            if server.wantsStreamSpace && !server.isStreamSpaceOpen {
                let result = await openImmersiveSpace(id: ServerSessionController.streamSpaceID)
                switch result {
                case .opened:
                    server.isStreamSpaceOpen = true
                    if !server.wantsStreamSpace {
                        needsSpaceResync = true // the stream ended while the space was opening
                    }
                case .userCancelled:
                    server.disconnect(withError: "The stream view was cancelled, so the stream was stopped.")
                case .error:
                    server.disconnect(withError: "Couldn't open the stream view. Close any other immersive scene (an open project or a rendered scene) and try again.")
                @unknown default:
                    server.disconnect(withError: "Couldn't open the stream view.")
                }
            } else if !server.wantsStreamSpace && server.isStreamSpaceOpen {
                await dismissImmersiveSpace()
                server.isStreamSpaceOpen = false
            }
        } while needsSpaceResync
    }

    // MARK: - Helpers

    private var activeServerName: String {
        server.activeServer?.name ?? "the server"
    }

    /// A connect / disconnect is in flight: other Connect buttons wait.
    private var isBusy: Bool {
        server.phase == .connecting || server.phase == .disconnecting
    }

    private var isSessionActive: Bool {
        switch server.phase {
        case .connecting, .connected, .disconnecting:
            return true
        default:
            return false
        }
    }

    private var deleteDialogTitle: String {
        if let deleteTarget {
            return "Delete “\(deleteTarget.name)”?"
        }
        return "Delete server?"
    }

    private var qualityBinding: Binding<StreamQuality> {
        Binding(get: { server.quality }, set: { server.quality = $0 })
    }

    private var handTrackingBinding: Binding<Bool> {
        Binding(get: { server.handTrackingEnabled }, set: { server.handTrackingEnabled = $0 })
    }

    private var showRoomBinding: Binding<Bool> {
        Binding(get: { server.showRoom }, set: { server.showRoom = $0 })
    }
}

// MARK: - Add / edit sheet

private struct ServerEditorTarget: Identifiable {
    let id = UUID()
    /// nil = add a new server.
    let existing: StreamServer?
}

private struct ServerEditorSheet: View {
    let existing: StreamServer?
    let onSave: (_ name: String, _ host: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String

    init(existing: StreamServer?, onSave: @escaping (_ name: String, _ host: String) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: existing?.host ?? "")
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isHostValid: Bool {
        StreamHostValidator.isValid(trimmedHost)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. My PC)", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("IP address or hostname", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onSubmit { save() }
                } footer: {
                    if !trimmedHost.isEmpty && !isHostValid {
                        Text("Enter an IPv4 address (e.g. 192.168.0.87) or a hostname (e.g. my-pc.local).")
                            .foregroundStyle(.red)
                    } else {
                        Text("The port is set by CloudXR, so only the address is needed.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isHostValid)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func save() {
        guard isHostValid else { return }
        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), StreamHostValidator.normalized(trimmedHost))
        dismiss()
    }
}
