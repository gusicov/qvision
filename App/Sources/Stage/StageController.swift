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
/// `root` -> `worldRoot` -> { `environmentRoot`, `contentRoot` -> item roots }.
/// FlyController moves `worldRoot`; scene scale / table height live on `contentRoot`;
/// every persisted item transform is relative to `contentRoot`.
@MainActor final class StageController {
    let root: Entity
    let worldRoot: Entity
    /// Scene scale + pivot + table height. Items are its direct children. Never rotated.
    let contentRoot: Entity

    private let environmentRoot: Entity
    private var records: [UUID: ItemRecord] = [:]
    private var selectedID: UUID?
    /// Bumped by `clear()`; async item loads that started before a clear are discarded.
    private var contentGeneration = 0

    // Scene scale state
    private var sceneScale: Float = 1
    private var isTabletop = false
    /// Last user position (contentRoot space, y = 0) seen by `placementPoint`.
    private var lastUserPosition: SIMD3<Float>?
    /// Last placement point (contentRoot space); scene-scale pivot when there are no items.
    private var lastPlacement: SIMD3<Float>?

    // Inspect state
    private var isInspectMode = false

    // Environment state
    private var environments: [EnvironmentPreset: Entity] = [:]
    private var buildingPresets: Set<EnvironmentPreset> = []
    private var environmentGeneration = 0
    private var requestedPreset: EnvironmentPreset = .studio
    private var requestedMode: ViewMode = .mixed
    private weak var shownEnvironment: Entity?
    private weak var activeImageBasedLight: Entity?

    private static let selectionName = "selection"
    private static let minCollisionSize: Float = 0.02
    private static let minPartCollisionSize: Float = 0.01
    private static let cubeSize: Float = 0.3
    private static let minNearFaceDistance: Float = 0.8     // real-world meters
    private static let placementDistance: Float = 1.6       // real-world meters
    private static let placementSpread: Float = 0.7         // real-world meters
    private static let tabletopHeight: Float = 0.75
    private static let maxWalkNodes = 20_000

    init() {
        root = Entity()
        root.name = "StageRoot"
        worldRoot = Entity()
        worldRoot.name = "WorldRoot"
        environmentRoot = Entity()
        environmentRoot.name = "EnvironmentRoot"
        contentRoot = Entity()
        contentRoot.name = "ContentRoot"

        root.addChild(worldRoot)
        worldRoot.addChild(environmentRoot)
        worldRoot.addChild(contentRoot)
    }

    // MARK: - Project

    func load(project: Project, assetURL: (ProjectItem) -> URL?) async {
        clear()
        let generation = contentGeneration

        // Start building the environment while the items load.
        setEnvironment(project.environment, mode: project.viewMode)

        // Hide the content while it loads so the scene-scale pivot (computed from all items
        // at the end) doesn't make the content jump.
        contentRoot.isEnabled = false

        let layersByID = Self.layerMap(project.layers)
        for item in project.items {
            guard generation == contentGeneration else { return }
            do {
                try await addItem(item, assetURL: assetURL(item), freshPlacement: false, placement: item.transform.position)
                if let record = records[item.id] {
                    applyState(of: item, layer: layersByID[item.layerID], to: record)
                }
            } catch is CancellationError {
                return
            } catch {
                print("[Stage] Failed to load item \(item.name): \(error)")
            }
        }
        guard generation == contentGeneration else { return }
        apply(layers: project.layers, items: project.items)

        contentRoot.isEnabled = true
        applySceneScale()
    }

    func clear() {
        contentGeneration += 1
        for (_, record) in records {
            record.root.removeFromParent()
        }
        records.removeAll()
        selectedID = nil
        contentRoot.transform = .identity
        contentRoot.isEnabled = true
        lastPlacement = nil
        lastUserPosition = nil
    }

    // MARK: - Items

