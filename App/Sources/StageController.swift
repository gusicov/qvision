import RealityKit
import UIKit

/// Marks an entity as something the user can grab, move, rotate and scale.
/// `id` is nil for the demo cube and set for imported models.
struct ManipulableComponent: Component {
    var id: UUID?
    var initialTransform: Transform
}

extension Entity {
    /// Gestures hit the child mesh that was touched; walk up to the grabbable root.
    var manipulableRoot: Entity? {
        var current: Entity? = self
        while let e = current {
            if e.components.has(ManipulableComponent.self) { return e }
            current = e.parent
        }
        return nil
    }
}

@MainActor
final class StageController {
    /// Everything on the stage hangs off this root (the immersive space origin = your feet).
    let root = Entity()
    let cube: ModelEntity
    private var models: [UUID: Entity] = [:]

    init() {
        root.name = "StageRoot"
        cube = Self.makeCube()
        root.addChild(cube)
    }

    // MARK: Demo cube

    private static func makeCube() -> ModelEntity {
        let mesh = MeshResource.generateBox(size: 0.3, cornerRadius: 0.03)
        let material = SimpleMaterial(color: UIColor(red: 0.10, green: 0.65, blue: 0.75, alpha: 1),
                                      roughness: 0.35, isMetallic: false)
        let cube = ModelEntity(mesh: mesh, materials: [material])
        cube.name = "Demo Cube"
        cube.position = [0, 1.2, -1.2]
        makeManipulable(cube, id: nil)
        return cube
    }

    // MARK: Models

    func addModel(id: UUID, file: ModelFile, realWorldScale: Bool, slot: Int) async throws {
        let content = try await Entity(contentsOf: file.url)

        let wrapper = Entity()
        wrapper.name = file.name
        wrapper.addChild(content)

        // Fit to ~60 cm unless the user wants true 1:1 size (USD units are meters).
        let bounds = content.visualBounds(relativeTo: wrapper)
        let maxExtent = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        if !realWorldScale, maxExtent > 0 {
            content.scale *= SIMD3<Float>(repeating: 0.6 / maxExtent)
        }

        // Pivot at bottom-center so the model sits on whatever height we place it at.
        let scaled = content.visualBounds(relativeTo: wrapper)
        content.position -= SIMD3<Float>(scaled.center.x, scaled.min.y, scaled.center.z)

        if realWorldScale {
            wrapper.position = [0, 0, -3]                 // on the floor, 3 m ahead
        } else {
            let column = Float(slot % 3) - 1               // -1, 0, 1
            wrapper.position = [column * 0.8, 0.9, -1.6]  // table height, side by side
        }

        addGroundingShadows(content)
        for animation in content.availableAnimations {
            content.playAnimation(animation.repeat())
        }

        Self.makeManipulable(wrapper, id: id)
        root.addChild(wrapper)
        models[id] = wrapper
    }

    func removeModel(id: UUID) {
        models[id]?.removeFromParent()
        models[id] = nil
    }

    func resetAllTransforms() {
        for entity in [cube as Entity] + Array(models.values) {
            if let m = entity.components[ManipulableComponent.self] {
                entity.transform = m.initialTransform
            }
        }
    }

    // MARK: Helpers

    /// One bounding-box collider per object: cheap even for heavy architectural models,
    /// and you grab the whole object rather than a single sub-mesh.
    private static func makeManipulable(_ entity: Entity, id: UUID?) {
        let b = entity.visualBounds(relativeTo: entity)
        let size = SIMD3<Float>(max(b.extents.x, 0.02), max(b.extents.y, 0.02), max(b.extents.z, 0.02))
        let shape = ShapeResource.generateBox(size: size).offsetBy(translation: b.center)
        entity.components.set(CollisionComponent(shapes: [shape]))
        entity.components.set(InputTargetComponent())
        entity.components.set(HoverEffectComponent())
        entity.components.set(ManipulableComponent(id: id, initialTransform: entity.transform))
    }

    private func addGroundingShadows(_ entity: Entity) {
        if entity.components.has(ModelComponent.self) {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
        for child in entity.children { addGroundingShadows(child) }
    }
}
