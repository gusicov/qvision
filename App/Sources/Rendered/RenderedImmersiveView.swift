import SwiftUI
import RealityKit
import simd

/// Content of `ImmersiveSpace(id: AppModel.renderedSpaceID)`: the baked scene, the fly indicator,
/// the comfort vignette and the shared palm menu (left palm toward your face:
/// Exit · Viewpoints · Speed).
struct RenderedImmersiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var updateSubscription: EventSubscription?
    @State private var palmState = PalmMenuState()
    @State private var vignette = ComfortVignette()

    var body: some View {
        RealityView { content, attachments in
            content.add(model.rendered.root)
            content.add(model.rendered.fly.indicator)
            content.add(vignette.anchor)

            if let menu = attachments.entity(for: PalmMenuPlacement.attachmentID) {
                PalmMenuPlacement.install(menu, in: palmState)
                content.add(menu)
            }

            let frameModel = model
            let frameState = palmState
            let frameVignette = vignette
            updateSubscription?.cancel()
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated {
                    RenderedImmersiveView.updateFrame(model: frameModel, state: frameState, vignette: frameVignette,
                                                      deltaTime: Float(event.deltaTime))
                }
            }
        } update: { _, _ in
            // Driven per frame by the SceneEvents.Update subscription.
        } attachments: {
            Attachment(id: PalmMenuPlacement.attachmentID) {
                RenderedPalmMenu()
                    .environment(model)
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
    private static func updateFrame(model: AppModel, state: PalmMenuState, vignette: ComfortVignette, deltaTime: Float) {
        let dt = Swift.min(Swift.max(deltaTime, 0), 0.1)
        let pose = model.hands.devicePose()
        let viewer = model.rendered
        viewer.updateFrame(deltaTime: dt, devicePose: pose)
        vignette.update(speed: viewer.fly.currentSpeed, yawRate: viewer.fly.currentYawRate,
                        enabled: model.comfortVignette, deltaTime: dt)
        // No palm menu while flying (both fists clenched).
        PalmMenuPlacement.update(state: state, hands: model.hands, pose: pose, deltaTime: dt,
                                 suppressed: viewer.fly.isFlying)
    }
}

/// Exit · Viewpoints · Speed, on the left palm (the shared palm menu, v0.9 D1).
private struct RenderedPalmMenu: View {
    private enum Section {
        case viewpoints, speed
    }

    @Environment(AppModel.self) private var model
    @State private var section: Section?

    var body: some View {
        let viewer = model.rendered
        PalmMenuChrome {
            PalmMenuButton(title: "Exit", systemImage: "house", isDestructive: true) {
                model.requestLeaveRendered()
            }
            PalmMenuButton(title: "Viewpoints", systemImage: "mappin.and.ellipse", isOn: section == .viewpoints) {
                section = (section == .viewpoints) ? nil : .viewpoints
            }
            .disabled(!viewer.isReady)
            PalmMenuButton(title: "Speed \(DisplayFormat.multiplier(viewer.speed))", systemImage: "hare", isOn: section == .speed) {
                section = (section == .speed) ? nil : .speed
            }
        } expanded: {
            switch section {
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
