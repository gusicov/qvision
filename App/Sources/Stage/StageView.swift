import SwiftUI
import RealityKit
import simd

/// Contents of the ImmersiveSpace: the stage, the fly indicator, the palm button
/// (left palm toward your face) that opens/closes the project panel WINDOW (a real
/// visionOS window with the system move bar), plus direct-manipulation gestures on items.
struct StageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var updateSubscription: EventSubscription?
    @State private var attachmentState = StageAttachmentState()
    @State private var gestureState = StageGestureState()
    /// v0.9 D1: the palm menu shared with Rendered and Server.
    @State private var palmState = PalmMenuState()
    @State private var vignette = ComfortVignette()

    var body: some View {
        RealityView { content, attachments in
            content.add(model.stage.root)
            content.add(model.fly.indicator)
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
                    StageView.updateFrame(model: frameModel, state: frameState, vignette: frameVignette,
                                          deltaTime: Float(event.deltaTime))
                }
            }
        } update: { _, _ in
            // Everything dynamic is driven per frame by the SceneEvents.Update subscription.
        } attachments: {
            Attachment(id: PalmMenuPlacement.attachmentID) {
                ProjectPalmMenu()
                    .environment(model)
            }
        }
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(rotateGesture)
        .simultaneousGesture(tapGesture)
        .task {
            await model.hands.start(owner: "stage")
        }
        .task {
            await vignette.prepare()
        }
        .task {
            // Fallback: without hand tracking there's no hand panel, so bring the main window back.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            openFallbackWindowIfNeeded()
        }
        .onDisappear {
            vignette.hide()
            model.hands.stop(owner: "stage")
            updateSubscription?.cancel()
            updateSubscription = nil
        }
    }

    private func openFallbackWindowIfNeeded() {
        let state = attachmentState
        guard !state.didOpenFallbackWindow, model.hands.status != .running else { return }
        state.didOpenFallbackWindow = true
        // Orchestrator integration: never open a second copy of the main window.
        guard !model.isMainWindowOpen else { return }
        openWindow(id: AppModel.mainWindowID)
    }

    // MARK: - Per-frame update

    @MainActor
    private static func updateFrame(model: AppModel, state: PalmMenuState, vignette: ComfortVignette, deltaTime: Float) {
        let dt = Swift.min(Swift.max(deltaTime, 0), 0.1)
        model.fly.update(deltaTime: dt, worldRoot: model.stage.worldRoot)
        let pose = model.hands.devicePose()
        // After fly mode moved worldRoot: sky dome + far ground re-centre on the head (L4).
        model.stage.updateFrame(devicePose: pose)
        vignette.update(speed: model.fly.currentSpeed, yawRate: model.fly.currentYawRate,
                        enabled: model.comfortVignette && model.isFlyModeEnabled, deltaTime: dt)
        // Palm menu: visible while the LEFT palm faces the user (+ a short grace to tap it).
        PalmMenuPlacement.update(state: state, hands: model.hands, pose: pose, deltaTime: dt,
                                 suppressed: model.fly.isFlying)
    }

    /// Head right vector flattened to XZ (column 0 of the device pose).
    private static func headRight(pose: simd_float4x4?) -> SIMD3<Float> {
        guard let pose else { return SIMD3<Float>(1, 0, 0) }
        let right = SIMD3<Float>(pose.columns.0.x, 0, pose.columns.0.z)
        let length = simd_length(right)
        return length > 0.001 ? right / length : SIMD3<Float>(1, 0, 0)
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

    private var isEditing: Bool {
        model.interactionMode == .edit
    }

    /// Belt-and-braces guard for fly mode: clenching / opening the fists produces a system
    /// pinch. Models aren't hit-testable while fly mode is on (StageController), and on top of
    /// that every gesture handler ignores input while flying and for 0.3 s after release.
    private var isFlightBlockingInput: Bool {
        model.isFlyModeEnabled || model.fly.isFlyingOrJustReleased
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                let state = gestureState
                if isFlightBlockingInput {
                    // Put a model that was being dragged back where the drag started, and ignore
                    // the rest of this drag.
                    if let id = state.dragItemID, let start = state.dragStartLocalPosition,
                       let root = model.stage.entity(for: id) {
                        root.position = start
                        model.stage.refreshSelectionIndicator()
                    }
                    state.resetDrag()
                    state.abortedDragStart = value.startLocation3D
                    return
                }
                guard state.abortedDragStart != value.startLocation3D else { return }
                state.abortedDragStart = nil
                guard isEditing,
                      let hit = Self.itemRoot(of: value.entity),
                      !model.isItemLocked(hit.id) else { return }
                let id = hit.id
                let root = hit.root
                if state.dragItemID != id || state.dragStartLocation3D != value.startLocation3D {
                    state.dragItemID = id
                    state.dragStartLocation3D = value.startLocation3D
                    state.dragStartScene = value.convert(value.startLocation3D, from: .local, to: .scene)
                    state.dragStartPosition = root.position(relativeTo: nil)
                    state.dragStartLocalPosition = root.position
                }
                guard let startScene = state.dragStartScene,
                      let startPosition = state.dragStartPosition else { return }
                let current = value.convert(value.location3D, from: .local, to: .scene)
                root.setPosition(startPosition + (current - startScene), relativeTo: nil)
                if model.snapToFloor {
                    model.stage.snapToFloorIfClose(id, worldThreshold: 0.10)
                }
            }
            .onEnded { value in
                let state = gestureState
                if let hit = Self.itemRoot(of: value.entity), state.dragItemID == hit.id {
                    model.itemTransformChanged(hit.id, transform: hit.root.transform)
                }
                state.resetDrag()
                state.abortedDragStart = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                let state = gestureState
                if isFlightBlockingInput {
                    if let id = state.scaleItemID, let start = state.startScale,
                       let root = model.stage.entity(for: id) {
                        root.scale = start
                        model.stage.refreshSelectionIndicator()
                    }
                    state.resetScale()
                    state.isScaleAborted = true
                    return
                }
                guard !state.isScaleAborted,
                      isEditing,
                      let hit = Self.itemRoot(of: value.entity),
                      !model.isItemLocked(hit.id) else { return }
                let id = hit.id
                let root = hit.root
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
                state.isScaleAborted = false
            }
    }

    private var rotateGesture: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToAnyEntity()
            .onChanged { value in
                let state = gestureState
                if isFlightBlockingInput {
                    if let id = state.rotateItemID, let start = state.startOrientation,
                       let root = model.stage.entity(for: id) {
                        root.orientation = start
                        model.stage.refreshSelectionIndicator()
                    }
                    state.resetRotation()
                    state.isRotationAborted = true
                    return
                }
                guard !state.isRotationAborted,
                      isEditing,
                      let hit = Self.itemRoot(of: value.entity),
                      !model.isItemLocked(hit.id) else { return }
                let id = hit.id
                let root = hit.root
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
                state.isRotationAborted = false
            }
    }

    private var tapGesture: some Gesture {
        TapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                // View mode: models are locked (and not hit-testable, so this rarely fires).
                guard model.interactionMode != .view,
                      !isFlightBlockingInput,
                      let hit = Self.itemRoot(of: value.entity),
                      !model.isItemLocked(hit.id) else { return }
                if model.interactionMode == .inspect {
                    let partID = model.stage.partID(for: value.entity, itemID: hit.id)
                    model.selectPart(itemID: hit.id, partID: partID)
                } else {
                    model.select(hit.id)
                }
            }
    }

    private static func clampScale(_ value: Float) -> Float {
        Swift.min(Swift.max(value, 0.01), 100)
    }
}

