import SwiftUI
import RealityKit
import simd

/// Content of `ImmersiveSpace(id: AppModel.renderedSpaceID)`: the baked scene, the fly indicator,
/// the comfort vignette and the shared palm menu (left palm toward your face:
/// Exit · Viewpoints · Speed, or Exit · Rooms for an Environment).
struct RenderedImmersiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library
    @Environment(\.openWindow) private var openWindow

    @State private var updateSubscription: EventSubscription?
    @State private var palmState = PalmMenuState()
    @State private var vignette = ComfortVignette()
    @State private var hintState = AreaHintState()

    private static let areaHintID = "qvAreaHint"

    var body: some View {
        RealityView { content, attachments in
            content.add(model.rendered.root)
            content.add(model.rendered.fly.indicator)
            content.add(vignette.anchor)

            if let menu = attachments.entity(for: PalmMenuPlacement.attachmentID) {
                PalmMenuPlacement.install(menu, in: palmState)
                content.add(menu)
            }
            if let hint = attachments.entity(for: Self.areaHintID) {
                hint.components.set(BillboardComponent())
                hint.isEnabled = false
                content.add(hint)
                hintState.hint = hint
            }

            let frameModel = model
            let frameState = palmState
            let frameVignette = vignette
            let frameHint = hintState
            updateSubscription?.cancel()
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated {
                    RenderedImmersiveView.updateFrame(model: frameModel, state: frameState, vignette: frameVignette,
                                                      hint: frameHint, deltaTime: Float(event.deltaTime))
                }
            }
        } update: { _, _ in
            // Driven per frame by the SceneEvents.Update subscription.
        } attachments: {
            Attachment(id: PalmMenuPlacement.attachmentID) {
                RenderedPalmMenu()
                    .environment(model)
                    .environment(library)
            }
            Attachment(id: Self.areaHintID) {
                Label("Step back to the centre", systemImage: "figure.walk.arrival")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .glassBackgroundEffect(in: Capsule())
            }
        }
        .installsSceneActions()
        .onAppear {
            model.renderedDidAppear()
        }
        .task {
            await model.hands.start(owner: "rendered")
        }
        .task {
            await vignette.prepare()
        }
        .task {
            // Hand tracking is shared with the stage space; if the previous space's onDisappear
            // stopped it after this space started it, start it again.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if model.hands.status == .idle {
                    await model.hands.start(owner: "rendered")
                }
            }
        }
        .onChange(of: model.rendered.phase) { _, phase in
            // A failed load must never leave the user in an empty space without a window.
            if case .failed = phase, !model.isMainWindowOpen {
                openWindow(id: AppModel.mainWindowID)
            }
        }
        .onDisappear {
            updateSubscription?.cancel()
            updateSubscription = nil
            vignette.hide()
            model.hands.stop(owner: "rendered")
            model.renderedDidDisappear()
        }
    }

    // MARK: - Per frame

    @MainActor
    private static func updateFrame(model: AppModel, state: PalmMenuState, vignette: ComfortVignette,
                                    hint: AreaHintState, deltaTime: Float) {
        let dt = Swift.min(Swift.max(deltaTime, 0), 0.1)
        let pose = model.hands.devicePose()
        let viewer = model.rendered
        viewer.updateFrame(deltaTime: dt, devicePose: pose)

        // E3: "Step back to the centre", 1.2 m in front of the eyes, slightly low.
        if let entity = hint.hint {
            let show = viewer.isEnvironment && viewer.isOutsideViewingArea && viewer.isReady
            if show, let pose {
                let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
                var forward = -SIMD3<Float>(pose.columns.2.x, 0, pose.columns.2.z)
                let length = simd_length(forward)
                forward = length > 0.01 ? forward / length : SIMD3<Float>(0, 0, -1)
                entity.setPosition(head + forward * 1.2 - SIMD3<Float>(0, 0.15, 0), relativeTo: nil)
                if !entity.isEnabled { entity.isEnabled = true }
            } else if entity.isEnabled {
                entity.isEnabled = false
            }
        }

        vignette.update(speed: viewer.fly.currentSpeed, yawRate: viewer.fly.currentYawRate,
                        enabled: model.comfortVignette, deltaTime: dt)
        // No palm menu while flying (both fists clenched).
        PalmMenuPlacement.update(state: state, hands: model.hands, pose: pose, deltaTime: dt,
                                 suppressed: viewer.fly.isFlying)
    }
}

