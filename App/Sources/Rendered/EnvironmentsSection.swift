import SwiftUI

/// v0.10 E3: Home › Rendered › Environments. Room-sized baked packages (`"kind": "environment"`),
/// grouped by `group`, cards in `order`. Combines what is on this Vision Pro with what the PC
/// library offers; download one room or the whole group. Hidden when there are none.
struct EnvironmentsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library

    /// One room: on this Vision Pro, on the PC, or both.
    struct Item: Identifiable {
        let id: String
        let title: String
        let order: Int
        let local: RenderedScene?
        let entry: LibraryEntry?
    }

    struct RoomGroup: Identifiable {
        let name: String
        let items: [Item]
        var id: String { name }
    }

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 18)]

    var body: some View {
        let groups = Self.groups(library: library)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                SectionTitle("Environments", systemImage: "cube.transparent")
                Text("Rooms baked to be seen from where you stand: look around and take a few steps. Switch rooms from the palm menu.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(groups) { group in
                    groupView(group)
                }
            }
        }
    }

    // MARK: - Group

    private func groupView(_ group: RoomGroup) -> some View {
        let missing = group.items.compactMap { item -> LibraryEntry? in
            guard let entry = item.entry, !library.isUpToDate(entry) else { return nil }
            return entry
        }
        let busy = group.items.contains { item in
            guard let entry = item.entry else { return false }
            return library.downloads[entry.id] != nil || library.isQueued(entry.id)
        }
        let onDevice = group.items.filter { $0.local != nil }.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Text("\(onDevice) of \(group.items.count) room\(group.items.count == 1 ? "" : "s") on this Vision Pro")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !missing.isEmpty, library.indexState == .loaded {
                    Button {
                        library.downloadAll(missing)
                    } label: {
                        Label(onDevice == 0 ? "Download all \(missing.count)" : "Download the other \(missing.count)",
                              systemImage: "arrow.down.circle")
                            .primaryActionLabel(expands: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(group.items) { item in
                    card(item)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    // MARK: - Card

    private func card(_ item: Item) -> some View {
        let download = item.entry.flatMap { library.downloads[$0.id] }
        let isQueued = item.entry.map { library.isQueued($0.id) } ?? false
        let needsUpdate = item.local != nil && (item.entry.map { !library.isUpToDate($0) } ?? false)
        let partial = item.entry.flatMap { library.partials[$0.id] } ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            thumbnail(item)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if item.order != Int.max {
                            QVBadge(text: "\(item.order)", color: .black.opacity(0.55))
                        }
                        if needsUpdate {
                            QVBadge(text: "Update", systemImage: "arrow.down.circle.fill", color: .orange)
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if let local = item.local {
                        Menu {
                            Button(role: .destructive) {
                                library.delete(local)
                            } label: {
                                Label("Delete from this Vision Pro", systemImage: "trash")
                            }
                            .disabled(model.currentRenderedScene?.id == local.id)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.semibold))
                                .frame(width: 40, height: 40)
                        }
                        .buttonBorderShape(.circle)
                        .padding(6)
                        .accessibilityLabel("Actions for \(item.title)")
                    }
                }

            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            Text(detail(item))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let download {
                DownloadProgress(download: download)
            }

            actions(item, download: download, isQueued: isQueued, needsUpdate: needsUpdate, partial: partial)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private func actions(_ item: Item, download: RenderedLibrary.Download?, isQueued: Bool,
                         needsUpdate: Bool, partial: Int64) -> some View {
        if download != nil || isQueued, let entry = item.entry {
            HStack(spacing: 10) {
                if download == nil {
                    Label("Waiting…", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(role: .cancel) {
                    library.cancelDownload(entry.id)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .frame(minHeight: 44)
                }
                .disabled(download?.stage == .finishing)
            }
        } else if let local = item.local {
            HStack(spacing: 8) {
                Button {
                    model.requestOpenRendered(local)
                } label: {
                    Label("Open", systemImage: "play.fill")
                        .primaryActionLabel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isTransitioning)
                .accessibilityLabel("Open \(item.title)")

                if needsUpdate, let entry = item.entry {
                    Button {
                        library.download(entry)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 60)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Update \(item.title)")
                }
            }
        } else if let entry = item.entry {
            Button {
                library.download(entry)
            } label: {
                Label(partial > 0 ? "Resume" : "Download", systemImage: "arrow.down.circle")
                    .primaryActionLabel()
            }
            .buttonStyle(.borderedProminent)
            .disabled(library.indexState != .loaded)
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: Item) -> some View {
        if let local = item.local, local.thumbnailURL != nil {
            LocalThumbnail(url: local.thumbnailURL, title: item.title, height: 140)
        } else if let entry = item.entry, let name = entry.thumbnail,
                  let address = library.indexHost,
                  let url = RenderedLibrary.fileURL(address: address, name: name) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    RenderedPlaceholder(title: item.title)
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            LocalThumbnail(url: nil, title: item.title, height: 140)
        }
    }

    private func detail(_ item: Item) -> String {
        let bytes = item.local?.sizeBytes ?? item.entry?.sizeBytes ?? 0
        var parts = [RenderedFiles.byteText(bytes)]
        if item.local != nil {
            parts.append("On this Vision Pro")
        } else if item.entry != nil {
            parts.append("On your PC")
        }
        if (item.local?.isHD ?? false) || (item.entry?.isHD ?? false) {
            parts.append("HD")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Grouping

    @MainActor
    static func groups(library: RenderedLibrary) -> [RoomGroup] {
        var byGroup: [String: [Item]] = [:]
        var usedLocal = Set<String>()

        for entry in library.entries {
            guard let sidecar = library.remoteSidecars[entry.id], sidecar.isEnvironment else { continue }
            let local = library.localScene(for: entry)
            if let local { usedLocal.insert(local.id) }
            let title = sidecar.trimmedTitle ?? entry.title
            byGroup[sidecar.groupName, default: []].append(
                Item(id: "pc:" + entry.id, title: title, order: sidecar.order ?? Int.max, local: local, entry: entry))
        }
        for scene in library.scenes {
            guard let info = scene.environment, !usedLocal.contains(scene.id) else { continue }
            byGroup[info.group, default: []].append(
                Item(id: "local:" + scene.id, title: scene.title, order: info.order, local: scene, entry: nil))
        }

        return byGroup
            .map { name, items in
                RoomGroup(name: name, items: items.sorted { a, b in
                    a.order != b.order ? a.order < b.order : a.title.localizedStandardCompare(b.title) == .orderedAscending
                })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