    @discardableResult
    func addItem(_ item: ProjectItem, assetURL: URL?, freshPlacement: Bool, placement: SIMD3<Float>) async throws -> Transform {
        let generation = contentGeneration

        // 1. Content entity (native size, never rescaled).
        let content: Entity
        if item.primitive != nil {
            content = Self.makeCube()
        } else if let url = assetURL {
            content = try await Entity(contentsOf: url)
        } else {
            throw StageLoadError.missingAsset(item.name)
        }

        // The stage was cleared (project closed / reloaded) while loading.
        guard generation == contentGeneration else { throw CancellationError() }

        // 2. Item root wraps the content: the root carries the item transform,
        //    the child carries the bottom-centre pivot offset.
        let itemRoot = Entity()
        itemRoot.name = item.name
        itemRoot.addChild(content)

        let initial = content.visualBounds(relativeTo: itemRoot)
        if !initial.isEmpty, Self.isFinite(initial.extents) {
            let pivot = SIMD3<Float>(initial.center.x, initial.min.y, initial.center.z)
            content.position = content.position - pivot
        }
        let bounds = content.visualBounds(relativeTo: itemRoot)
        let hasBounds = !bounds.isEmpty && Self.isFinite(bounds.extents)

        if freshPlacement {
            itemRoot.transform = .identity
            itemRoot.position = freshPosition(placement: placement,
                                              footprint: hasBounds ? bounds.extents : SIMD3<Float>(repeating: 0.1))
        } else {
            itemRoot.transform = item.transform.transform
        }

        // 3. Interaction: one bounding box in root space.
        let shape: ShapeResource
        if hasBounds {
            let size = SIMD3<Float>(
                Swift.max(bounds.extents.x, Self.minCollisionSize),
                Swift.max(bounds.extents.y, Self.minCollisionSize),
                Swift.max(bounds.extents.z, Self.minCollisionSize)
            )
            shape = ShapeResource.generateBox(size: size).offsetBy(translation: bounds.center)
        } else {
            shape = ShapeResource.generateBox(size: SIMD3<Float>(repeating: 0.1))
        }
        let rootCollision = CollisionComponent(shapes: [shape])
        itemRoot.components.set(rootCollision)
        itemRoot.components.set(InputTargetComponent())
        itemRoot.components.set(HoverEffectComponent())
        itemRoot.components.set(ItemComponent(id: item.id))
        Self.addGroundingShadows(to: content)
        if let ibl = activeImageBasedLight {
            itemRoot.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        }

        let record = ItemRecord(id: item.id, name: item.name, root: itemRoot, content: content,
                                assetURL: item.primitive == nil ? assetURL : nil,
                                rootCollision: rootCollision)

        // 4. Hidden internal parts (fresh and restored items alike).
        for path in item.hiddenParts {
            if let part = Self.resolvePart(path, in: content) {
                part.isEnabled = false
                record.hiddenParts.insert(path)
            }
        }

        // 5. Animations on repeat.
        for animation in content.availableAnimations {
            content.playAnimation(animation.repeat())
        }

        // 6. Insert (replacing any entity with the same id).
        records[item.id]?.root.removeFromParent()
        records[item.id] = record
        contentRoot.addChild(itemRoot)
        itemRoot.isEnabled = !item.isHidden

        if isInspectMode {
            enablePartColliders(record)
        }
        if selectedID == item.id {
            attachSelectionIndicator(to: record)
        }
        return itemRoot.transform
    }

    func removeItem(_ id: UUID) {
        records.removeValue(forKey: id)?.root.removeFromParent()
        if selectedID == id {
            selectedID = nil
        }
    }

    func setTransform(_ id: UUID, _ transform: Transform) {
        guard let record = records[id] else { return }
        record.root.transform = transform
        if selectedID == id {
            refreshSelectionIndicator()
        }
    }

    func apply(layers: [Layer], items: [ProjectItem]) {
        let layersByID = Self.layerMap(layers)
        for item in items {
            guard let record = records[item.id] else { continue }
            applyState(of: item, layer: layersByID[item.layerID], to: record)
        }
    }

    func entity(for id: UUID) -> Entity? {
        records[id]?.root
    }

    // MARK: - Scene scale

    func setSceneScale(_ scale: Float, tabletop: Bool) {
        sceneScale = scale.isFinite ? Swift.min(Swift.max(scale, 0.001), 10) : 1
        isTabletop = tabletop
        applySceneScale()
    }

    /// Scales `contentRoot` about the content's footprint centre on the floor (pivot stays put),
    /// optionally lifting it to table height.
    private func applySceneScale() {
        let s = sceneScale
        let pivot = scenePivot()
        var position = pivot * (1 - s)
        if isTabletop && s < 0.999 {
            position.y += Self.tabletopHeight
        }
        contentRoot.transform = Transform(scale: SIMD3<Float>(repeating: s),
                                          rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                          translation: position)
        refreshSelectionIndicator()
    }

