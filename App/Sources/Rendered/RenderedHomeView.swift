import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Home › Rendered (v0.8 R1/R3): photoreal baked scenes. "On this Vision Pro" (downloaded,
/// offline), "On my PC" (the QVision Library), and Import from Files.
struct RenderedHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library
    @Environment(ServerSessionController.self) private var server

    @State private var addressText = ""
    @State private var isImporting = false
    @State private var deleteTarget: RenderedScene?
    @State private var isConfirmingDelete = false
    @State private var isShowingHowTo = false
    @State private var didAutoFetch = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 20)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 30)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    localSection
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
        .onAppear {
            library.refresh()
            if addressText.isEmpty {
                addressText = effectiveAddress
            }
            if !didAutoFetch, !addressText.isEmpty, library.indexState == .idle {
                didAutoFetch = true
                library.fetchIndex(address: addressText)
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
                    if !library.scenes.isEmpty {
                        InfoPill(text: sceneCountText, systemImage: "visionpro")
                    }
                }
                Text("Photoreal scenes baked on your PC, shown exactly as rendered. Walk through them at real size; once downloaded they work offline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sceneCountText: String {
        let count = library.scenes.count
        let scenes = count == 1 ? "1 scene" : "\(count) scenes"
        return "\(scenes) · \(RenderedFiles.byteText(library.totalBytes))"
    }

    // MARK: - On this Vision Pro

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("On this Vision Pro", systemImage: "visionpro")

            if let status = library.importStatus {
                HStack(spacing: 14) {
                    ProgressView()
                    Text(status)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                .qvCard(padding: 16)
            }

            if library.scenes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("No rendered scenes yet", systemImage: "cube.transparent")
                        .font(.headline)
                    Text("Download one from your PC below, or use Import from Files for a .usdz (with its .json sidecar).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .qvCard()
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(library.scenes) { scene in
                        localCard(scene)
                    }
                }
            }
        }
    }

    private func localCard(_ scene: RenderedScene) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.requestOpenRendered(scene)
            } label: {
                RenderedSceneCard(scene: scene)
            }
            .buttonStyle(.plain)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 28, style: .continuous))
            .hoverEffect()
            .disabled(model.isTransitioning)
            .accessibilityLabel("Open \(scene.title)")
            .contextMenu {
                localActions(scene)
            }

            Menu {
                localActions(scene)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonBorderShape(.circle)
            .padding(20)
            .accessibilityLabel("Actions for \(scene.title)")
        }
    }

    @ViewBuilder
    private func localActions(_ scene: RenderedScene) -> some View {
        Button {
            model.requestOpenRendered(scene)
        } label: {
            Label("Open", systemImage: "play.fill")
        }
        Button(role: .destructive) {
            deleteTarget = scene
            isConfirmingDelete = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - On my PC

    private var pcSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("On my PC", systemImage: "desktopcomputer") {
                if library.indexState == .loading {
                    ProgressView()
                }
            }

            addressCard
            remoteContent
        }
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("PC address (e.g. 192.168.0.87)", text: $addressText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .font(.body.monospaced())
                    .onSubmit { connect() }
                Text(":\(RenderedLibrary.port)")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    connect()
                } label: {
                    Label(library.indexState == .loaded ? "Refresh" : "Connect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(RenderedLibrary.parseAddress(addressText) == nil || library.indexState == .loading)
            }
            Text(addressFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .qvCard()
    }

    private var addressFootnote: String {
        if let saved = savedServer {
            return "Your PC runs “QVision Library (PC)” (Desktop › Vision Pro). Address taken from the saved server “\(saved.name)”; edit it here if the library runs elsewhere."
        }
        return "Your PC runs “QVision Library (PC)” (Desktop › Vision Pro); it shows the address to type here."
    }

    @ViewBuilder
    private var remoteContent: some View {
        switch library.indexState {
        case .idle:
            EmptyView()
        case .loading:
            if library.entries.isEmpty {
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Looking for the QVision Library…")
                        .font(.subheadline)
                }
                .qvCard(padding: 16)
            } else {
                remoteList
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                Button {
                    connect()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
            .qvCard()
        case .loaded:
            if library.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("The library is empty", systemImage: "tray")
                        .font(.headline)
                    Text("Put baked scenes (<Name>.usdz with <Name>.json and <Name>.jpg) into “assets\\Rendered” on the PC, then tap Refresh.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .qvCard()
            } else {
                remoteList
            }
        }
    }

    private var remoteList: some View {
        VStack(spacing: 12) {
            ForEach(library.entries) { entry in
                RemoteEntryRow(entry: entry, address: library.indexHost ?? addressText)
            }
        }
    }

    private func connect() {
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
                step(1, "On the PC, double-click “QVision Library (PC)” in Desktop › Vision Pro. It shows the PC's address.")
                step(2, "First time only: run tools\\library-server\\add-library-firewall.ps1 as administrator.")
                step(3, "Here, type that address under On my PC and tap Connect, then Download.")
                step(4, "Open the scene. Clench both fists to fly; turn your left palm toward you for Exit, Start position and Speed.")
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

// MARK: - Local scene card

private struct RenderedSceneCard: View {
    let scene: RenderedScene

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LocalThumbnail(url: scene.thumbnailURL, title: scene.title, height: 132)
                .overlay(alignment: .bottomLeading) {
                    Label("Rendered", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.3), in: Capsule())
                        .padding(10)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(scene.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("Added \(Self.relativeFormatter.localizedString(for: scene.addedAt, relativeTo: Date()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 14) {
                Label(RenderedFiles.byteText(scene.sizeBytes), systemImage: "internaldrive")
                Label(scene.origin?.source == "files" ? "Files" : "My PC",
                      systemImage: scene.origin?.source == "files" ? "folder" : "desktopcomputer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

private struct RenderedPlaceholder: View {
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

        HStack(spacing: 16) {
            remoteThumbnail
                .frame(width: 112, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let download {
                    VStack(alignment: .leading, spacing: 4) {
                        if let fraction = download.fraction, download.stage == .downloading {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                        Text(progressText(download))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 12)

            if download != nil {
                Button(role: .cancel) {
                    library.cancelDownload(entry.id)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .disabled(download?.stage == .finishing)
            } else if let local, library.isUpToDate(entry) {
                HStack(spacing: 10) {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Button("Open") {
                        model.requestOpenRendered(local)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTransitioning)
                }
            } else {
                Button {
                    library.download(entry)
                } label: {
                    Label(local == nil ? "Download" : "Update", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
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

    private func progressText(_ download: RenderedLibrary.Download) -> String {
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
