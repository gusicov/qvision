import SwiftUI
import RealityKit
import simd

/// Contents of the ImmersiveSpace: the stage, the fly indicator, the palm "Layers" button
/// and the floating Layers panel, plus direct-manipulation gestures on items.
struct StageView: View {
    @Environment(AppModel.self) private var model

    @State private var updateSubscription: EventSubscription?
    @State private var attachmentState = StageAttachmentState()
    @State private var gestureState = StageGestureState()

    private static let palmMenuID = "palmMenu"
    private static let layersPanelID = "layersPanel"

    var body: some View {
        RealityView { content, attachments in
            content.add(model.stage.root)
            content.add(model.fly.indicator)

            if let palm = attachments.entity(for: Self.palmMenuID) {
                palm.components.set(BillboardComponent())
                palm.isEnabled = false
                content.add(palm)
                attachmentState.palmMenu = palm
            }
            if let panel = attachments.entity(for: Self.layersPanelID) {
                panel.components.set(BillboardComponent())
                panel.isEnabled = false
                content.add(panel)
                attachmentState.layersPanel = panel
            }

            let frameModel = model
            let frameState = attachmentState
            updateSubscription?.cancel()
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated {
                    StageView.updateFrame(model: frameModel, state: frameState, deltaTime: Float(event.deltaTime))
                }
            }
        } update: { _, _ in
            // Everything dynamic is driven per frame by the SceneEvents.Update subscription.
        } attachments: {
            Attachment(id: Self.palmMenuID) {
                palmMenuButton
            }
            Attachment(id: Self.layersPanelID) {
                LayersPanelView(compact: true)
                    .environment(model)
                    .frame(width: 420, height: 560)
                    .glassBackgroundEffect()
            }
        }
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(rotateGesture)
        .simultaneousGesture(tapGesture)
        .task {
            await model.hands.start()
        }
        .onDisappear {
            model.hands.stop()
            updateSubscription?.cancel()
            updateSubscription = nil
        }
    }

    // MARK: - Attachments

    private var palmMenuButton: some View {
        Button {
            model.isLayersPanelVisible.toggle()
        } label: {
            Label("Layers", systemImage: "square.3.layers.3d")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 4)
        }
        .buttonBorderShape(.capsule)
        .glassBackgroundEffect(in: Capsule())
    }

    // MARK: - Per-frame update

    @MainActor
    private static func updateFrame(model: AppModel, state: StageAttachmentState, deltaTime: Float) {
        let dt = Swift.min(Swift.max(deltaTime, 0), 0.1)
        model.fly.update(deltaTime: dt, worldRoot: model.stage.worldRoot)

        let pose = model.hands.devicePose()
        let head: SIMD3<Float>? = pose.map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }

        updatePalmMenu(model: model, state: state, head: head)
        updateLayersPanel(model: model, state: state, pose: pose)
    }

    @MainActor
    private static func updatePalmMenu(model: AppModel, state: StageAttachmentState, head: SIMD3<Float>?) {
        guard let palm = state.palmMenu else { return }
        let left = model.hands.left
        guard left.isTracked, left.palmFacingUser, let head else {
            if palm.isEnabled { palm.isEnabled = false }
            return
        }
        let toHead = head - left.palmCenter
        let distance = simd_length(toHead)
        let direction = distance > 0.0001 ? toHead / distance : SIMD3<Float>(0, 0, 1)
        palm.setPosition(left.palmCenter + direction * 0.06, relativeTo: nil)
        // Orientation: BillboardComponent keeps the button facing the viewer.
        if !palm.isEnabled { palm.isEnabled = true }
    }

    @MainActor
    private static func updateLayersPanel(model: AppModel, state: StageAttachmentState, pose: simd_float4x4?) {
        guard let panel = state.layersPanel else { return }
        let wantsVisible = model.isLayersPanelVisible

        if wantsVisible && !state.panelWasVisible {
            panel.setPosition(layersPanelPosition(pose: pose, left: model.hands.left), relativeTo: nil)
        }
        state.panelWasVisible = wantsVisible
        if panel.isEnabled != wantsVisible {
            panel.isEnabled = wantsVisible
        }
    }

    /// ~0.45 m in front of the head, slightly to the left, at eye height (world space).
    private static func layersPanelPosition(pose: simd_float4x4?, left: HandState) -> SIMD3<Float> {
        if let pose {
            let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            var forward = SIMD3<Float>(-pose.columns.2.x, 0, -pose.columns.2.z)
            let length = simd_length(forward)
            forward = length > 0.001 ? forward / length : SIMD3<Float>(0, 0, -1)
            let right = SIMD3<Float>(-forward.z, 0, forward.x)
            var point = head + forward * 0.45 - right * 0.12
            point.y = head.y
            return point
        }
        if left.isTracked {
            return left.palmCenter + SIMD3<Float>(0, 0.2, 0)
        }
        return SIMD3<Float>(-0.12, 1.45, -0.45)
    }

    // MARK: - Gestures

    /// Walks up from the hit entity to the item root carrying `ItemComponent`.
    @MainActor
    private static func itemRoot(of entity: Entity) -> (id: UUID, root: Entity)? {
        var current: Entity? = entity
        while let candidate = current {
            if let component = candidate.components[ItemComponent.self] {
                return (component.id, candidate)
            }
            current = candidate.parent
        }
        return nil
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let hit = Self.itemRoot(of: value.entity),
                      !model.isItemLocked(hit.id) else { return }
                let id = hit.id
                let root = hit.root
                let state = gestureState
                if state.dragItemID != id || state.dragStartLocation3D != value.startLocation3D {
                    state.dragItemID = id
                    state.dragStartLocation3D = value.startLocation3D
                    state.dragStartScene = value.convert(value.startLocation3D, from: .local, to: .scene)
                    state.dragStartPosition = root.position(relativeTo: nil)
                }
                guard let startScene = state.dragStartScene,
                      let startPosition = state.dragStartPosition else { return }
                let current = value.convert(value.location3D, from: .local, to: .scene)
                root.setPosition(startPosition + (current - startScene), relativeTo: nil)
            }
            .onEnded { value in
                let state = gestureState
                if let hit = Self.itemRoot(of: value.entity), state.dragItemID == hit.id {
                    model.itemTransformChanged(hit.id, transform: hit.root.transform)
                }
                state.resetDrag()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let hit = Self.itemRoot(of: value.entity),
                      !model.isItemLocked(hit.id) else { return }
                let id = hit.id
                let root = hit.root
                let state = gestureState
                if state.scaleItemID != id || state.startScale == nil {
                    state.scaleItemID = id
                    state.startScale = root.scale
                }
                guard let startScale = state.startScale else { return }
                let factor = Float(value.magnification)
                guard factor.isFinite, factor > 0 else { return }
                let scaled = startScale * factor
                root.scale = SIMD3<Float>(
                    Self.clampScale(scaled.x),
                    Self.clampScale(scaled.y),
                    Self.clampScale(scaled.z)
                )
            }
            .onEnded { value in
                let state = gestureState
                if let hit = Self.itemRoot(of: value.entity), state.scaleItemID == hit.id {
                    model.itemTransformChanged(hit.id, transform: hit.root.transform)
                    model.stage.refreshSelectionIndicator()
                }
                state.resetScale()
            }
    }

    private var rotateGesture: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToAnyEntity()
            .onChanged { value in
                guard let hit = Self.itemRoot(of: value.entity),
                      !model.isItemLocked(hit.id) else { return }
                let id = hit.id
                let root = hit.root
                let state = gestureState
                if state.rotateItemID != id || state.startOrientation == nil {
                    state.rotateItemID = id
                    state.startOrientation = root.orientation
                }
                guard let start = state.startOrientation else { return }
                let q = value.rotation.quaternion
                let delta = simd_quatf(
                    ix: Float(q.imag.x),
                    iy: Float(q.imag.y),
                    iz: Float(q.imag.z),
                    r: Float(q.real)
                )
                root.orientation = simd_normalize(delta * start)
            }
            .onEnded { value in
                let state = gestureState
                if let hit = Self.itemRoot(of: value.entity), state.rotateItemID == hit.id {
                    model.itemTransformChanged(hit.id, transform: hit.root.transform)
                }
                state.resetRotation()
            }
    }

    private var tapGesture: some Gesture {
        TapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard let hit = Self.itemRoot(of: value.entity),
                      !model.isItemLocked(hit.id) else { return }
                model.select(hit.id)
            }
    }

    private static func clampScale(_ value: Float) -> Float {
        Swift.min(Swift.max(value, 0.01), 100)
    }
}

// MARK: - State holders

/// Entities of the RealityView attachments, read by the per-frame update.
final class StageAttachmentState {
    var palmMenu: Entity?
    var layersPanel: Entity?
    var panelWasVisible = false
}

/// Start values of the running gestures (cleared in every `onEnded`).
final class StageGestureState {
    var dragItemID: UUID?
    var dragStartLocation3D: Point3D?
    var dragStartScene: SIMD3<Float>?
    var dragStartPosition: SIMD3<Float>?

    var scaleItemID: UUID?
    var startScale: SIMD3<Float>?

    var rotateItemID: UUID?
    var startOrientation: simd_quatf?

    func resetDrag() {
        dragItemID = nil
        dragStartLocation3D = nil
        dragStartScene = nil
        dragStartPosition = nil
    }

    func resetScale() {
        scaleItemID = nil
        startScale = nil
    }

    func resetRotation() {
        rotateItemID = nil
        startOrientation = nil
    }
}