    /// Footprint centre (cx, 0, cz) of all visible items in contentRoot space.
    private func scenePivot() -> SIMD3<Float> {
        var lo: SIMD3<Float>?
        var hi: SIMD3<Float>?
        func include(_ b: BoundingBox) {
            lo = lo.map { simd_min($0, b.min) } ?? b.min
            hi = hi.map { simd_max($0, b.max) } ?? b.max
        }

        for (_, record) in records where record.root.isEnabled {
            if let b = contentBounds(record) { include(b) }
        }
        if lo == nil {
            // Everything hidden: fall back to all items, measured from their meshes.
            for (_, record) in records {
                if let b = meshBounds(record) { include(b) }
            }
        }
        if let lo, let hi {
            let c = (lo + hi) * 0.5
            return SIMD3<Float>(c.x, 0, c.z)
        }
        let fallback = lastPlacement ?? SIMD3<Float>(0, 0, -Self.placementDistance)
        return SIMD3<Float>(fallback.x, 0, fallback.z)
    }

    // MARK: - Floor

    /// Moves the item so its bottom sits exactly on the floor (contentRoot y = 0).
    func dropToFloor(_ id: UUID) -> Transform? {
        guard let record = records[id], let b = contentBounds(record) ?? meshBounds(record) else { return nil }
        record.root.position.y -= b.min.y
        return record.root.transform
    }

    /// Snaps the item onto the floor if its bottom is within `worldThreshold` real-world meters of it.
    @discardableResult
    func snapToFloorIfClose(_ id: UUID, worldThreshold: Float) -> Bool {
        guard let record = records[id], let bottom = bottomY(record) else { return false }
        let threshold = worldThreshold / Swift.max(sceneScale, 0.0001)
        guard abs(bottom) < threshold else { return false }
        if bottom != 0 {
            record.root.position.y -= bottom
        }
        return true
    }

    /// Bottom of the item (contentRoot y). Called every drag frame, so the offset between the root
    /// and its bottom is cached while the item's scale and rotation stay the same.
    private func bottomY(_ record: ItemRecord) -> Float? {
        let scale = record.root.scale
        let rotation = record.root.orientation.vector
        if let cache = record.bottomCache, cache.scale == scale, cache.rotation == rotation {
            return record.root.position.y + cache.offset
        }
        guard let b = contentBounds(record) else { return nil }
        record.bottomCache = BottomCache(scale: scale, rotation: rotation, offset: b.min.y - record.root.position.y)
        return b.min.y
    }

    // MARK: - Selection

    func setSelected(_ id: UUID?) {
        if let previous = selectedID, let record = records[previous] {
            Self.removeSelectionIndicator(from: record.root)
        }
        selectedID = id
        if let id, let record = records[id] {
            attachSelectionIndicator(to: record)
        }
    }

    /// Rebuilds the selection box (e.g. after a scale change, so the edges keep a constant thickness).
    func refreshSelectionIndicator() {
        guard let id = selectedID, let record = records[id] else { return }
        attachSelectionIndicator(to: record)
    }

