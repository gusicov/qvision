import Foundation
import Observation
import RealityKit
import simd
import SwiftUI
import UIKit

/// The open quantities project (v0.11 Q2): one package in memory at a time.
///
/// Scene graph: `root` → `placement` (the movable parent: position, yaw, scale) → the main USDZ
/// (`building`), plus the selection overlay and the batched context that `ArchViewerQuantities`
/// adds. Movement, rotation and scale only ever touch `placement`, so model, hatch and context
/// stay together. The Move handle is a sibling of `placement` (it keeps its size).
@MainActor
@Observable
final class QuantitiesSession {
    enum Phase: Equatable {
        case idle
        case loading(String)
        case ready
        case failed(String)
    }

    enum ScalePreset: String, CaseIterable, Identifiable {
        case table, s200, s100, s50

        var id: String { rawValue }

        var title: String {
            switch self {
            case .table: return "Table"
            case .s200: return "1:200"
            case .s100: return "1:100"
            case .s50: return "1:50"
            }
        }

        /// nil = fit the table (largest horizontal extent about 1.2 m).
        var factor: Float? {
            switch self {
            case .table: return nil
            case .s200: return 1.0 / 200
            case .s100: return 1.0 / 100
            case .s50: return 1.0 / 50
            }
        }
    }

    /// A building (CAMPUS) or top-level layer (BLOC) the user can hide.
    struct LayerToggle: Identifiable, Hashable {
        let layerId: String
        let name: String
        var id: String { layerId }
    }

    /// One article of a tapped element.
    struct TappedArticle: Identifiable, Hashable {
        let id: String
        let articleId: String
        let reviewId: String?
        let role: String
        let title: String
        let reference: String
        let quantity: String
    }

    /// What the last tap on the model found.
    struct Tapped: Equatable {
        var elementId: String?
        var detail: String
        var articles: [TappedArticle]
        /// The exact part under the tap on the hatched overlay.
        var part: AVQPart?
        var otherPartsHere: Int
        var message: String?

