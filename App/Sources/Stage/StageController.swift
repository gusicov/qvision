import Foundation
import RealityKit
import UIKit
import simd

enum StageLoadError: LocalizedError {
    case missingAsset(String)

    var errorDescription: String? {
        switch self {
        case .missingAsset(let name):
            return "The model file for \"\(name)\" could not be found."
        }
    }
}

/// Owns the RealityKit scene graph of the stage:
/// `root` -> `worldRoot` -> { `environmentRoot`, item roots }.
/// FlyController moves `worldRoot`; every item transform is relative to `worldRoot`.
@MainActor final class StageController {
    let root: Entity
    let worldRoot: Entity

    private let environmentRoot: Entity
    private var itemEntities: [UUID: Entity] = [:]
    private var selectedID: UUID?
    /// Bumped by `clear()`; async item loads that started before a clear are discarded.
    private var contentGeneration = 0

    // Environment state
    private var environments: [EnvironmentPreset: Entity] = [:]
    private var buildingPresets: Set<EnvironmentPreset> = []
    private var environmentGeneration = 0
    private var requestedPreset: EnvironmentPreset = .studio
    private var requestedMode: ViewMode = .mixed
    private weak var shownEnvironment: Entity?
    private weak var activeImageBasedLight: Entity?

    private static let selectionName = "selection"
    private static let fitMaxExtent: Float = 0.6
    private static let minCollisionSize: Float = 0.02

    init() {
        root = Entity()
        root.name = "StageRoot"
        worldRoot = Entity()
        worldRoot.name = "WorldRoot"
        environmentRoot = Entity()
        environmentRoot.name = "EnvironmentRoot"

        root.addChild(worldRoot)
        worldRoot.addChild(environmentRoot)
    }

    // MARK: - Project

    func load(project: Project, assetURL: (ProjectItem) -> URL?) async {
        clear()
        let generation = contentGeneration

        // Start building the environment while the items load.
        setEnvironment(project.environment, mode: project.viewMode)

        let layersByID = Self.layerMap(project.layers)
        for item in project.items {
            guard generation == contentGeneration else { return }
            do {
                try await addItem(item, assetURL: assetURL(item), fit: false, placement: item.transform.position)
                if let entity = itemEntities[item.id] {
                    applyState(of: item, layer: layersByID[item.layerID], to: entity)
                }
            } catch is CancellationError {
                return
            } catch {
                print("[Stage] Failed to load item \(item.name): \(error)")
            }
        }
        guard generation == contentGeneration else { return }
        apply(layers: project.layers, items: project.items)
    }

    func clear() {
        contentGeneration += 1
        for (_, entity) in itemEntities {
            entity.removeFromParent()
        }
        itemEntities.removeAll()
        selectedID = nil
    }

    // MARK: - Items

    @discardableResult
    func addItem(_ item: ProjectItem, assetURL: URL?, fit: Bool, placement: SIMD3<Float>) async throws -> Transform {
        let generation = contentGeneration

        // 1. Content entity.
        let content: Entity
        let isPrimitive: Bool
        if item.primitive != nil {
            content = Self.makeCube()
            isPrimitive = true
        } else if let url = assetURL {
            content = try await Entity(contentsOf: url)
            isPrimitive = false
        } else {
            throw StageLoadError.missingAsset(item.name)
        }

        // The stage was cleared (project closed / reloaded) while loading.
        guard generation == contentGeneration else { throw CancellationError() }

        // 2. Item root wraps the content so the root carries the item transform
        //    and the child carries the fitting offset.
        let itemRoot = Entity()
        itemRoot.name = item.name
        itemRoot.addChild(content)

        if fit {
            Self.fit(content: content, in: itemRoot, scaleToFit: !isPrimitive)
            itemRoot.transform = .identity
            itemRoot.position = placement
        } else {
            itemRoot.transform = item.transform.transform
        }

        // 3. Interaction: one bounding box in root space, computed after fitting.
        let bounds = itemRoot.visualBounds(relativeTo: itemRoot)
        let shape: ShapeResource
        if bounds.isEmpty || !Self.isFinite(bounds.extents) {
            shape = ShapeResource.generateBox(size: SIMD3<Float>(repeating: 0.1))
        } else {
            let size = SIMD3<Float>(
                Swift.max(bounds.extents.x, Self.minCollisionSize),
                Swift.max(bounds.extents.y, Self.minCollisionSize),
                Swift.max(bounds.extents.z, Self.minCollisionSize)
            )
            shape = ShapeResource.generateBox(size: size).offsetBy(translation: bounds.center)
        }
        itemRoot.components.set(CollisionComponent(shapes: [shape]))
        itemRoot.components.set(InputTargetComponent())
        itemRoot.components.set(HoverEffectComponent())
        itemRoot.components.set(ItemComponent(id: item.id))
        Self.addGroundingShadows(to: content)
        if let ibl = activeImageBasedLight {
            itemRoot.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        }

        // 4. Animations on repeat.
        for animation in content.availableAnimations {
            content.playAnimation(animation.repeat())
        }

        // 5. Insert (replacing any entity with the same id).
        itemEntities[item.id]?.removeFromParent()
        itemEntities[item.id] = itemRoot
        worldRoot.addChild(itemRoot)
        itemRoot.isEnabled = !item.isHidden

        if selectedID == item.id {
            attachSelectionIndicator(to: itemRoot)
        }
        return itemRoot.transform
    }