    private func attachSelectionIndicator(to record: ItemRecord) {
        let itemRoot = record.root
        Self.removeSelectionIndicator(from: itemRoot)

        let bounds = record.content.visualBounds(relativeTo: itemRoot)
        guard !bounds.isEmpty, Self.isFinite(bounds.extents) else { return }

        // Keep edges ~3 mm thick and the padding ~1 cm in world units regardless of item and scene scale.
        let scale = itemRoot.scale
        let maxScale = Swift.max(Swift.max(abs(scale.x), abs(scale.y)), Swift.max(abs(scale.z), 0.0001))
        let worldFactor = maxScale * Swift.max(sceneScale, 0.0001)
        let thickness: Float = 0.003 / worldFactor
        let padding: Float = 0.01 / worldFactor

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

    // MARK: - Inspect

    /// On: per-part box colliders (meshes only), root collider off. Off: back to the root collider.
    func setInspectMode(_ on: Bool) {
        guard on != isInspectMode else { return }
        isInspectMode = on
        for (_, record) in records {
            if on {
                enablePartColliders(record)
            } else {
                disablePartColliders(record)
            }
        }
    }

    private func enablePartColliders(_ record: ItemRecord) {
        guard record.partColliders.isEmpty else { return }
        record.root.components.remove(CollisionComponent.self)

        var visited = 0
        var stack: [Entity] = Array(record.content.children.reversed())
        if record.content.components.has(ModelComponent.self) {
            stack.append(record.content)
        }
        while let entity = stack.popLast() {
            visited += 1
            if visited > Self.maxWalkNodes { break }
            stack.append(contentsOf: entity.children.reversed())

            guard let model = entity.components[ModelComponent.self] else { continue }
            var b = model.mesh.bounds
            if b.isEmpty || !Self.isFinite(b.extents) {
                b = entity.visualBounds(relativeTo: entity)
            }
            guard !b.isEmpty, Self.isFinite(b.extents) else { continue }

            let state = PartColliderState(
                entity: entity,
                originalCollision: entity.components[CollisionComponent.self],
                hadInputTarget: entity.components.has(InputTargetComponent.self),
                hadHover: entity.components.has(HoverEffectComponent.self)
            )
            let size = SIMD3<Float>(
                Swift.max(b.extents.x, Self.minPartCollisionSize),
                Swift.max(b.extents.y, Self.minPartCollisionSize),
                Swift.max(b.extents.z, Self.minPartCollisionSize)
            )
            let shape = ShapeResource.generateBox(size: size).offsetBy(translation: b.center)
            entity.components.set(CollisionComponent(shapes: [shape]))
            if !state.hadHover {
                entity.components.set(HoverEffectComponent())
            }
            record.partColliders.append(state)
        }
        updatePartInputTargets(record)
    }

    private func disablePartColliders(_ record: ItemRecord) {
        for state in record.partColliders {
            let entity = state.entity
            if let original = state.originalCollision {
                entity.components.set(original)
            } else {
                entity.components.remove(CollisionComponent.self)
            }
            if !state.hadInputTarget {
                entity.components.remove(InputTargetComponent.self)
            }
            if !state.hadHover {
                entity.components.remove(HoverEffectComponent.self)
            }
        }
        record.partColliders.removeAll()
        record.root.components.set(record.rootCollision)
    }

    /// Locked layers get no InputTarget on their parts (the root's is handled by `applyState`).
    private func updatePartInputTargets(_ record: ItemRecord) {
        for state in record.partColliders {
            if record.isLocked {
                state.entity.components.remove(InputTargetComponent.self)
            } else if !state.entity.components.has(InputTargetComponent.self) {
                state.entity.components.set(InputTargetComponent())
            }
        }
    }

    /// Path of names from the item's content child down to `entity` ("Building/Floor_2/Wall_12").
    /// nil for the item root / content itself or an entity outside the item.
    func partID(for entity: Entity, itemID: UUID) -> String? {
        guard let record = records[itemID] else { return nil }
        let content = record.content
        var components: [String] = []
        var current: Entity? = entity
        while let node = current, node !== content {
            guard let parent = node.parent else { return nil }   // not under the content child
            components.append(Self.pathComponent(of: node, in: parent))
            current = parent
        }
        guard current === content, !components.isEmpty else { return nil }
        return components.reversed().joined(separator: "/")
    }

    func setPartHidden(itemID: UUID, partID: String, hidden: Bool) {
        guard let record = records[itemID],
              let part = Self.resolvePart(partID, in: record.content) else { return }
        part.isEnabled = !hidden
        if hidden {
            record.hiddenParts.insert(partID)
        } else {
            record.hiddenParts.remove(partID)
        }
        record.inspectionCache = nil
    }

    func inspect(itemID: UUID, partID: String?) -> InspectionInfo? {
        guard let record = records[itemID] else { return nil }

        let rootScale = record.root.scale
        let rootRotation = record.root.orientation.vector
        let cache: InspectionCache
        if let cached = record.inspectionCache,
           cached.rootScale == rootScale,
           cached.rootRotation == rootRotation {
            cache = cached
        } else {
            cache = buildInspection(record)
            record.inspectionCache = cache
        }

        return InspectionInfo(
            itemID: record.id,
            itemName: record.name,
            fileName: cache.fileName,
            fileSizeBytes: cache.fileSizeBytes,
            size: cache.size,
            triangleCount: cache.totals.triangles,
            vertexCount: cache.totals.vertices,
            meshCount: cache.totals.meshes,
            materialCount: cache.totals.materials,
            animationCount: cache.animationCount,
            parts: cache.parts,
            selectedPartID: partID
        )
    }

    private func buildInspection(_ record: ItemRecord) -> InspectionCache {
        var context = WalkContext()
        let contentMatrix = record.root.transform.matrix * record.content.transform.matrix
        let totals = collect(record.content, matrix: contentMatrix, path: nil, depth: -1, context: &context)

        var size = SIMD3<Float>(repeating: 0)
        let visual = record.root.isEnabled ? contentBounds(record) : nil
        if let visual {
            size = visual.extents
        } else if let b = totals.bounds {
            size = b.max - b.min
        }

        var fileSize: Int64?
        if let url = record.assetURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let number = attributes[.size] as? NSNumber {
            fileSize = number.int64Value
        }

        let parts = context.drafts.map { draft in
            PartInfo(id: draft.id,
                     name: draft.name,
                     depth: draft.depth,
                     isMesh: draft.isMesh,
                     triangleCount: draft.stats.triangles,
                     vertexCount: draft.stats.vertices,
                     materialCount: draft.stats.materials,
                     size: draft.stats.bounds.map { $0.max - $0.min } ?? SIMD3<Float>(repeating: 0),
                     isHidden: draft.isHidden)
        }

        return InspectionCache(
            rootScale: record.root.scale,
            rootRotation: record.root.orientation.vector,
            fileName: record.assetURL?.lastPathComponent,
            fileSizeBytes: fileSize,
            size: size,
            totals: totals,
            animationCount: record.content.availableAnimations.count,
            parts: parts
        )
    }

    /// Depth-first: stats of `entity` + descendants. Records a draft for every child (pre-order).
    /// `matrix` maps `entity`'s local space to contentRoot space.
    private func collect(_ entity: Entity, matrix: simd_float4x4, path: String?, depth: Int,
                         context: inout WalkContext) -> PartStats {
        var stats = PartStats()
        if let model = entity.components[ModelComponent.self] {
            let mesh = model.mesh
            let key = ObjectIdentifier(mesh)
            let counts: (triangles: Int, vertices: Int)
            if let cached = context.meshCounts[key] {
                counts = cached
            } else {
                counts = Self.meshCounts(mesh)
                context.meshCounts[key] = counts
            }
            stats.triangles += counts.triangles
            stats.vertices += counts.vertices
            stats.materials += model.materials.count
            stats.meshes += 1
            let b = mesh.bounds
            if !b.isEmpty, Self.isFinite(b.extents) {
                stats.include(Self.transformBounds(b, by: matrix))
            }
        }

        var seenNames = Set<String>()
        for (index, child) in entity.children.enumerated() {
            if context.visited >= Self.maxWalkNodes { break }
            context.visited += 1

            let component = Self.pathComponent(name: child.name, index: index, seenNames: &seenNames)
            let childPath = path.map { $0 + "/" + component } ?? component
            let draftIndex = context.drafts.count
            context.drafts.append(PartDraft(
                id: childPath,
                name: child.name.isEmpty ? "#\(index)" : child.name,
                depth: depth + 1,
                isMesh: child.components.has(ModelComponent.self),
                isHidden: !child.isEnabled,
                stats: PartStats()
            ))

            let childStats = collect(child, matrix: matrix * child.transform.matrix,
                                     path: childPath, depth: depth + 1, context: &context)
            context.drafts[draftIndex].stats = childStats
            stats.add(childStats)
        }
        return stats
    }

    private static func meshCounts(_ mesh: MeshResource) -> (triangles: Int, vertices: Int) {
        var triangles = 0
        var vertices = 0
        for model in mesh.contents.models {
            for part in model.parts {
                vertices += part.positions.count
                triangles += (part.triangleIndices?.count ?? 0) / 3
            }
        }
        return (triangles, vertices)
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
            for (_, record) in records {
                record.root.components.set(receiver)
            }
        } else {
            activeImageBasedLight = nil
            worldRoot.components.remove(ImageBasedLightReceiverComponent.self)
            for (_, record) in records {
                record.root.components.remove(ImageBasedLightReceiverComponent.self)
            }
        }
    }

