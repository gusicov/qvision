import SwiftUI

/// Home › Quantities (v0.11): quantity packages "On this Vision Pro" and "On my PC" (the
/// QVision Library), with Download / Open / Update / Delete as in Rendered. The tab connects to
/// the PC by itself (same address as Rendered) and keeps trying quietly while visible.
struct QuantitiesHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(QuantityLibrary.self) private var library
    @Environment(RenderedLibrary.self) private var rendered
    @Environment(ServerSessionController.self) private var server

    @State private var addressText = ""
    @State private var deleteTarget: LocalQuantityPackage?
    @State private var isConfirmingDelete = false
    @FocusState private var addressFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 20)]

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
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            deleteTarget.map { "Delete “\($0.name)”?" } ?? "Delete project?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { package in
            Button("Delete", role: .destructive) {
                library.delete(package)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { package in
            Text("Frees \(RenderedFiles.byteText(package.sizeBytes)) on this Vision Pro. You can download it again from your PC.")
        }
        .alert("Quantities", isPresented: errorBinding) {
            Button("OK", role: .cancel) { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "")
        }
        .task {
            library.refresh()
            if addressText.isEmpty { addressText = effectiveAddress }
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
            BrandHeader()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Breadcrumb(components: ["Home", "Quantities"])
                    Spacer(minLength: 8)
                    connectionPill
                }
                Text("Bills of quantities on the model. Pick an article to see its exact quantity and the elements it counts, hatched, with the rest of the building dimmed. Tap an element to see its articles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

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

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("On this Vision Pro", systemImage: "visionpro") {
                if !library.packages.isEmpty {
                    Text("\(library.packages.count == 1 ? "1 project" : "\(library.packages.count) projects") · \(RenderedFiles.byteText(library.totalBytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if library.packages.isEmpty {
                EmptyStateCard(
                    systemImage: "ruler",
                    title: "No quantity projects yet",
                    message: "Download one from your PC below. The QVision Library on the PC serves the folders in assets › Quantities."
                )
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(library.packages) { package in
                        localCard(package)
                    }
                }
            }
        }
    }

    private func localCard(_ package: LocalQuantityPackage) -> some View {
        let entry = library.entry(for: package)
        let needsUpdate = entry.map { !library.isUpToDate($0) } ?? false
        let download = library.downloads[package.packageId]
        let isOpen = model.currentQuantities?.packageId == package.packageId

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                QuantityTile(title: package.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text("\(RenderedFiles.byteText(package.sizeBytes)) · \(RenderedHomeView.dateFormatter.string(from: package.addedAt))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if isOpen {
                            QVBadge(text: "Open", systemImage: "eye", color: .green)
                        }
                        if needsUpdate {
                            QVBadge(text: "Update", systemImage: "arrow.down.circle.fill", color: .orange)
                        }
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Button(role: .destructive) {
                        deleteTarget = package
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(isOpen || download != nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonBorderShape(.circle)
                .accessibilityLabel("Actions for \(package.name)")
            }

            if let download {
                DownloadProgress(download: download)
            }

            HStack(spacing: 10) {
                Button {
                    model.requestOpenQuantities(package)
                } label: {
                    Label(isOpen ? "Show" : "Open", systemImage: "play.fill")
                        .primaryActionLabel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isTransitioning || download != nil)
                .accessibilityLabel("Open \(package.name)")

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
                    .disabled(isOpen)
                    .accessibilityLabel("Update \(package.name) from your PC")
                }
            }
            if isOpen, needsUpdate {
                Text("Exit the open project to update it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    // MARK: - On my PC

    private var pcSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("On my PC", systemImage: "desktopcomputer") {
                if library.indexState == .loading {
                    ProgressView()
                }
            }
            switch library.indexState {
            case .loaded:
                if library.libraryTooOld {
                    EmptyStateCard(
                        systemImage: "arrow.triangle.2.circlepath",
                        title: "Update the QVision Library on your PC",
                        message: "The library running on the PC doesn't serve quantity packages yet. Restart “QVision Library (PC)” after updating QVision's tools."
                    )
                } else if library.entries.isEmpty {
                    EmptyStateCard(
                        systemImage: "folder",
                        title: "No quantity packages on your PC",
                        message: "Put a package folder (with its manifest.json) in assets › Quantities on the PC."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(library.entries) { entry in
                            remoteRow(entry)
                        }
                    }
                }
            case .failed(let message):
                EmptyStateCard(systemImage: "wifi.exclamationmark", title: "Can't reach your PC", message: message)
            case .loading, .idle:
                EmptyStateCard(systemImage: "antenna.radiowaves.left.and.right", title: "Looking for your PC…",
                               message: "QVision connects by itself to the QVision Library on your PC.")
            }
            addressCard
        }
    }

    private func remoteRow(_ entry: QuantityIndexEntry) -> some View {
        let download = library.downloads[entry.packageId]
        let local = library.local(for: entry)
        let partial = library.partials[entry.packageId] ?? 0
        let isOpen = model.currentQuantities?.packageId == entry.packageId

        return HStack(spacing: 16) {
            QuantityTile(title: entry.name)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(RenderedFiles.byteText(entry.sizeBytes)) · \(entry.files.count) files")
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
                    library.cancelDownload(entry.packageId)
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
                        model.requestOpenQuantities(local)
                    } label: {
                        Label(isOpen ? "Show" : "Open", systemImage: "play.fill")
                            .primaryActionLabel(expands: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTransitioning)
                }
            } else {
                Button {
                    library.download(entry)
                } label: {
                    Label(partial > 0 ? "Resume" : (local == nil ? "Download" : "Update"), systemImage: "arrow.down.circle")
                        .primaryActionLabel(expands: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(local == nil ? nil : Color.orange)
                .disabled(isOpen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous))
    }

    /// The PC address (shared with Rendered); always editable.
    private var addressCard: some View {
        HStack(spacing: 12) {
            Text("PC address")
                .font(.headline)
            TextField("192.168.0.87", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($addressFocused)
                .onSubmit { applyAddress() }
                .frame(maxWidth: 260)
            Button("Connect") {
                addressFocused = false
                applyAddress()
            }
            .buttonStyle(.bordered)
            .disabled(RenderedLibrary.parseAddress(addressText) == nil)
            Spacer(minLength: 0)
        }
        .qvCard(padding: 16)
    }

    private func applyAddress() {
        guard let parsed = RenderedLibrary.parseAddress(addressText) else { return }
        let normalized = parsed.port == RenderedLibrary.port ? parsed.host : "\(parsed.host):\(parsed.port)"
        addressText = normalized
        rendered.hostOverride = (normalized == savedServer?.host) ? "" : normalized
        library.fetchIndex(address: normalized)
    }

    private var savedServer: StreamServer? {
        server.servers.first { $0.name.lowercased().contains("my pc") } ?? server.servers.first
    }

    private var effectiveAddress: String {
        if let host = rendered.indexHost { return host }
        if !rendered.hostOverride.isEmpty { return rendered.hostOverride }
        return savedServer?.host ?? ""
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.lastError = nil } }
        )
    }
}

/// Square tile for a quantity project (initials on the brand gradient).
private struct QuantityTile: View {
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Brand.gradient)
            VStack(spacing: 2) {
                Image(systemName: "ruler")
                    .font(.system(size: 22, weight: .semibold))
                Text(ProjectMonogram.initials(of: title))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }
}