        static func == (lhs: Tapped, rhs: Tapped) -> Bool {
            lhs.elementId == rhs.elementId && lhs.part?.partId == rhs.part?.partId
                && lhs.articles == rhs.articles && lhs.message == rhs.message
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var packageID: String? = nil
    private(set) var title: String = ""
    private(set) var viewer: ArchViewerQuantities? = nil
    private(set) var hasContext = false
    /// The app's selection binding: panel, model taps and the 3D view share it.
    var selection: AVQSelection? = nil {
        didSet { if let selection { lastSelection = selection } }
    }
    /// The last article shown, so "Show whole building" can be switched off again.
    private(set) var lastSelection: AVQSelection? = nil
    private(set) var visibility = AVQVisibility()
    /// "Building visibility": opacity of the rest of the building while an article is shown.
    var contextOpacity: Double = 0.20 {
        didSet { viewer?.setContextOpacity(Float(contextOpacity)) }
    }
    private(set) var layerToggles: [LayerToggle] = []
    private(set) var togglesAreBuildings = false
    private(set) var tapped: Tapped? = nil
    private(set) var scalePreset: ScalePreset? = .table
    /// Collision shapes for picking: 0...1 while they are generated, nil when done.
    private(set) var pickingProgress: Double? = nil

    @ObservationIgnored let root = Entity()
    @ObservationIgnored private let placement = Entity()
    @ObservationIgnored let handle: ModelEntity
    @ObservationIgnored private let hands: HandTrackingService
    @ObservationIgnored private var building: Entity? = nil
    @ObservationIgnored private var grabVolume: Entity? = nil
    @ObservationIgnored private var layerEntities: [String: Entity] = [:]
    @ObservationIgnored private var articleIndex: [String: AVQArticle] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>? = nil
    @ObservationIgnored private var collisionTask: Task<Void, Never>? = nil
    @ObservationIgnored private var tapToken = 0

    // Placement (the parent's pose). Model space: base centred on the origin, metres.
    @ObservationIgnored private var position = SIMD3<Float>(0, 0.9, -1)
    @ObservationIgnored private var yaw: Float = 0
    @ObservationIgnored private var scale: Float = 0.01
    @ObservationIgnored private var fitScale: Float = 0.01
    @ObservationIgnored private var halfDiagonal: Float = 1
    /// Horizontal unit vector from the model toward the user (where the Move handle sits).
    @ObservationIgnored private var facing = SIMD3<Float>(0, 0, 1)
    @ObservationIgnored private var needsFirstPlacement = false

    // Running gestures.
    private enum Drag {
        case rotate(startYaw: Float, startAngle: Float)
        case slide(startYaw: Float, startPoint: SIMD3<Float>)
        case move(startPosition: SIMD3<Float>, startPoint: SIMD3<Float>)
    }
    @ObservationIgnored private var drag: Drag? = nil
    @ObservationIgnored private var dragStartPoint: SIMD3<Float>? = nil
    @ObservationIgnored private var scaleStart: Float? = nil

    static let overlayName = "ArchViewerQuantitySelection"
    private static let tableExtent: Float = 1.2
    private static let tableHeight: Float = 0.9
    private static let rotationGain: Float = 1.5

    init(hands: HandTrackingService) {
        self.hands = hands
        var material = UnlitMaterial(color: UIColor(white: 0.96, alpha: 1))
        material.faceCulling = .none
        handle = ModelEntity(mesh: .generateBox(width: 0.16, height: 0.014, depth: 0.045, cornerRadius: 0.007),
                             materials: [material])
        handle.name = "QVMoveHandle"
        handle.components.set(InputTargetComponent())
        handle.components.set(CollisionComponent(shapes: [.generateBox(width: 0.22, height: 0.05, depth: 0.09)]))
        handle.components.set(HoverEffectComponent())
        handle.isEnabled = false
        placement.name = "QVQuantitiesPlacement"
        root.addChild(placement)
        root.addChild(handle)
    }

    var isReady: Bool { phase == .ready }

    // MARK: - Load / release

    /// Loads a package (any previous one is detached and released first).
    func begin(_ package: LocalQuantityPackage) {
        release()
        let token = generation
        packageID = package.packageId
        title = package.name
        phase = .loading("Checking the project files…")
        loadTask = Task { @MainActor [weak self] in
            await self?.load(package, token: token)
        }
    }

    /// Detach the viewer, clear the selection, unload every entity (switch or leave).
    func release() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        collisionTask?.cancel()
        collisionTask = nil
        viewer?.detach()
        selection = nil
        lastSelection = nil
        tapped = nil
        viewer = nil
        for child in Array(placement.children) { child.removeFromParent() }
        building = nil
        grabVolume = nil
        layerEntities = [:]
        articleIndex = [:]
        layerToggles = []
        togglesAreBuildings = false
        visibility = AVQVisibility()
        hasContext = false
        pickingProgress = nil
        drag = nil
        dragStartPoint = nil
        scaleStart = nil
        handle.isEnabled = false
        packageID = nil
        title = ""
        phase = .idle
    }