    // MARK: - Placement

    /// Floor point (contentRoot space, y = 0) 1.6 m in front of the head; `slot` spreads items sideways.
    func placementPoint(devicePose: simd_float4x4?, slot: Int) -> SIMD3<Float> {
        let side = Float(((slot % 3) + 3) % 3 - 1)

        let worldPoint: SIMD3<Float>
        let worldUser: SIMD3<Float>
        if let pose = devicePose {
            let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            var forward = SIMD3<Float>(-pose.columns.2.x, 0, -pose.columns.2.z)
            let length = simd_length(forward)
            forward = length > 0.001 ? forward / length : SIMD3<Float>(0, 0, -1)
            let right = SIMD3<Float>(-forward.z, 0, forward.x)
            worldPoint = head + forward * Self.placementDistance + right * (side * Self.placementSpread)
            worldUser = head
        } else {
            worldPoint = SIMD3<Float>(side * Self.placementSpread, 0, -Self.placementDistance)
            worldUser = SIMD3<Float>(0, 0, 0)
        }

        var point = contentRoot.convert(position: worldPoint, from: nil)
        point.y = 0
        var user = contentRoot.convert(position: worldUser, from: nil)
        user.y = 0
        lastUserPosition = user
        lastPlacement = point
        return point
    }

    /// Footprint centre at `placement` (y = 0), pushed away from the user until the near face
    /// is >= 0.8 real-world meters away.
    private func freshPosition(placement: SIMD3<Float>, footprint: SIMD3<Float>) -> SIMD3<Float> {
        var position = SIMD3<Float>(placement.x, 0, placement.z)
        let user: SIMD3<Float>
        if let last = lastUserPosition {
            user = last
        } else {
            var origin = contentRoot.convert(position: SIMD3<Float>(0, 0, 0), from: nil)
            origin.y = 0
            user = origin
        }

        let halfFootprint = 0.5 * Swift.max(abs(footprint.x), abs(footprint.z))
        let required = halfFootprint + Self.minNearFaceDistance / Swift.max(sceneScale, 0.0001)

        var direction = position - user
        direction.y = 0
        let distance = simd_length(direction)
        if distance > 0.0001 {
            if distance < required {
                position = user + (direction / distance) * required
            }
        } else {
            // Degenerate (placement at the user): push straight along contentRoot -Z.
            position = user + SIMD3<Float>(0, 0, -required)
        }
        position.y = 0
        return position
    }