    func removeItem(_ id: UUID) {
        itemEntities.removeValue(forKey: id)?.removeFromParent()
        if selectedID == id {
            selectedID = nil
        }
    }

    func setTransform(_ id: UUID, _ transform: Transform) {
        guard let entity = itemEntities[id] else { return }
        entity.transform = transform
        if selectedID == id {
            refreshSelectionIndicator()
        }
    }

    func apply(layers: [Layer], items: [ProjectItem]) {
        let layersByID = Self.layerMap(layers)
        for item in items {
            guard let entity = itemEntities[item.id] else { continue }
            applyState(of: item, layer: layersByID[item.layerID], to: entity)
        }
    }

    func entity(for id: UUID) -> Entity? {
        itemEntities[id]
    }

    // MARK: - Selection

    func setSelected(_ id: UUID?) {
        if let previous = selectedID, let entity = itemEntities[previous] {
            Self.removeSelectionIndicator(from: entity)
        }
        selectedID = id
        if let id, let entity = itemEntities[id] {
            attachSelectionIndicator(to: entity)
        }
    }

    /// Rebuilds the selection box (e.g. after a scale change, so the edges keep a constant thickness).
    func refreshSelectionIndicator() {
        guard let id = selectedID, let entity = itemEntities[id] else { return }
        attachSelectionIndicator(to: entity)
    }

    private func attachSelectionIndicator(to itemRoot: Entity) {
        Self.removeSelectionIndicator(from: itemRoot)

        let bounds = itemRoot.visualBounds(relativeTo: itemRoot)
        guard !bounds.isEmpty, Self.isFinite(bounds.extents) else { return }

        // Keep edges ~3 mm thick and the padding ~1 cm in world units regardless of item scale.
        let scale = itemRoot.scale
        let maxScale = Swift.max(Swift.max(abs(scale.x), abs(scale.y)), Swift.max(abs(scale.z), 0.0001))
        let thickness: Float = 0.003 / maxScale
        let padding: Float = 0.01 / maxScale

        let lo = bounds.min - SIMD3<Float>(repeating: padding)
        let hi = bounds.max + SIMD3<Float>(repeating: padding)
        let center = (lo + hi) / 2
        let size = hi - lo

        let container = Entity()
        container.name = Self.selectionName
        container.components.set(OpacityComponent(opacity: 0.8))

        let material = UnlitMaterial(color: .white)
        let meshX = MeshResource.generateBox(size: SIMD3<Float>(size.x + thickness, thickness, thickness))
        let meshY = MeshResource.generateBox(size: SIMD3<Float>(thickness, size.y + thickness, thickness))
        let meshZ = MeshResource.generateBox(size: SIMD3<Float>(thickness, thickness, size.z + thickness))

        for a in [lo, hi] {
            for b in [lo, hi] {
                // Edges along X (vary y, z)
                let ex = ModelEntity(mesh: meshX, materials: [material])
                ex.position = SIMD3<Float>(center.x, a.y, b.z)
                container.addChild(ex)
                // Edges along Y (vary x, z)
                let ey = ModelEntity(mesh: meshY, materials: [material])
                ey.position = SIMD3<Float>(a.x, center.y, b.z)
                container.addChild(ey)
                // Edges along Z (vary x, y)
                let ez = ModelEntity(mesh: meshZ, materials: [material])
                ez.position = SIMD3<Float>(a.x, b.y, center.z)
                container.addChild(ez)
            }
        }
        itemRoot.addChild(container)
    }

    private static func removeSelectionIndicator(from itemRoot: Entity) {
        let indicators = itemRoot.children.filter { $0.name == selectionName }
        for indicator in indicators {
            indicator.removeFromParent()
        }
    }

    // MARK: - Environment