    private func load(_ local: LocalQuantityPackage, token: Int) async {
        var loadedBuilding: Entity? = nil
        do {
            let package = try await AVQPackage.open(at: local.folder)
            guard token == generation else { return }
            phase = .loading("Loading the model…")
            let building = try await Entity(contentsOf: package.modelURL)
            guard token == generation else { return }
            var context: Entity? = nil
            if let url = package.contextModelURL {
                phase = .loading("Loading the context…")
                context = try? await Entity(contentsOf: url)
                guard token == generation else { return }
            }

            // Base centred on the placement origin (keeps the USDZ root's own rotation / scale).
            placement.isEnabled = false
            placement.transform = .identity
            building.name = "QVQuantityBuilding"
            placement.addChild(building)
            loadedBuilding = building
            let bounds = building.visualBounds(relativeTo: placement)
            if !bounds.isEmpty {
                building.position -= SIMD3<Float>(bounds.center.x, bounds.min.y, bounds.center.z)
            }
            phase = .loading("Preparing the quantities…")
            let viewer = try await ArchViewerQuantities(package: package, building: building,
                                                        placement: placement, reviewContext: context)
            guard token == generation else {
                viewer.detach()
                building.removeFromParent()
                return
            }
            viewer.setContextOpacity(Float(contextOpacity))
            building.components.set(InputTargetComponent())

            let extents = bounds.isEmpty ? SIMD3<Float>(repeating: 10) : bounds.extents
            let footprint = Swift.max(Swift.max(extents.x, extents.z), 0.01)
            fitScale = Self.tableExtent / footprint
            halfDiagonal = 0.5 * simd_length(SIMD2<Float>(extents.x, extents.z))
            scale = fitScale
            scalePreset = .table

            articleIndex = Dictionary(package.articles.map { ($0.articleId, $0) }, uniquingKeysWith: { a, _ in a })
            loadToggles(folder: local.folder, package: package, building: building)
            addGrabVolume(extents: extents)

            self.building = building
            self.viewer = viewer
            hasContext = context != nil
            placeInFrontOfUser(resetYaw: true)
            placement.isEnabled = true
            handle.isEnabled = true
            phase = .ready
            startCollisions(building: building, token: token)
        } catch is CancellationError {
            if token == generation { loadedBuilding?.removeFromParent() }
        } catch {
            guard token == generation else { return }
            loadedBuilding?.removeFromParent()
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Buildings / layers (AVQVisibility mirrored on the entities)

    private struct ManifestBuildings: Decodable {
        struct Model: Decodable {
            struct Building: Decodable {
                let buildingId: String
                let name: String
                let layerId: String
            }
            let buildings: [Building]?
        }
        let model: Model
    }

    private func loadToggles(folder: URL, package: AVQPackage, building: Entity) {
        var toggles: [LayerToggle] = []
        let manifest = (try? Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONDecoder().decode(ManifestBuildings.self, from: $0) }
        if let buildings = manifest?.model.buildings, !buildings.isEmpty {
            toggles = buildings.filter { package.layers[$0.layerId] != nil }
                .map { LayerToggle(layerId: $0.layerId, name: "\($0.buildingId) · \($0.name)") }
            togglesAreBuildings = true
        } else {
            // No buildings: the layers right under a single root layer (or the root layers).
            let roots = package.layers.values.filter { $0.parentId == nil }
            let candidates = roots.count == 1
                ? package.layers.values.filter { $0.parentId == roots[0].layerId }
                : roots
            toggles = candidates.filter { $0.defaultVisible && $0.defaultEnabled }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { LayerToggle(layerId: $0.layerId, name: $0.name) }
            togglesAreBuildings = false
        }
        var wanted: [String: String] = [:]
        for toggle in toggles {
            if let name = package.layers[toggle.layerId]?.entityName { wanted[name] = toggle.layerId }
        }
        var found: [String: Entity] = [:]
        var stack = [building]
        while let node = stack.popLast(), found.count < wanted.count {
            if let id = wanted[node.name], found[id] == nil { found[id] = node }
            stack.append(contentsOf: node.children)
        }
        layerEntities = found
        layerToggles = toggles.filter { found[$0.layerId] != nil }
    }

    func isLayerHidden(_ layerId: String) -> Bool {
        visibility.hiddenLayerIds.contains(layerId)
    }

    func setLayerHidden(_ layerId: String, _ hidden: Bool) {
        var next = visibility
        if hidden { next.hiddenLayerIds.insert(layerId) } else { next.hiddenLayerIds.remove(layerId) }
        guard next != visibility else { return }
        visibility = next
        layerEntities[layerId]?.isEnabled = !hidden
        if let tapped, let id = tapped.elementId, let viewer, !viewer.package.isVisible(id, using: next) {
            self.tapped = nil
        }
    }

    func showAllLayers() {
        for id in visibility.hiddenLayerIds { layerEntities[id]?.isEnabled = true }
        visibility.hiddenLayerIds = []
    }

    // MARK: - Normal view

    func normalView() {
        selection = nil
        viewer?.normalView()
    }

    /// "Show whole building": on = normal view; off = back to the last article.
    var showsWholeBuilding: Bool {
        get { selection == nil }
        set {
            if newValue {
                normalView()
            } else if selection == nil, let last = lastSelection {
                selection = last
            }
        }
    }

    // MARK: - Placement

    func recentre() {
        placeInFrontOfUser(resetYaw: false)
    }

    func setScalePreset(_ preset: ScalePreset) {
        scale = preset.factor ?? fitScale
        scalePreset = preset
        // Never put the user inside a bigger model: keep its edge in front of them.
        let (head, _) = headAndForward()
        let flat = SIMD2<Float>(position.x - head.x, position.z - head.z)
        if simd_length(flat) < halfDiagonal * scale + 0.3 {
            placeInFrontOfUser(resetYaw: false)
        } else {
            applyPlacement()
        }
    }

    /// The model's centre about 1 m in front of the user (further for a big scale), base at 0.9 m.
    private func placeInFrontOfUser(resetYaw: Bool) {
        let pose = hands.devicePose()
        needsFirstPlacement = (pose == nil)
        let (head, forward) = headAndForward(pose)
        let distance = Swift.max(1.0, halfDiagonal * scale + 0.35)
        position = SIMD3<Float>(head.x + forward.x * distance, Self.tableHeight, head.z + forward.z * distance)
        facing = -forward
        if resetYaw {
            yaw = 0
        }
        applyPlacement()
    }

    private func headAndForward(_ pose: simd_float4x4? = nil) -> (SIMD3<Float>, SIMD3<Float>) {
        guard let pose = pose ?? hands.devicePose() else {
            return (SIMD3<Float>(0, 1.5, 0), SIMD3<Float>(0, 0, -1))
        }
        let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        var forward = -SIMD3<Float>(pose.columns.2.x, 0, pose.columns.2.z)
        let length = simd_length(forward)
        forward = length > 0.01 ? forward / length : SIMD3<Float>(0, 0, -1)
        return (head, forward)
    }

    private func applyPlacement() {
        placement.transform = Transform(scale: SIMD3<Float>(repeating: scale),
                                        rotation: simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)),
                                        translation: position)
        let reach = halfDiagonal * scale + 0.08
        handle.position = position + facing * reach + SIMD3<Float>(0, -0.03, 0)
        handle.orientation = simd_quatf(angle: atan2(facing.x, facing.z), axis: SIMD3<Float>(0, 1, 0))
    }