    // MARK: - Helpers

    /// A 0.3 m cube, wrapped so the inspector shows it as one part named "Cube".
    private static func makeCube() -> Entity {
        let wrapper = Entity()
        wrapper.name = "TestCube"
        let cube = ModelEntity(
            mesh: .generateBox(size: cubeSize, cornerRadius: 0.03),
            materials: [SimpleMaterial(color: .systemTeal, roughness: 0.35, isMetallic: false)]
        )
        cube.name = "Cube"
        wrapper.addChild(cube)
        return wrapper
    }

    /// Content bounds in contentRoot space (excludes the selection indicator). nil if empty.
    private func contentBounds(_ record: ItemRecord) -> BoundingBox? {
        let b = record.content.visualBounds(relativeTo: contentRoot)
        guard !b.isEmpty, Self.isFinite(b.extents), Self.isFinite(b.min) else { return nil }
        return b
    }

    /// Bounds from the mesh resources (works for disabled entities), contentRoot space.
    private func meshBounds(_ record: ItemRecord) -> BoundingBox? {
        var stats = PartStats()
        var visited = 0
        var stack: [(Entity, simd_float4x4)] = [(record.content, record.root.transform.matrix * record.content.transform.matrix)]
        while let next = stack.popLast() {
            let entity = next.0
            let matrix = next.1
            visited += 1
            if visited > Self.maxWalkNodes { break }
            if let model = entity.components[ModelComponent.self] {
                let b = model.mesh.bounds
                if !b.isEmpty, Self.isFinite(b.extents) {
                    stats.include(Self.transformBounds(b, by: matrix))
                }
            }
            for child in entity.children {
                stack.append((child, matrix * child.transform.matrix))
            }
        }
        return stats.bounds
    }

    private static func transformBounds(_ b: BoundingBox, by m: simd_float4x4) -> BoundingBox {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for x in [b.min.x, b.max.x] {
            for y in [b.min.y, b.max.y] {
                for z in [b.min.z, b.max.z] {
                    let p = m * SIMD4<Float>(x, y, z, 1)
                    let q = SIMD3<Float>(p.x, p.y, p.z)
                    lo = simd_min(lo, q)
                    hi = simd_max(hi, q)
                }
            }
        }
        return BoundingBox(min: lo, max: hi)
    }