    func setEnvironment(_ preset: EnvironmentPreset, mode: ViewMode) {
        environmentGeneration += 1
        requestedPreset = preset
        requestedMode = mode
        applyEnvironmentState()

        guard mode == .full, environments[preset] == nil, !buildingPresets.contains(preset) else { return }
        buildingPresets.insert(preset)
        let generation = environmentGeneration

        Task { [weak self] in
            let environment = await EnvironmentBuilder.make(preset)
            guard let self else { return }
            self.buildingPresets.remove(preset)
            environment.isEnabled = false
            self.environments[preset] = environment
            self.environmentRoot.addChild(environment)
            // A stale task only applies if a newer request for the same preset joined this build.
            guard generation == self.environmentGeneration || self.requestedPreset == preset else { return }
            self.applyEnvironmentState()
        }
    }

    /// Shows the requested environment (only in `.full`) and wires image-based lighting to it.
    private func applyEnvironmentState() {
        let target: Entity?
        if requestedMode == .full {
            // While the requested preset is still being built, keep whatever is shown.
            target = environments[requestedPreset] ?? shownEnvironment
        } else {
            target = nil
        }

        for (_, environment) in environments {
            environment.isEnabled = (environment === target)
        }
        shownEnvironment = target

        let ibl = target?.findEntity(named: EnvironmentBuilder.imageBasedLightName)
        if let ibl, ibl.components.has(ImageBasedLightComponent.self) {
            activeImageBasedLight = ibl
            let receiver = ImageBasedLightReceiverComponent(imageBasedLight: ibl)
            worldRoot.components.set(receiver)
            for (_, entity) in itemEntities {
                entity.components.set(receiver)
            }
        } else {
            activeImageBasedLight = nil
            worldRoot.components.remove(ImageBasedLightReceiverComponent.self)
            for (_, entity) in itemEntities {
                entity.components.remove(ImageBasedLightReceiverComponent.self)
            }
        }
    }

    // MARK: - Placement

    func placementPoint(devicePose: simd_float4x4?, slot: Int) -> SIMD3<Float> {
        let side = Float(((slot % 3) + 3) % 3 - 1)

        guard let pose = devicePose else {
            return SIMD3<Float>(side * 0.7, 1.0, -1.5)
        }

        let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        var forward = SIMD3<Float>(-pose.columns.2.x, 0, -pose.columns.2.z)
        let length = simd_length(forward)
        forward = length > 0.001 ? forward / length : SIMD3<Float>(0, 0, -1)
        let right = SIMD3<Float>(-forward.z, 0, forward.x)

        var point = head + forward * 1.5 + right * (side * 0.7)
        point.y = head.y - 0.35
        return worldRoot.convert(position: point, from: nil)
    }

    // MARK: - Helpers

    private static func makeCube() -> ModelEntity {
        ModelEntity(
            mesh: .generateBox(size: 0.3, cornerRadius: 0.03),
            materials: [SimpleMaterial(color: .systemTeal, roughness: 0.35, isMetallic: false)]
        )
    }

    /// Scales `content` so its largest extent is `fitMaxExtent` (if `scaleToFit`) and offsets it
    /// so the bottom-centre of its bounds sits at the item root's origin.
    private static func fit(content: Entity, in itemRoot: Entity, scaleToFit: Bool) {
        let initial = content.visualBounds(relativeTo: itemRoot)
        guard !initial.isEmpty, isFinite(initial.extents) else { return }

        if scaleToFit {
            let maxExtent = Swift.max(initial.extents.x, Swift.max(initial.extents.y, initial.extents.z))
            if maxExtent > 0.0001 {
                content.scale = content.scale * (fitMaxExtent / maxExtent)
            }
        }

        let scaled = content.visualBounds(relativeTo: itemRoot)
        guard !scaled.isEmpty, isFinite(scaled.extents) else { return }
        let pivot = SIMD3<Float>(scaled.center.x, scaled.min.y, scaled.center.z)
        content.position = content.position - pivot
    }

    private static func addGroundingShadows(to entity: Entity) {
        if entity.components.has(ModelComponent.self) {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
        for child in entity.children {
            addGroundingShadows(to: child)
        }
    }

    private func applyState(of item: ProjectItem, layer: Layer?, to entity: Entity) {
        let layerVisible = layer?.isVisible ?? true
        let locked = layer?.isLocked ?? false
        entity.isEnabled = !item.isHidden && layerVisible
        if locked {
            entity.components.remove(InputTargetComponent.self)
        } else if !entity.components.has(InputTargetComponent.self) {
            entity.components.set(InputTargetComponent())
        }
    }

    private static func layerMap(_ layers: [Layer]) -> [UUID: Layer] {
        Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}
