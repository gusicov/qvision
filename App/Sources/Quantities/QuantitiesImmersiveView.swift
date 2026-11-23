import SwiftUI
import RealityKit
import simd

/// Content of `ImmersiveSpace(id: AppModel.quantitiesSpaceID)` (mixed): the table-top model,
/// its Move handle and the shared palm menu (Exit · Recentre · Normal view).
///
/// Gestures (all applied to the placement parent by `QuantitiesSession`):
/// - drag on the model: turn it about its vertical axis;
/// - drag the Move handle: move it;
/// - pinch with both hands: scale;
/// - tap an element: its articles in the window.
struct QuantitiesImmersiveView: View {
    @Environment(AppModel.self) private var model

    @State private var updateSubscription: EventSubscription?
    @State private var palmState = PalmMenuState()

    private static let moveLabelID = "qvMoveLabel"

    var body: some View {
        RealityView { content, attachments in
            let session = model.quantities
            content.add(session.root)
            if let menu = attachments.entity(for: PalmMenuPlacement.attachmentID) {
                PalmMenuPlacement.install(menu, in: palmState)
                content.add(menu)
            }
            // A label from a previous opening of this space goes first.
            for child in Array(session.handle.children) { child.removeFromParent() }
            if let label = attachments.entity(for: Self.moveLabelID) {
                label.position = SIMD3<Float>(0, 0.04, 0)
                session.handle.addChild(label)
            }
            let frameModel = model
            let frameState = palmState
            updateSubscription?.cancel()
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated {
                    let dt = Swift.min(Swift.max(Float(event.deltaTime), 0), 0.1)
                    frameModel.quantities.updateFrame()
                    PalmMenuPlacement.update(state: frameState, hands: frameModel.hands,
                                             pose: frameModel.hands.devicePose(), deltaTime: dt, suppressed: false)
                }
            }
        } update: { _, _ in
        } attachments: {
            Attachment(id: PalmMenuPlacement.attachmentID) {
                QuantitiesPalmMenu()
                    .environment(model)
            }
            Attachment(id: Self.moveLabelID) {
                Label("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassBackgroundEffect(in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(tapGesture)
        .installsSceneActions()
        .onAppear {
            model.quantitiesDidAppear()
        }
        .task {
            await model.hands.start(owner: "quantities")
        }
        .task {
            // Hand tracking is shared between spaces: restart it if another space stopped it late.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if model.hands.status == .idle {
                    await model.hands.start(owner: "quantities")
                }
            }
        }
        .onDisappear {
            updateSubscription?.cancel()
            updateSubscription = nil
            model.hands.stop(owner: "quantities")
            model.quantitiesDidDisappear()
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                let start = value.convert(value.startLocation3D, from: .local, to: .scene)
                let current = value.convert(value.location3D, from: .local, to: .scene)
                model.quantities.dragChanged(on: value.entity, start: start, current: current)
            }
            .onEnded { _ in
                model.quantities.dragEnded()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                model.quantities.magnifyChanged(Float(value.magnification))
            }
            .onEnded { _ in
                model.quantities.magnifyEnded()
            }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                let point = value.convert(value.location3D, from: .local, to: .scene)
                let entity = value.entity
                Task { @MainActor in
                    await model.quantities.handleTap(on: entity, scenePoint: point)
                }
            }
    }
}

/// Exit · Recentre · Normal view on the left palm (the shared palm menu).
private struct QuantitiesPalmMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.quantities
        PalmMenuChrome {
            PalmMenuButton(title: "Exit", systemImage: "house", isDestructive: true) {
                model.requestLeaveQuantities()
            }
            PalmMenuButton(title: "Recentre", systemImage: "scope") {
                session.recentre()
            }
            .disabled(!session.isReady)
            PalmMenuButton(title: "Normal view", systemImage: "building.2") {
                session.normalView()
            }
            .disabled(session.selection == nil)
        } expanded: {
            EmptyView()
        }
    }
}