/// The "Step back to the centre" attachment (read by the per-frame update).
final class AreaHintState {
    var hint: Entity?
}

/// Exit · Viewpoints · Speed on the left palm (the shared palm menu, v0.9 D1). For an
/// Environment: Exit · Rooms (the other rooms of its group), no Speed (no fist-fly).
private struct RenderedPalmMenu: View {
    private enum Section {
        case viewpoints, speed, rooms
    }

    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library
    @State private var section: Section?

    var body: some View {
        let viewer = model.rendered
        PalmMenuChrome {
            PalmMenuButton(title: "Exit", systemImage: "house", isDestructive: true) {
                model.requestLeaveRendered()
            }
            if viewer.isEnvironment {
                PalmMenuButton(title: "Rooms", systemImage: "door.left.hand.open", isOn: section == .rooms) {
                    section = (section == .rooms) ? nil : .rooms
                }
                .disabled(viewer.isSwitchingRoom)
            } else {
                PalmMenuButton(title: "Viewpoints", systemImage: "mappin.and.ellipse", isOn: section == .viewpoints) {
                    section = (section == .viewpoints) ? nil : .viewpoints
                }
                .disabled(!viewer.isReady)
                PalmMenuButton(title: "Speed \(DisplayFormat.multiplier(viewer.speed))", systemImage: "hare", isOn: section == .speed) {
                    section = (section == .speed) ? nil : .speed
                }
            }
        } expanded: {
            switch section {
            case .rooms:
                RoomList(maxHeight: 300) {
                    section = nil
                }
                .frame(width: 400)
            case .viewpoints:
                ViewpointList(viewer: viewer, maxHeight: 280) {
                    section = nil
                }
                .frame(width: 380)
            case .speed:
                SpeedPresetRow(speed: viewer.speed) { viewer.speed = $0 }
                    .frame(width: 380)
            case nil:
                EmptyView()
            }
        }
    }
}

/// E3: the rooms of the open Environment's group that are on this Vision Pro, in `order`.
/// Tapping another one switches to it (fade out, unload, load, fade in).
struct RoomList: View {
    var maxHeight: CGFloat? = nil
    var onChosen: (() -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(RenderedLibrary.self) private var library

    var body: some View {
        let viewer = model.rendered
        let rooms = library.rooms(inGroup: viewer.environmentGroup)
        let currentID = model.currentRenderedScene?.id
        let list = VStack(spacing: 8) {
            ForEach(rooms) { room in
                let isCurrent = room.id == currentID
                Button {
                    model.requestSwitchRoom(to: room)
                    onChosen?()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isCurrent ? "checkmark.circle.fill" : "door.left.hand.open")
                            .foregroundStyle(isCurrent ? Color.green : Color.secondary)
                        Text(room.title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if isCurrent {
                            Text("You are here")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(isCurrent || viewer.isSwitchingRoom || model.isTransitioning)
                .accessibilityLabel(isCurrent ? "\(room.title), current room" : "Go to \(room.title)")
            }
            if rooms.count <= 1 {
                Text("Download the other rooms of \(viewer.environmentGroup ?? "this group") in Home › Rendered to walk between them here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let maxHeight, rooms.count > 5 {
            ScrollView { list }
                .frame(maxHeight: maxHeight)
        } else {
            list
        }
    }
}

/// The viewpoints of the open scene ("Start" first); tapping one moves the user there with a
/// short fade. Used by the palm menu and the session window (D2).
struct ViewpointList: View {
    let viewer: RenderedViewer
    var maxHeight: CGFloat? = nil
    var onChosen: (() -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        let grid = LazyVGrid(columns: columns, spacing: 8) {
            ForEach(viewer.viewpoints) { viewpoint in
                Button {
                    viewer.go(to: viewpoint)
                    onChosen?()
                } label: {
                    Label(viewpoint.name, systemImage: viewpoint.id == 0 ? "figure.stand" : "mappin")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .accessibilityLabel("Go to \(viewpoint.name)")
            }
        }
        if let maxHeight, viewer.viewpoints.count > 8 {
            ScrollView {
                grid
            }
            .frame(maxHeight: maxHeight)
        } else {
            grid
        }
    }
}
