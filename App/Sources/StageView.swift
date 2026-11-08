import SwiftUI
import RealityKit

/// Remembers where a gesture started so each update is applied relative to it.
@MainActor
final class GestureTracker {
    var dragStartPosition: SIMD3<Float>?
    var dragStartLocation: SIMD3<Float>?
    var startScale: SIMD3<Float>?
    var startOrientation: simd_quatf?
}

struct StageView: View {
    @Environment(AppModel.self) private var model
    @State private var tracker = GestureTracker()

    var body: some View {
        RealityView { content, attachments in
            content.add(model.stage.root)
            if let panel = attachments.entity(for: "stagePanel") {
                panel.position = [0.55, 1.05, -0.9]
                panel.components.set(BillboardComponent())
                content.add(panel)
            }
        } attachments: {
            Attachment(id: "stagePanel") {
                StagePanelView()
                    .environment(model)
            }
        }
        .gesture(dragGesture)
        .simultaneousGesture(scaleGesture)
        .simultaneousGesture(rotateGesture)
        .simultaneousGesture(tapGesture)
    }

    // MARK: Gestures (pinch + move = drag, two hands = scale / rotate)

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let target = value.entity.manipulableRoot else { return }
                let location = value.convert(value.location3D, from: .local, to: .scene)
                if tracker.dragStartPosition == nil {
                    tracker.dragStartPosition = target.position(relativeTo: nil)
                    tracker.dragStartLocation = value.convert(value.startLocation3D, from: .local, to: .scene)
                }
                guard let startPos = tracker.dragStartPosition,
                      let startLoc = tracker.dragStartLocation else { return }
                target.setPosition(startPos + (location - startLoc), relativeTo: nil)
            }
            .onEnded { _ in
                tracker.dragStartPosition = nil
                tracker.dragStartLocation = nil
            }
    }

    private var scaleGesture: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let target = value.entity.manipulableRoot else { return }
                if tracker.startScale == nil { tracker.startScale = target.scale }
                let factor = Float(value.magnification)
                if let start = tracker.startScale {
                    target.scale = simd_clamp(start * factor,
                                              SIMD3<Float>(repeating: 0.01),
                                              SIMD3<Float>(repeating: 100))
                }
            }
            .onEnded { _ in tracker.startScale = nil }
    }

    private var rotateGesture: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToAnyEntity()
            .onChanged { value in
                guard let target = value.entity.manipulableRoot else { return }
                if tracker.startOrientation == nil { tracker.startOrientation = target.orientation }
                let q = value.rotation.quaternion
                let delta = simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y),
                                       iz: Float(q.imag.z), r: Float(q.real))
                if let start = tracker.startOrientation {
                    target.orientation = delta * start
                }
            }
            .onEnded { _ in tracker.startOrientation = nil }
    }

    private var tapGesture: some Gesture {
        TapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                let id = value.entity.manipulableRoot?.components[ManipulableComponent.self]?.id
                model.select(id)
            }
    }
}

/// Small floating panel that lives inside the stage, next to your models.
struct StagePanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stage").font(.title2.bold())
            if let name = model.selectedName {
                Text("Selected: \(name)").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Pinch a model to select it").font(.callout).foregroundStyle(.secondary)
            }

            Button {
                model.setCubeVisible(!model.cubeVisible)
            } label: {
                Label(model.cubeVisible ? "Hide cube" : "Show cube",
                      systemImage: model.cubeVisible ? "eye.slash" : "eye")
            }

            Button {
                model.resetScene()
            } label: {
                Label("Reset scene", systemImage: "arrow.counterclockwise")
            }

            if let id = model.selectedID {
                Button(role: .destructive) {
                    model.removeFromStage(id)
                } label: {
                    Label("Remove selected", systemImage: "trash")
                }
            }
        }
        .padding(24)
        .frame(width: 320)
        .glassBackgroundEffect()
    }
}