    /// Path component for `child` under `parent`: its name, "#<index>" when unnamed,
    /// "name#<index>" when an earlier sibling has the same name.
    private static func pathComponent(of child: Entity, in parent: Entity) -> String {
        var seen = Set<String>()
        for (index, sibling) in parent.children.enumerated() {
            let component = pathComponent(name: sibling.name, index: index, seenNames: &seen)
            if sibling === child { return component }
        }
        return child.name.isEmpty ? "#0" : child.name
    }

    private static func pathComponent(name: String, index: Int, seenNames: inout Set<String>) -> String {
        if name.isEmpty { return "#\(index)" }
        if seenNames.contains(name) { return "\(name)#\(index)" }
        seenNames.insert(name)
        return name
    }

    /// Resolves a part path produced by `partID(for:itemID:)` below `content`.
    private static func resolvePart(_ path: String, in content: Entity) -> Entity? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        var current = content
        for component in components {
            let children = Array(current.children)
            if let match = children.first(where: { $0.name == component }) {
                current = match
                continue
            }
            // "#<index>" or "name#<index>"
            guard let hash = component.lastIndex(of: "#"),
                  let index = Int(component[component.index(after: hash)...]),
                  index >= 0, index < children.count else { return nil }
            current = children[index]
        }
        return current
    }

    private static func addGroundingShadows(to entity: Entity) {
        if entity.components.has(ModelComponent.self) {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
        for child in entity.children {
            addGroundingShadows(to: child)
        }
    }

    private func applyState(of item: ProjectItem, layer: Layer?, to record: ItemRecord) {
        let entity = record.root
        let layerVisible = layer?.isVisible ?? true
        let locked = layer?.isLocked ?? false
        entity.isEnabled = !item.isHidden && layerVisible
        record.isLocked = locked
        if locked {
            entity.components.remove(InputTargetComponent.self)
        } else if !entity.components.has(InputTargetComponent.self) {
            entity.components.set(InputTargetComponent())
        }
        if isInspectMode {
            updatePartInputTargets(record)
        }
    }

    private static func layerMap(_ layers: [Layer]) -> [UUID: Layer] {
        Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}

// MARK: - Private bookkeeping types

/// Everything the stage keeps per item.
@MainActor private final class ItemRecord {
    let id: UUID
    let name: String
    let root: Entity
    let content: Entity
    let assetURL: URL?
    let rootCollision: CollisionComponent
    var isLocked = false
    var hiddenParts: Set<String> = []
    var partColliders: [PartColliderState] = []
    var inspectionCache: InspectionCache?
    var bottomCache: BottomCache?

    init(id: UUID, name: String, root: Entity, content: Entity, assetURL: URL?, rootCollision: CollisionComponent) {
        self.id = id
        self.name = name
        self.root = root
        self.content = content
        self.assetURL = assetURL
        self.rootCollision = rootCollision
    }
}

/// What a part entity had before inspect mode added its collider (restored on exit).
private struct PartColliderState {
    let entity: Entity
    let originalCollision: CollisionComponent?
    let hadInputTarget: Bool
    let hadHover: Bool
}

private struct BottomCache {
    let scale: SIMD3<Float>
    let rotation: SIMD4<Float>
    let offset: Float
}

private struct PartStats {
    var triangles = 0
    var vertices = 0
    var materials = 0
    var meshes = 0
    var bounds: BoundingBox?

    mutating func include(_ b: BoundingBox) {
        if let current = bounds {
            bounds = BoundingBox(min: simd_min(current.min, b.min), max: simd_max(current.max, b.max))
        } else {
            bounds = b
        }
    }

    mutating func add(_ other: PartStats) {
        triangles += other.triangles
        vertices += other.vertices
        materials += other.materials
        meshes += other.meshes
        if let b = other.bounds { include(b) }
    }
}

private struct PartDraft {
    let id: String
    let name: String
    let depth: Int
    let isMesh: Bool
    let isHidden: Bool
    var stats: PartStats
}

private struct WalkContext {
    var visited = 0
    var drafts: [PartDraft] = []
    var meshCounts: [ObjectIdentifier: (triangles: Int, vertices: Int)] = [:]
}

private struct InspectionCache {
    let rootScale: SIMD3<Float>
    let rootRotation: SIMD4<Float>
    let fileName: String?
    let fileSizeBytes: Int64?
    let size: SIMD3<Float>
    let totals: PartStats
    let animationCount: Int
    let parts: [PartInfo]
}
