import Foundation
import Observation
import RealityKit
import simd
import SwiftUI
import UIKit

/// The open quantities project (v0.11 Q2): one package in memory at a time.
///
/// Scene graph: `root` → `placement` (the movable parent: position, yaw, scale) → the context USDZ
/// (`building`, v0.11.1: one mesh per layer and material; the main per-element USDZ is never
/// loaded on the headset), plus the selection overlay that `ArchViewerQuantities` adds.
/// Movement, rotation and scale only ever touch `placement`, so model and hatch stay together.
/// Taps find their element through `QuantityPickIndex` (Data/pick.bin).
///
/// v0.11.2: direct manipulation, no Move handle. A one-hand pinch-and-drag that starts on the model
/// moves it freely in 3D; two hands scale it (magnify) and turn it about the vertical axis
/// (rotate); a tap selects an element. "Lock model" (persisted) turns every input target off.
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
    /// When the current open started (the window shows the elapsed seconds while loading).
    private(set) var loadStarted: Date? = nil
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

    /// v0.11.2: locked = the model ignores all input (no move, scale, turn or tap selection), so
    /// the quantities window always gets the pinch even when the model is in front of it.
    var isLocked: Bool = UserDefaults.standard.bool(forKey: QuantitiesSession.lockKey) {
        didSet {
            guard isLocked != oldValue else { return }
            UserDefaults.standard.set(isLocked, forKey: Self.lockKey)
            applyLock()
        }
    }

    @ObservationIgnored let root = Entity()
    @ObservationIgnored private let placement = Entity()
    @ObservationIgnored private let hands: HandTrackingService
    @ObservationIgnored private var building: Entity? = nil
    @ObservationIgnored private var grabVolume: Entity? = nil
    @ObservationIgnored private var layerEntities: [String: Entity] = [:]
    @ObservationIgnored private var articleIndex: [String: AVQArticle] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>? = nil
    @ObservationIgnored private var collisionTask: Task<Void, Never>? = nil
    @ObservationIgnored private var tapToken = 0
    @ObservationIgnored private var pick: QuantityPickIndex? = nil

    // Placement (the parent's pose). Model space: base centred on the origin, metres.
    @ObservationIgnored private var position = SIMD3<Float>(0, 0.9, -1)
    @ObservationIgnored private var yaw: Float = 0
    @ObservationIgnored private var scale: Float = 0.01
    @ObservationIgnored private var fitScale: Float = 0.01
    @ObservationIgnored private var halfDiagonal: Float = 1
    @ObservationIgnored private var needsFirstPlacement = false

    // Running gestures (v0.11.2).
    /// The running one-hand drag: where the model and the hand were when it took hold.
    private struct Drag {
        let gestureStart: SIMD3<Float>
        var anchorPosition: SIMD3<Float>?
        var anchorPoint: SIMD3<Float>
        var moving: Bool
    }
    @ObservationIgnored private var drag: Drag? = nil
    @ObservationIgnored private var scaleStart: Float? = nil
    @ObservationIgnored private var rotateStart: Float? = nil
    /// When the last drag / two-hand gesture that changed the model ended (a tap right after it
    /// is the end of that gesture, not a selection).
    @ObservationIgnored private var lastManipulationEnd: TimeInterval = 0

    static let overlayName = "ArchViewerQuantitySelection"
    private static let lockKey = "qv.quantities.lockModel"
    private static let tableExtent: Float = 1.2
    private static let tableHeight: Float = 0.9
    /// The hand must travel this far (scene metres) before a drag moves the model, so the small
    /// wobble of a tap never moves it.
    private static let dragDeadZone: Float = 0.012

    init(hands: HandTrackingService) {
        self.hands = hands
        placement.name = "QVQuantitiesPlacement"
        root.addChild(placement)
    }

    var isReady: Bool { phase == .ready }

    // MARK: - Load / release

    /// Loads a package (any previous one is detached and released first).
    func begin(_ package: LocalQuantityPackage) {
        release()
        let token = generation
        packageID = package.packageId
        title = package.name
        loadStarted = Date()
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
        pick = nil
        articleIndex = [:]
        layerToggles = []
        togglesAreBuildings = false
        visibility = AVQVisibility()
        hasContext = false
        pickingProgress = nil
        drag = nil
        scaleStart = nil
        rotateStart = nil
        packageID = nil
        title = ""
        loadStarted = nil
        phase = .idle
    }

    private func load(_ local: LocalQuantityPackage, token: Int) async {
        var loadedBuilding: Entity? = nil
        do {
            let package = try await AVQPackage.open(at: local.folder)
            guard token == generation else { return }
            guard let contextURL = package.contextModelURL else {
                throw AVQPackageError("This project has no context model, which QVision shows on the headset.")
            }
            let pickIndex = try await QuantityPickIndex.load(folder: local.folder, package: package)
            guard token == generation else { return }
            // v0.11.1: the context model (one mesh per layer and material) is the building.
            phase = .loading("Loading the model…")
            let building = try await Entity(contentsOf: contextURL)
            guard token == generation else { return }

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
                                                        placement: placement, reviewContext: nil)
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
            self.pick = pickIndex
            hasContext = false
            placeClearOfWindow(resetYaw: true)
            applyLock()
            placement.isEnabled = true
            phase = .ready
            loadStarted = nil
            startCollisions(building: building, token: token)
        } catch is CancellationError {
            if token == generation { loadedBuilding?.removeFromParent() }
        } catch {
            guard token == generation else { return }
            loadedBuilding?.removeFromParent()
            loadStarted = nil
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
        placeClearOfWindow(resetYaw: false)
    }

    func setScalePreset(_ preset: ScalePreset) {
        scale = preset.factor ?? fitScale
        scalePreset = preset
        // Never put the user inside a bigger model: keep its edge in front of them.
        let (head, _) = headAndForward()
        let flat = SIMD2<Float>(position.x - head.x, position.z - head.z)
        if simd_length(flat) < halfDiagonal * scale + 0.3 {
            placeClearOfWindow(resetYaw: false)
        } else {
            applyPlacement()
        }
    }

    /// v0.11.2: the window always wins. visionOS gives an immersive space no window positions,
    /// but the quantities window opens straight ahead of the user (default placement, about
    /// 1.1 m wide), and the Recentre button sits in that window, so the head's forward direction
    /// points at the window when the model is placed. The model goes to the front-right, far
    /// enough round that its whole footprint stays out of the window's angular span, with its
    /// base well below eye level (under the window's lower edge). It never sits between the user
    /// and the window, so it can't take the window's pinches. If the user later puts it in front
    /// of the window, Recentre or Lock model gives the window back.
    private func placeClearOfWindow(resetYaw: Bool) {
        let pose = hands.devicePose()
        needsFirstPlacement = (pose == nil)
        let (head, forward) = headAndForward(pose)
        let right = SIMD3<Float>(-forward.z, 0, forward.x)
        let radius = halfDiagonal * scale
        let distance = Swift.max(0.9, radius + 0.45)
        let windowHalfAngle: Float = 0.42          // ~24 degrees: half of a 1.1 m window at ~1.2 m
        let modelHalfAngle = asin(Swift.min(radius / distance, 0.95))
        let angle = Swift.min(windowHalfAngle + modelHalfAngle + 0.08, 1.25)   // at most ~72 degrees
        let direction = forward * cos(angle) + right * sin(angle)
        let baseHeight: Float = pose == nil
            ? Self.tableHeight
            : Swift.min(Swift.max(head.y - 0.7, 0.45), Self.tableHeight)
        position = SIMD3<Float>(head.x + direction.x * distance, baseHeight, head.z + direction.z * distance)
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
    }

    /// Per frame: the first placement waits for head tracking if it wasn't there at load time.
    func updateFrame() {
        if needsFirstPlacement, phase == .ready, hands.devicePose() != nil {
            placeClearOfWindow(resetYaw: false)
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
        var target = InputTargetComponent()
        target.isEnabled = !isLocked
        volume.components.set(target)
        placement.addChild(volume)
        grabVolume = volume
    }

    // MARK: - Lock

    /// Mirrors `isLocked` on every input target of the model: the building (its per-mesh
    /// collision shapes inherit it), the coarse grab volume and the selection overlay.
    private func applyLock() {
        for entity in [building, grabVolume].compactMap({ $0 }) {
            var target = entity.components[InputTargetComponent.self] ?? InputTargetComponent()
            target.isEnabled = !isLocked
            entity.components.set(target)
        }
        viewer?.setOverlayInput(!isLocked)
        if isLocked {
            cancelDrag()
            scaleStart = nil
            rotateStart = nil
        }
    }

    // MARK: - Gestures (v0.11.2: direct manipulation, all on `placement`)

    private var acceptsInput: Bool { phase == .ready && !isLocked }

    /// One hand: the model follows the pinch in 3D (left/right, up/down, nearer/further).
    func dragChanged(start: SIMD3<Float>, current: SIMD3<Float>) {
        guard acceptsInput, scaleStart == nil, rotateStart == nil else { return }
        if drag == nil || drag?.gestureStart != start {
            drag = Drag(gestureStart: start, anchorPosition: position, anchorPoint: start, moving: false)
        }
        guard var running = drag else { return }
        guard let anchorPosition = running.anchorPosition else {
            // A two-hand gesture took over and ended while this hand kept pinching: go on from here.
            running.anchorPosition = position
            running.anchorPoint = current
            running.moving = true
            drag = running
            return
        }
        let delta = current - running.anchorPoint
        if !running.moving {
            guard simd_length(delta) > Self.dragDeadZone else { return }
            running.moving = true
            drag = running
        }
        var next = anchorPosition + delta
        next.y = Swift.min(Swift.max(next.y, 0), 2.5)
        position = next
        applyPlacement()
    }

    func dragEnded() {
        if drag?.moving == true { lastManipulationEnd = ProcessInfo.processInfo.systemUptime }
        drag = nil
    }

    /// A second hand joins (or the model locks): undo what the one-hand drag did.
    private func cancelDrag() {
        guard var running = drag else { return }
        if let anchorPosition = running.anchorPosition, running.moving {
            position = anchorPosition
            applyPlacement()
        }
        running.anchorPosition = nil
        running.moving = false
        drag = running
    }

    func magnifyChanged(_ factor: Float) {
        guard acceptsInput, factor.isFinite, factor > 0 else { return }
        if scaleStart == nil {
            scaleStart = scale
            cancelDrag()
        }
        guard let start = scaleStart else { return }
        scale = Swift.min(Swift.max(start * factor, 0.0005), 0.2)
        scalePreset = nil
        applyPlacement()
    }

    func magnifyEnded() {
        guard scaleStart != nil else { return }
        scaleStart = nil
        lastManipulationEnd = ProcessInfo.processInfo.systemUptime
        if abs(scale - fitScale) / fitScale < 0.03 { scalePreset = .table }
        for preset in ScalePreset.allCases {
            if let factor = preset.factor, abs(scale - factor) / factor < 0.03 { scalePreset = preset }
        }
    }

    /// Two hands turning: `angle` (radians, counter-clockwise seen from above) since the start.
    func rotateChanged(_ angle: Float) {
        guard acceptsInput, angle.isFinite else { return }
        if rotateStart == nil {
            rotateStart = yaw
            cancelDrag()
        }
        guard let start = rotateStart else { return }
        yaw = start + angle
        applyPlacement()
    }

    func rotateEnded() {
        guard rotateStart != nil else { return }
        rotateStart = nil
        lastManipulationEnd = ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Tap an element

    func handleTap(on entity: Entity, scenePoint: SIMD3<Float>) async {
        guard acceptsInput, let viewer, let building else { return }
        // A drag (or a two-hand gesture) is never a tap.
        guard drag?.moving != true, scaleStart == nil, rotateStart == nil,
              ProcessInfo.processInfo.systemUptime - lastManipulationEnd > 0.3 else { return }
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
        if !onOverlay, elementId == nil, let pick {
            // The context mesh under the tap -> its nearest triangle in Data/pick.bin -> the element.
            let point = building.convert(position: scenePoint, from: nil)
            var names: [String] = []
            var node: Entity? = entity
            while let current = node, current !== building {
                names.append(current.name)
                node = current.parent
            }
            let meshNames = names
            let found = await Task.detached(priority: .userInitiated) {
                pick.element(meshNames: meshNames, point: point)
            }.value
            guard token == tapToken, self.viewer === viewer else { return }
            elementId = found
        }
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

    /// Static mesh collision shapes for the context meshes (about 500-600), generated in batches
    /// after the model shows; the window shows "Preparing taps N %" meanwhile. The exact element
    /// comes from Data/pick.bin, so the shape only has to say which mesh and where.
    private func startCollisions(building: Entity, token: Int) {
        collisionTask?.cancel()
        pickingProgress = 0
        collisionTask = Task { @MainActor [weak self] in
            var meshes: [(Entity, Int)] = []
            var total = 0
            var stack = [building]
            while let node = stack.popLast() {
                if let model = node.components[ModelComponent.self] {
                    let count = Swift.max(Self.triangleCount(model.mesh), 1)
                    meshes.append((node, count))
                    total += count
                }
                stack.append(contentsOf: node.children)
            }
            // Let the model draw first.
            try? await Task.sleep(nanoseconds: 300_000_000)
            var done = 0
            var batchTriangles = 0
            for (entity, count) in meshes {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if let model = entity.components[ModelComponent.self], !entity.components.has(CollisionComponent.self) {
                    let mesh = model.mesh
                    if let shape = try? await ShapeResource.generateStaticMesh(from: mesh) {
                        guard self.generation == token else { return }
                        entity.components.set(CollisionComponent(shapes: [shape]))
                    } else if !mesh.bounds.isEmpty {
                        let bounds = mesh.bounds
                        entity.components.set(CollisionComponent(shapes: [
                            ShapeResource.generateBox(size: simd_max(bounds.extents, SIMD3<Float>(repeating: 0.002)))
                                .offsetBy(translation: bounds.center)
                        ]))
                    }
                }
                done += count
                batchTriangles += count
                if batchTriangles >= 60_000 {
                    batchTriangles = 0
                    self.pickingProgress = Double(done) / Double(Swift.max(total, 1))
                    try? await Task.sleep(nanoseconds: 8_000_000)
                }
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
