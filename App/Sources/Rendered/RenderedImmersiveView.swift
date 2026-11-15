import SwiftUI
import RealityKit
import simd

/// Content of `ImmersiveSpace(id: AppModel.renderedSpaceID)`: the baked scene, the fly indicator
/// and the palm menu (left palm toward your face: Exit / Start position / Speed).
struct RenderedImmersiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var updateSubscription: EventSubscription?
    @State private var palmState = RenderedPalmState()

    private static let palmMenuID = "renderedPalmMenu"
    private static let palmMenuLift: Float = 0.07     // off the palm, toward the face
    private static let palmMenuGrace: Float = 0.6     // stays tappable briefly after the palm turns

    var body: some View {
        RealityView { content, attachments in
            content.add(model.rendered.root)
            content.add(model.rendered.fly.indicator)

            if let menu = attachments.entity(for: Self.palmMenuID) {
                menu.components.set(BillboardComponent())
                menu.isEnabled = false
                content.add(menu)
                palmState.menu = menu
            }

            let frameModel = model
            let frameState = palmState
            updateSubscription?.cancel()
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated {
                    RenderedImmersiveView.updateFrame(model: frameModel, state: frameState,
                                                      deltaTime: Float(event.deltaTime))
                }
            }
        } update: { _, _ in
            // Driven per frame by the SceneEvents.Update subscription.
        } attachments: {
            Attachment(id: Self.palmMenuID) {
                RenderedPalmMenu()
                    .environment(model)
            }
        }
        .installsSceneActions()
        .onAppear {
            model.renderedDidAppear()
        }
        .task {
            await model.hands.start()
        }
        .task {
            // Hand tracking is shared with the stage space; if the previous space's onDisappear
            // stopped it after this space started it, start it again.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if model.hands.status == .idle {
                    await model.hands.start()
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
            model.hands.stop()
            model.renderedDidDisappear()
        }
    }

    // MARK: - Per frame

    @MainActor
    private static func updateFrame(model: AppModel, state: RenderedPalmState, deltaTime: Float) {
        let dt = Swift.min(Swift.max(deltaTime, 0), 0.1)
        let pose = model.hands.devicePose()
        model.rendered.updateFrame(deltaTime: dt, devicePose: pose)

        state.clock += dt
        guard let menu = state.menu else { return }
        let left = model.hands.left
        // No palm menu while flying (both fists clenched) or before the scene is shown.
        if left.isTracked && left.palmFacingUser && !left.isFist && !model.rendered.fly.isFlying, let pose {
            let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            var towardHead = head - left.palmCenter
            let length = simd_length(towardHead)
            towardHead = length > 0.001 ? towardHead / length : SIMD3<Float>(0, 1, 0)
            menu.setPosition(left.palmCenter + towardHead * palmMenuLift + SIMD3<Float>(0, 0.04, 0), relativeTo: nil)
            if !menu.isEnabled { menu.isEnabled = true }
            state.lastPalmSeen = state.clock
        } else if menu.isEnabled, state.clock - state.lastPalmSeen > palmMenuGrace {
            menu.isEnabled = false
        }
    }
}

/// Attachment entity and timing of the palm menu (read by the per-frame update).
final class RenderedPalmState {
    var menu: Entity?
    var clock: Float = 0
    var lastPalmSeen: Float = 0
}

/// Exit · Start position · Speed − n× +, on the left palm.
private struct RenderedPalmMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let viewer = model.rendered
        HStack(spacing: 10) {
            Button(role: .destructive) {
                model.requestLeaveRendered()
            } label: {
                Label("Exit", systemImage: "xmark")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button {
                viewer.resetToStart()
            } label: {
                Label("Start", systemImage: "figure.stand")
                    .font(.headline)
            }
            .disabled(!viewer.isReady)

            HStack(spacing: 4) {
                Button {
                    viewer.changeSpeed(by: -1)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(viewer.speed <= RenderedViewer.speedRange.lowerBound)
                .accessibilityLabel("Slower")

                VStack(spacing: 0) {
                    Text(DisplayFormat.multiplier(viewer.speed))
                        .font(.headline.monospacedDigit())
                    Text("Speed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 52)

                Button {
                    viewer.changeSpeed(by: 1)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewer.speed >= RenderedViewer.speedRange.upperBound)
                .accessibilityLabel("Faster")
            }
            .buttonBorderShape(.circle)
        }
        .buttonBorderShape(.capsule)
        .padding(10)
        .glassBackgroundEffect(in: Capsule())
    }
}
