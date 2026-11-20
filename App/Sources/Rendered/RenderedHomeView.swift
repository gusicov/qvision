import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Home › Rendered: photoreal baked scenes. "On this Vision Pro" (downloaded, offline) and
/// "On my PC" (the QVision Library), plus Import from Files.
///
/// v0.9 C: the tab connects to the PC by itself and keeps trying quietly while it is visible;
/// when the PC doesn't answer it says exactly what to do; downloaded scenes show an Update
/// badge when the PC copy changed; downloads resume.
struct RenderedHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library
    @Environment(ServerSessionController.self) private var server

    @State private var addressText = ""
    @State private var isImporting = false
    @State private var deleteTarget: RenderedScene?
    @State private var isConfirmingDelete = false
    @State private var isShowingHowTo = false
    @FocusState private var addressFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 20)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 30)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ContinueCard()
                    EnvironmentsSection()
                    if !(classicScenes.isEmpty && hasEnvironments) {
                        localSection
                    }
                    pcSection
                    howToSection
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: Self.importTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await library.importFiles(urls) }
            case .failure(let error):
                library.lastError = "Couldn't open the file picker: \(error.localizedDescription)"
            }
        }
        .confirmationDialog(
            deleteTarget.map { "Delete “\($0.title)”?" } ?? "Delete scene?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { scene in
            Button("Delete", role: .destructive) {
                library.delete(scene)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: { scene in
            Text("Frees \(RenderedFiles.byteText(scene.sizeBytes)) on this Vision Pro. You can download it again from your PC.")
        }
        .alert("Rendered", isPresented: errorBinding) {
            Button("OK", role: .cancel) { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "")
        }
        .task {
            // C1: connect by itself, and keep trying quietly while this tab is visible.
            library.refresh()
            if addressText.isEmpty {
                addressText = effectiveAddress
            }
            while !Task.isCancelled {
                if !addressFocused, RenderedLibrary.parseAddress(addressText) != nil {
                    library.poll(address: addressText)
                }
                let seconds: UInt64 = (library.indexState == .loaded) ? 15 : 4
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            BrandHeader {
                Button {
                    isImporting = true
                } label: {
                    Label("Import from Files", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(library.importStatus != nil || model.isTransitioning)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Breadcrumb(components: ["Home", "Rendered"])
                    Spacer(minLength: 8)
                    connectionPill
                }
                Text("Photoreal scenes baked on your PC, shown exactly as rendered. Walk through them at real size; once downloaded they work offline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// PC connection at a glance, next to the breadcrumb (like the Server tab's pill).
    @ViewBuilder
    private var connectionPill: some View {
        switch library.indexState {
        case .loaded:
            InfoPill(text: "PC connected", systemImage: "checkmark.circle.fill", tint: .green)
        case .loading, .idle:
            InfoPill(text: "Looking for your PC", systemImage: "antenna.radiowaves.left.and.right")
        case .failed:
            InfoPill(text: "PC not found", systemImage: "wifi.exclamationmark", tint: .orange)
        }
    }

    // MARK: - On this Vision Pro

    /// v0.10: classic Rendered scenes (Environments have their own section above).
    private var classicScenes: [RenderedScene] {
        library.scenes.filter { $0.environment == nil }
    }

    private var classicEntries: [LibraryEntry] {
        library.entries.filter { !library.isEnvironment($0) }
    }

    private var hasEnvironments: Bool {
        library.scenes.contains { $0.environment != nil } || library.entries.contains { library.isEnvironment($0) }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("On this Vision Pro", systemImage: "visionpro") {
                if !library.scenes.isEmpty {
                    Text(sceneCountText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let status = library.importStatus {
                HStack(spacing: 14) {
                    ProgressView()
                    Text(status)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                .qvCard(padding: 16)
            }

            if classicScenes.isEmpty {
                EmptyStateCard(
                    systemImage: "sparkles",
                    title: "No rendered scenes yet",
                    message: "Download one from your PC below (tap Download), or use Import from Files for a .usdz with its .json sidecar."
                )
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(classicScenes) { scene in
                        localCard(scene)
                    }
                }
            }
        }
    }

    private var sceneCountText: String {
        let count = library.scenes.count
        let scenes = count == 1 ? "1 scene" : "\(count) scenes"
        return "\(scenes) · \(RenderedFiles.byteText(library.totalBytes))"
    }

    private func localCard(_ scene: RenderedScene) -> some View {
        let entry = library.entry(for: scene)
        let needsUpdate = entry.map { !library.isUpToDate($0) } ?? false
        let download = entry.flatMap { library.downloads[$0.id] }

        return VStack(alignment: .leading, spacing: 12) {
            LocalThumbnail(url: scene.thumbnailURL, title: scene.title, height: 170)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if scene.isHD {
                            QVBadge(text: "HD", systemImage: "sparkles", color: .purple)
                        }
                        if needsUpdate {
                            QVBadge(text: "Update", systemImage: "arrow.down.circle.fill", color: .orange)
                        }
                    }
                    .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            deleteTarget = scene
                            isConfirmingDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonBorderShape(.circle)
                    .padding(8)
                    .accessibilityLabel("Actions for \(scene.title)")
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(scene.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(detailText(scene))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let download {
                DownloadProgress(download: download)
            }

            HStack(spacing: 10) {
                Button {
                    model.requestOpenRendered(scene)
                } label: {
                    Label("Open", systemImage: "play.fill")
                        .primaryActionLabel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isTransitioning || download != nil)
                .accessibilityLabel("Open \(scene.title)")

                if let entry, needsUpdate, download == nil {
                    Button {
                        library.download(entry)
                    } label: {
                        Label("Update", systemImage: "arrow.down.circle")
                            .font(.headline)
                            .frame(minHeight: 60)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Update \(scene.title) from your PC")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func detailText(_ scene: RenderedScene) -> String {
        var parts = [RenderedFiles.byteText(scene.sizeBytes)]
        parts.append(Self.dateFormatter.string(from: scene.addedAt))
        if scene.viewpointCount > 0 {
            parts.append(scene.viewpointCount == 1 ? "1 viewpoint" : "\(scene.viewpointCount) viewpoints")
        }
        return parts.joined(separator: " · ")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - On my PC

    private var pcSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("On my PC", systemImage: "desktopcomputer") {
                if library.indexState == .loading {
                    ProgressView()
                }
            }

            remoteContent
            addressCard
        }
    }

    @ViewBuilder
    private var remoteContent: some View {
        switch library.indexState {
        case .idle, .loading:
            HStack(spacing: 14) {
                ProgressView()
                Text("Looking for the QVision Library at \(displayAddress)…")
                    .font(.subheadline)
            }
            .qvCard(padding: 16)

        case .failed(let message):
            // C2: say exactly what to do.
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Your PC isn't answering")
                        .font(.headline)
                } icon: {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
                Text(message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Trying \(displayAddress) again every few seconds…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !library.scenes.isEmpty {
                    Text("The scenes already on this Vision Pro work without the PC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .qvCard()

        case .loaded:
            if library.entries.isEmpty {
                EmptyStateCard(
                    systemImage: "tray",
                    title: "The library is empty",
                    message: "Bake a scene on the PC (Bake-Rendered.cmd) or put <Name>.usdz with its .json and .jpg into the Rendered folder. It appears here by itself."
                )
            } else if classicEntries.isEmpty {
                Text("Everything on your PC is an Environment: see Environments above.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .qvCard(padding: 16)
            } else {
                VStack(spacing: 12) {
                    ForEach(classicEntries) { entry in
                        RemoteEntryRow(entry: entry, address: library.indexHost ?? addressText)
                    }
                }
            }
        }
    }

    private var displayAddress: String {
        let address = library.triedAddress ?? addressText
        if let parsed = RenderedLibrary.parseAddress(address) {
            return "\(parsed.host):\(parsed.port)"
        }
        return address.isEmpty ? "your PC" : address
    }

    /// The address being used; always editable (C2).
    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("PC address")
                    .font(.subheadline.weight(.semibold))
                TextField("192.168.0.87", text: $addressText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.body.monospaced())
                    .focused($addressFocused)
                    .onSubmit { applyAddress() }
                Text(":\(RenderedLibrary.port)")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    addressFocused = false
                    applyAddress()
                } label: {
                    Label("Connect", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(RenderedLibrary.parseAddress(addressText) == nil)
            }
            Text(addressFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .qvCard()
    }

    private var addressFootnote: String {
        if RenderedLibrary.parseAddress(addressText) == nil {
            return "Type your PC's address: it is shown in the “QVision Library (PC)” window on the PC."
        }
        if let saved = savedServer, saved.host == addressText {
            return "Taken from your saved server “\(saved.name)”. QVision connects by itself; change the address only if the library runs on another PC."
        }
        return "QVision connects by itself. The address is shown in the “QVision Library (PC)” window on the PC."
    }

    private func applyAddress() {
        guard let parsed = RenderedLibrary.parseAddress(addressText) else { return }
        let normalized = parsed.port == RenderedLibrary.port ? parsed.host : "\(parsed.host):\(parsed.port)"
        addressText = normalized
        library.hostOverride = (normalized == savedServer?.host) ? "" : normalized
        library.fetchIndex(address: normalized)
    }

    /// The saved Server entry for "My PC" (or the first saved server).
    private var savedServer: StreamServer? {
        server.servers.first { $0.name.lowercased().contains("my pc") } ?? server.servers.first
    }

    private var effectiveAddress: String {
        if !library.hostOverride.isEmpty { return library.hostOverride }
        return savedServer?.host ?? ""
    }

    // MARK: - How it works

    private var howToSection: some View {
        DisclosureGroup(isExpanded: $isShowingHowTo) {
            VStack(alignment: .leading, spacing: 10) {
                step(1, "The PC runs “QVision Library (PC)” (it starts with Windows; the shortcut is in Desktop › Vision Pro).")
                step(2, "Scenes baked on the PC appear under On my PC. Tap Download; it resumes if interrupted.")
                step(3, "Tap Open. Clench both fists to fly. Turn your left palm toward you for Exit, Viewpoints and Speed.")
                Text("Scenes are baked (path-traced lighting in the textures), so they look the same at any frame rate and need no network once downloaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.top, 10)
        } label: {
            Label("How it works", systemImage: "questionmark.circle")
                .font(.headline)
        }
        .qvCard()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .font(.body.monospacedDigit().weight(.semibold))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.lastError = nil } }
        )
    }

    private static var importTypes: [UTType] {
        var types: [UTType] = [.usdz, .json, .jpeg, .png]
        if let jpg = UTType(filenameExtension: "jpg"), !types.contains(jpg) {
            types.append(jpg)
        }
        return types
    }
}

// MARK: - Pieces

/// Small coloured badge on a thumbnail ("HD", "Update").
struct QVBadge: View {
    let text: String
    var systemImage: String? = nil
    var color: Color = .accentColor

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.footnote.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.9), in: Capsule())
    }
}

/// Progress bar with "312 MB of 480 MB · 65 %".
struct DownloadProgress: View {
    let download: RenderedLibrary.Download

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = download.fraction, download.stage == .downloading {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(text)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var text: String {
        switch download.stage {
        case .preparing:
            return "Starting…"
        case .finishing:
            return "Finishing…"
        case .downloading:
            let received = RenderedFiles.byteText(download.received)
            let total = RenderedFiles.byteText(download.expected)
            if let fraction = download.fraction {
                return "\(received) of \(total) · \(Int((fraction * 100).rounded())) %"
            }
            return received
        }
    }
}

/// Thumbnail from a local file (downsampled off the main thread), or a branded placeholder.
struct LocalThumbnail: View {
    let url: URL?
    let title: String
    var height: CGFloat = 120

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RenderedPlaceholder(title: title)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await Self.load(url)
        }
        .accessibilityHidden(true)
    }

    static func load(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 800,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

struct RenderedPlaceholder: View {
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.gradient)
            VStack(spacing: 6) {
                Image(systemName: "photo.artframe")
                    .font(.system(size: 34, weight: .semibold))
                Text(ProjectMonogram.initials(of: title))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.95))
        }
    }
}

// MARK: - Remote entry row

private struct RemoteEntryRow: View {
    let entry: LibraryEntry
    let address: String

    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        let download = library.downloads[entry.id]
        let local = library.localScene(for: entry)
        let partial = library.partials[entry.id] ?? 0

        HStack(spacing: 16) {
            remoteThumbnail
                .frame(width: 168, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if entry.isHD {
                        QVBadge(text: "HD", systemImage: "sparkles", color: .purple)
                            .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let download {
                    DownloadProgress(download: download)
                } else if partial > 0, local == nil || !library.isUpToDate(entry) {
                    Text("Paused at \(RenderedFiles.byteText(partial)) of \(RenderedFiles.byteText(entry.sizeBytes))")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 12)

            if download != nil {
                Button(role: .cancel) {
                    library.cancelDownload(entry.id)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.headline)
                        .frame(minHeight: 60)
                        .padding(.horizontal, 6)
                }
                .disabled(download?.stage == .finishing)
            } else if let local, library.isUpToDate(entry) {
                VStack(alignment: .trailing, spacing: 6) {
                    Label("On this Vision Pro", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                    Button {
                        model.requestOpenRendered(local)
                    } label: {
                        Label("Open", systemImage: "play.fill")
                            .primaryActionLabel(expands: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTransitioning)
                }
            } else {
                Button {
                    library.download(entry)
                } label: {
                    Label(actionTitle(local: local, partial: partial), systemImage: "arrow.down.circle")
                        .primaryActionLabel(expands: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(local == nil ? nil : Color.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
    }

    private func actionTitle(local: RenderedScene?, partial: Int64) -> String {
        if partial > 0 { return "Resume" }
        return local == nil ? "Download" : "Update"
    }

    @ViewBuilder
    private var remoteThumbnail: some View {
        if let name = entry.thumbnail, let url = RenderedLibrary.fileURL(address: address, name: name) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    RenderedPlaceholder(title: entry.title)
                }
            }
        } else {
            RenderedPlaceholder(title: entry.title)
        }
    }

    private var detailText: String {
        var parts = [RenderedFiles.byteText(entry.sizeBytes)]
        if let date = entry.modifiedDate {
            parts.append(Self.dateFormatter.string(from: date))
        }
        if entry.sidecar == nil {
            parts.append("no start position")
        }
        return parts.joined(separator: " · ")
    }
}