// MARK: - State holders

/// Entities of the RealityView attachments and hand-panel state, read by the per-frame update.
final class StageAttachmentState {
    var didOpenFallbackWindow = false
}

/// Start values of the running gestures (cleared in every `onEnded`).
final class StageGestureState {
    var dragItemID: UUID?
    var dragStartLocation3D: Point3D?
    var dragStartScene: SIMD3<Float>?
    var dragStartPosition: SIMD3<Float>?
    /// Item position relative to its parent (contentRoot) at drag start; stable while the
    /// world moves, so a drag interrupted by fly mode can be undone.
    var dragStartLocalPosition: SIMD3<Float>?
    /// Start location of a drag cancelled by fly mode: the rest of that drag is ignored.
    var abortedDragStart: Point3D?

    var scaleItemID: UUID?
    var startScale: SIMD3<Float>?
    /// A scale gesture was cancelled by fly mode; ignored until it ends.
    var isScaleAborted = false

    var rotateItemID: UUID?
    var startOrientation: simd_quatf?
    /// A rotation gesture was cancelled by fly mode; ignored until it ends.
    var isRotationAborted = false

    func resetDrag() {
        dragItemID = nil
        dragStartLocation3D = nil
        dragStartScene = nil
        dragStartPosition = nil
        dragStartLocalPosition = nil
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

// MARK: - Palm menu

/// Home · Panel · Speed (+ Undo / Redo), on the left palm: the shared palm menu (v0.9 D1).
private struct ProjectPalmMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isShowingSpeed = false

    var body: some View {
        PalmMenuChrome {
            PalmMenuButton(title: "Home", systemImage: "house", isDestructive: true) {
                model.requestLeave()
            }
            .disabled(model.isTransitioning)

            PalmMenuButton(title: model.isProjectPanelVisible ? "Hide panel" : "Panel",
                           systemImage: "slider.horizontal.3",
                           isOn: model.isProjectPanelVisible) {
                if model.isProjectPanelVisible {
                    // Tell AppModel this is a palm hide, not "user closed the last window" (L6).
                    model.notePanelHideRequested()
                    dismissWindow(id: AppModel.panelWindowID)
                } else {
                    openWindow(id: AppModel.panelWindowID)
                }
            }

            PalmMenuButton(title: "Speed \(DisplayFormat.multiplier(model.flySpeed))", systemImage: "hare",
                           isOn: isShowingSpeed) {
                isShowingSpeed.toggle()
            }

            // Undo / Redo right on the palm (L1).
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(minWidth: 28, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canUndo)
            .accessibilityLabel("Undo")

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(minWidth: 28, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canRedo)
            .accessibilityLabel("Redo")
        } expanded: {
            if isShowingSpeed {
                VStack(spacing: 8) {
                    SpeedPresetRow(speed: model.flySpeed) { model.flySpeed = $0 }
                    Toggle(isOn: Binding(get: { model.isFlyModeEnabled }, set: { model.isFlyModeEnabled = $0 })) {
                        Label("Fly mode (both fists)", systemImage: "airplane")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                }
                .frame(width: 400)
            }
        }
    }
}