    /// Per frame: the first placement waits for head tracking if it wasn't there at load time.
    func updateFrame() {
        if needsFirstPlacement, phase == .ready, hands.devicePose() != nil {
            placeInFrontOfUser(resetYaw: false)
        }
    }

    /// A coarse box that takes drags until the per-element collision shapes are ready.
    private func addGrabVolume(extents: SIMD3<Float>) {
        let volume = Entity()
        volume.name = "QVGrabVolume"
        let size = simd_max(extents, SIMD3<Float>(repeating: 0.1))
        volume.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: size).offsetBy(translation: SIMD3<Float>(0, extents.y / 2, 0))
        ]))
        volume.components.set(InputTargetComponent())
        placement.addChild(volume)
        grabVolume = volume
    }

    // MARK: - Gestures (all on `placement`)

    func dragChanged(on entity: Entity, start: SIMD3<Float>, current: SIMD3<Float>) {
        guard phase == .ready, scaleStart == nil else { return }
        if drag == nil || dragStartPoint != start {
            dragStartPoint = start
            if entity === handle || entity.parent === handle {
                drag = .move(startPosition: position, startPoint: start)
            } else {
                let v = start - position
                if simd_length(SIMD2<Float>(v.x, v.z)) > 0.04 {
                    drag = .rotate(startYaw: yaw, startAngle: atan2(v.x, v.z))
                } else {
                    drag = .slide(startYaw: yaw, startPoint: start)
                }
            }
        }
        guard let drag else { return }
        switch drag {
        case .move(let startPosition, let startPoint):
            var next = startPosition + (current - startPoint)
            next.y = Swift.min(Swift.max(next.y, 0.1), 2.5)
            position = next
            let (head, _) = headAndForward()
            let toUser = SIMD3<Float>(head.x - position.x, 0, head.z - position.z)
            if simd_length(toUser) > 0.05 { facing = simd_normalize(toUser) }
        case .rotate(let startYaw, let startAngle):
            let v = current - position
            guard simd_length(SIMD2<Float>(v.x, v.z)) > 0.02 else { return }
            yaw = startYaw + Self.rotationGain * Self.wrap(atan2(v.x, v.z) - startAngle)
        case .slide(let startYaw, let startPoint):
            let right = simd_cross(SIMD3<Float>(0, 1, 0), facing)
            yaw = startYaw + 3 * simd_dot(current - startPoint, right)
        }
        applyPlacement()
    }

    func dragEnded() {
        drag = nil
        dragStartPoint = nil
    }

    func magnifyChanged(_ factor: Float) {
        guard phase == .ready, factor.isFinite, factor > 0 else { return }
        if scaleStart == nil {
            scaleStart = scale
            // A two-hand pinch: undo what the first hand's drag started.
            switch drag {
            case .rotate(let startYaw, _)?, .slide(let startYaw, _)?:
                yaw = startYaw
            case .move(let startPosition, _)?:
                position = startPosition
            case nil:
                break
            }
            drag = nil
            dragStartPoint = nil
        }
        guard let start = scaleStart else { return }
        scale = Swift.min(Swift.max(start * factor, 0.0005), 0.2)
        scalePreset = nil
        applyPlacement()
    }

    func magnifyEnded() {
        scaleStart = nil
        if abs(scale - fitScale) / fitScale < 0.03 { scalePreset = .table }
        for preset in ScalePreset.allCases {
            if let factor = preset.factor, abs(scale - factor) / factor < 0.03 { scalePreset = preset }
        }
    }

    private static func wrap(_ angle: Float) -> Float {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    // MARK: - Tap an element

    func handleTap(on entity: Entity, scenePoint: SIMD3<Float>) async {
        guard phase == .ready, let viewer, let building else { return }
        if entity === handle || entity.parent === handle { return }
        if entity === grabVolume {
            tapped = Tapped(elementId: nil, detail: "", articles: [], part: nil, otherPartsHere: 0,
                            message: "Element picking is still being prepared. Try again in a moment.")
            return
        }
        tapToken += 1
        let token = tapToken
        var onOverlay = false
        var node: Entity? = entity
        while let current = node {
            if current.name == Self.overlayName { onOverlay = true; break }
            node = current.parent
        }
        let package = viewer.package
        var elementId = viewer.element(forHit: entity)?.elementId
        var part: AVQPart? = nil
        var ties = 0
        if onOverlay, viewer.selection != nil {
            let point = building.convert(position: scenePoint, from: nil)
            if let parts = try? await viewer.parts(atProjectPoint: point), let first = parts.first {
                guard token == tapToken, self.viewer === viewer else { return }
                part = first
                ties = parts.count - 1
                elementId = first.elementId
            }
        }
        guard let elementId, let element = package.elements[elementId] else {
            tapped = Tapped(elementId: nil, detail: "", articles: [], part: nil, otherPartsHere: 0,
                            message: "No quantity element here.")
            return
        }

        // Its articles (walk up to the owning assembly if the element itself lists none).
        var uses: AVQUses? = nil
        var owner: String? = elementId
        var visited: Set<String> = []
        while let id = owner, visited.insert(id).inserted {
            if let found = package.usesByElement[id] { uses = found; break }
            owner = package.elements[id]?.parentElementId
        }
        var rows: [TappedArticle] = []
        func add(_ articleId: String, role: String, reviewId: String? = nil) {
            guard let article = articleIndex[articleId] else { return }
            var quantity = article.displayQuantity.map { $0 + " " + article.displayUnit } ?? "—"
            var roleText = role
            if let reviewId, let review = article.reviews.first(where: { $0.reviewId == reviewId }) {
                quantity = review.displayQuantity + " " + review.unit
                roleText = "Review · " + review.label
            }
            rows.append(TappedArticle(id: "\(role)|\(articleId)|\(reviewId ?? "")", articleId: articleId,
                                      reviewId: reviewId, role: roleText, title: article.title,
                                      reference: article.reference, quantity: quantity))
        }
        for id in uses?.primary ?? [] { add(id, role: "Primary") }
        for id in uses?.hostedPrimary ?? [] { add(id, role: "Hosted") }
        for id in uses?.referenceOnly ?? [] { add(id, role: "Reference only") }
        for review in uses?.reviews ?? [] { add(review.articleId, role: "Review", reviewId: review.reviewId) }

        let layer = package.layers[element.layerId]?.fullPath ?? ""
        tapped = Tapped(elementId: elementId,
                        detail: [element.kind, layer].filter { !$0.isEmpty }.joined(separator: " · "),
                        articles: rows, part: part, otherPartsHere: ties,
                        message: rows.isEmpty ? "This element carries no article." : nil)
    }

    func choose(_ row: TappedArticle) {
        selection = AVQSelection(articleId: row.articleId, reviewId: row.reviewId)
    }

    /// Steps the shown article to the part found under the last tap.
    func selectTappedPart() {
        guard let part = tapped?.part, selection != nil else { return }
        selection?.partId = part.partId
    }

    func dismissTapped() {
        tapped = nil
    }

    // MARK: - Collision shapes for picking

    /// Per-mesh collision shapes, generated in batches after the model shows (never blocking
    /// the first frame): an exact static mesh for small meshes while the triangle budget lasts,
    /// a box from the mesh bounds otherwise.
    private func startCollisions(building: Entity, token: Int) {
        collisionTask?.cancel()
        pickingProgress = 0
        collisionTask = Task { @MainActor [weak self] in
            var meshes: [Entity] = []
            var stack = [building]
            while let node = stack.popLast() {
                if node.components.has(ModelComponent.self) { meshes.append(node) }
                stack.append(contentsOf: node.children)
            }
            // Let the model draw first.
            try? await Task.sleep(nanoseconds: 300_000_000)
            var budget = 400_000
            var index = 0
            let batch = 120
            while index < meshes.count {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                let end = Swift.min(index + batch, meshes.count)
                for entity in meshes[index..<end] {
                    guard let model = entity.components[ModelComponent.self],
                          !entity.components.has(CollisionComponent.self) else { continue }
                    let mesh = model.mesh
                    let bounds = mesh.bounds
                    guard !bounds.isEmpty else { continue }
                    var shape: ShapeResource? = nil
                    let triangles = Self.triangleCount(mesh)
                    if triangles > 0, triangles <= 1_500, triangles <= budget,
                       let exact = try? await ShapeResource.generateStaticMesh(from: mesh) {
                        guard self.generation == token else { return }
                        shape = exact
                        budget -= triangles
                    }
                    let fallback = ShapeResource.generateBox(size: simd_max(bounds.extents, SIMD3<Float>(repeating: 0.002)))
                        .offsetBy(translation: bounds.center)
                    entity.components.set(CollisionComponent(shapes: [shape ?? fallback]))
                }
                index = end
                self.pickingProgress = Double(index) / Double(Swift.max(meshes.count, 1))
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            guard let self, self.generation == token else { return }
            self.grabVolume?.removeFromParent()
            self.grabVolume = nil
            self.pickingProgress = nil
        }
    }

    private static func triangleCount(_ mesh: MeshResource) -> Int {
        var count = 0
        for model in mesh.contents.models {
            for part in model.parts {
                count += (part.triangleIndices?.count ?? 0) / 3
            }
        }
        return count
    }
}
