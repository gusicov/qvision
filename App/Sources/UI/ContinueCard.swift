import SwiftUI

/// v0.9 B1: "Continue" at the top of every Home tab: the last thing opened (a project, a
/// rendered scene or a server), one tap to get back into it. Hidden when there is nothing to
/// continue or the target no longer exists.
struct ContinueCard: View {
    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library
    @Environment(ServerSessionController.self) private var server

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private struct Target {
        let title: String
        let kindText: String
        let systemImage: String
        let thumbnail: URL?
        let open: () -> Void
    }

    var body: some View {
        if let record = model.lastOpened, let target = resolve(record) {
            Button(action: target.open) {
                HStack(spacing: 16) {
                    Group {
                        if let thumbnail = target.thumbnail {
                            LocalThumbnail(url: thumbnail, title: target.title, height: 72)
                                .frame(width: 116)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Brand.gradient)
                                Image(systemName: target.systemImage)
                                    .font(.title.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 116, height: 72)
                        }
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Continue")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(target.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                        Text("\(target.kindText) · \(Self.relativeFormatter.localizedString(for: record.date, relativeTo: Date()))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Brand.gradient)
                        .accessibilityHidden(true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .buttonStyle(.plain)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 28, style: .continuous))
            .hoverEffect()
            .disabled(model.isTransitioning)
            .accessibilityLabel("Continue \(target.title), \(target.kindText)")
        }
    }

    private func resolve(_ record: AppModel.LastOpened) -> Target? {
        switch record.kind {
        case .project:
            guard let id = UUID(uuidString: record.id),
                  let project = model.projects.first(where: { $0.id == id }) else { return nil }
            return Target(title: project.name, kindText: "Project", systemImage: "square.stack.3d.up", thumbnail: nil) {
                model.requestOpenProject(id)
            }

        case .rendered:
            guard let scene = library.scene(id: record.id) else { return nil }
            return Target(title: scene.title, kindText: scene.isHD ? "Rendered scene · HD" : "Rendered scene",
                          systemImage: "sparkles", thumbnail: scene.thumbnailURL) {
                model.requestOpenRendered(scene)
            }

        case .server:
            guard let id = UUID(uuidString: record.id),
                  let saved = server.servers.first(where: { $0.id == id }) else { return nil }
            // While it is streaming or connecting there is nothing to continue.
            if server.activeServerID == id, server.phase == .connected || server.phase == .connecting {
                return nil
            }
            return Target(title: saved.name, kindText: "Server stream", systemImage: "server.rack", thumbnail: nil) {
                // The Server tab owns the stream space: show it, then connect.
                model.homeTab = .server
                Task { @MainActor in
                    await model.releaseImmersiveSpacesForStream()
                    await server.connect(to: id)
                }
            }
        }
    }
}
