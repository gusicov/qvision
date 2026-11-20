import Foundation
import Observation
import RealityKit
import UIKit
import simd

/// The v0.8 Rendered viewer (R4): one baked, pre-lit scene at real scale, shown unlit.
///
/// Entity tree (added to the "rendered" ImmersiveSpace by RenderedImmersiveView):
///
///     root (identity)
///       worldRoot            moved by fist-fly (FlyController: translation + yaw about the head)
///         placement          puts the sidecar start point under the user's feet, facing its yaw
///           scene            the loaded USDZ (its own transform untouched)
///         sky                far sky dome (only if the scene has no sky), follows the head
///
/// Loading: `Entity(contentsOf:)` (asynchronous, off the main thread), then every material of
/// every `ModelComponent` becomes an `UnlitMaterial` that keeps the base colour texture + tint
/// and the opacity (transparent blending when < 1) and skips post-process tone mapping (the bake
/// is already tone-mapped). No lights, no IBL, no grounding shadows. Everything is released on
/// `release()` (leaving the space).
@MainActor
@Observable
final class RenderedViewer {
    enum Phase: Equatable {
        case idle
        /// Message + progress 0...1 (nil = indeterminate).
        case loading(String, Double?)
        case ready
        case failed(String)
    }

    /// A place to stand: the sidecar start, a named viewpoint, or where the user was last time.
    /// `point` and `yaw` (radians) are in placement space (= the scene's parent space).
    struct Viewpoint: Identifiable, Equatable {
        let id: Int
        let name: String
        let point: SIMD3<Float>
        let yaw: Float
        let atEyeHeight: Bool
    }

    static let speedRange: ClosedRange<Float> = 1...10
    private static let speedKey = "qvision.renderedFlySpeed"

    /// Files above this are refused before loading (R2 budget: USDZ <= ~500 MB).
    private static let maxFileBytes: Int64 = 1_500_000_000
    /// Above this the load is attempted, but a failure mentions the size.
    private static let budgetFileBytes: Int64 = 500_000_000

    private static let minSkyRadius: Float = 450
    private static let maxSkyRadius: Float = 5_000
    private static let skyExtentFactor: Float = 1.5
    /// Scene geometry larger than this is assumed to include its own sky / environment sphere.
    private static let skyGeometryExtent: Float = 1_500

    private(set) var phase: Phase = .idle
    private(set) var scene: RenderedScene? = nil
    /// Facts about the loaded scene for the session panel ("12.4 × 9.8 × 6.1 m").
    private(set) var sceneSize: SIMD3<Float>? = nil
    private(set) var hasOwnSky = false
    /// How the materials ended up: "HD shading: 238 shader-graph materials · 12 baked" (nil before loading).
    /// Shader-graph materials (an HD package's albedo x lightmap graph) are kept; the others become unlit.
    private(set) var shadingSummary: String? = nil
    /// v0.9 D2: places to jump to. Index 0 is always "Start".
    private(set) var viewpoints: [Viewpoint] = []
    /// v0.9 B3: the scene opened where the user left it last time (Start is one tap away).
    private(set) var resumedLastPosition = false

    // v0.10 E3: Environment packages (`"kind": "environment"`).
    /// The open scene is an Environment: no fist-fly, a viewing area, rooms instead of viewpoints.
    private(set) var isEnvironment = false
    /// Its group ("Tradition Place"); the palm menu lists the other rooms of it.
    private(set) var environmentGroup: String? = nil
    /// The user walked more than ~1 m beyond the viewing area: the scene fades, a hint shows.
    private(set) var isOutsideViewingArea = false
    /// Fading out to switch to another room.
    private(set) var isSwitchingRoom = false

    /// Fist-fly speed multiplier (1...10, R4), remembered across launches.
    var speed: Float = 1 {
        didSet {
            let clamped = Self.clampSpeed(speed)
            fly.speed = clamped
            UserDefaults.standard.set(Double(clamped), forKey: Self.speedKey)
        }
    }

    var isReady: Bool { phase == .ready }

    @ObservationIgnored let root: Entity
    @ObservationIgnored let worldRoot: Entity
    @ObservationIgnored let fly: FlyController

    @ObservationIgnored private let placement: Entity
    @ObservationIgnored private let hands: HandTrackingService
    @ObservationIgnored private var content: Entity? = nil
    @ObservationIgnored private var sky: Entity? = nil
    @ObservationIgnored private var skyBaseScale = SIMD3<Float>(-1, 1, 1)
    @ObservationIgnored private var skyScaleFactor: Float = 1
    @ObservationIgnored private var loadTask: Task<Void, Never>? = nil
    @ObservationIgnored private var loadToken = 0
    /// Start point and view direction in placement space (= the scene's parent space).
    @ObservationIgnored private var startPoint = SIMD3<Float>(0, 0, 0)
    @ObservationIgnored private var startYaw: Float = 0
    @ObservationIgnored private var startAtEyeHeight = false
    /// The placement was made without a head pose: redo it once the first pose arrives.
    @ObservationIgnored private var needsPosePlacement = false
    /// Where the scene is placed right now (for the redo above).
    @ObservationIgnored private var currentTarget: Viewpoint? = nil
    @ObservationIgnored private var fadeTask: Task<Void, Never>? = nil
    @ObservationIgnored private var fadeOpacity: Float = 1
    /// Last-position bookkeeping (B3).
    @ObservationIgnored private var poseSaveClock: Float = 0
    @ObservationIgnored private var lastSavedPose: SIMD4<Float>? = nil
    @ObservationIgnored private var sceneBounds: BoundingBox? = nil
    /// Environments: viewing-area centre (placement space, floor level) and radius (m).
    @ObservationIgnored private var viewingCenter: SIMD3<Float>? = nil
    @ObservationIgnored private var viewingRadius: Float = 1.5
    @ObservationIgnored private var areaOpacity: Float = 1
    /// The next scene fades in when it is ready (room switch).
    @ObservationIgnored private var fadeInWhenReady = false
    @ObservationIgnored private var switchTask: Task<Void, Never>? = nil

    /// Beyond `radius + outsideMargin` the scene starts to fade; it reaches `minAreaOpacity`
    /// `fadeDistance` metres further.
    private static let outsideMargin: Float = 1.0
    private static let fadeDistance: Float = 1.0
    private static let minAreaOpacity: Float = 0.12
    /// Environment packages are budgeted at up to 12 atlases of 4096 px.
    private static let maxEnvironmentFileBytes: Int64 = 3_000_000_000
    @ObservationIgnored private var lastHeadWorld: SIMD3<Float>? = nil
    /// Mirror of `phase == .ready` for the per-frame update (not observed).
    @ObservationIgnored private var frameReady = false

    init(hands: HandTrackingService) {
        let rootEntity = Entity()
        rootEntity.name = "RenderedRoot"
        let worldEntity = Entity()
        worldEntity.name = "RenderedWorldRoot"
        let placementEntity = Entity()
        placementEntity.name = "RenderedPlacement"
        rootEntity.addChild(worldEntity)
        worldEntity.addChild(placementEntity)
        let flyController = FlyController(hands: hands)

        let stored = UserDefaults.standard.object(forKey: Self.speedKey) as? Double
        let initial = Self.clampSpeed(Float(stored ?? 1))
        flyController.speed = initial

        self.hands = hands
        self.root = rootEntity
        self.worldRoot = worldEntity
        self.placement = placementEntity
        self.fly = flyController
        self.speed = initial
    }

    // MARK: - Load / release

    /// Starts loading `scene` (releases whatever was loaded before).
    func begin(_ scene: RenderedScene) {
        // A load that is still inside RealityKit can't be cancelled; wait for it to finish (it
        // is dropped right away) so two scenes are never in memory at once.
        let previous = loadTask
        release()
        self.scene = scene
        loadToken += 1
        let token = loadToken
        phase = .loading("Opening “\(scene.title)” (\(RenderedFiles.byteText(scene.sizeBytes)))…", nil)
        loadTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, token == self.loadToken else { return }
            await self.load(scene, token: token)
        }
    }

    /// Removes the scene and the sky, stops fly mode, cancels a running load. After this
    /// nothing of the scene is referenced, so RealityKit frees its meshes and textures.
    func release() {
        if frameReady { saveLastPose(force: true) }
        loadToken += 1
        loadTask?.cancel()
        // `loadTask` is kept: `begin` waits for it before loading the next scene.
        fadeTask?.cancel()
        fadeTask = nil
        clearFade()
        frameReady = false
        fly.isEnabled = false
        fly.resetOffset(worldRoot: worldRoot)
        content?.removeFromParent()
        content = nil
        sky?.removeFromParent()
        sky = nil
        placement.transform = .identity
        needsPosePlacement = false
        sceneSize = nil
        hasOwnSky = false
        shadingSummary = nil
        viewpoints = []
        resumedLastPosition = false
        currentTarget = nil
        lastSavedPose = nil
        sceneBounds = nil
        isEnvironment = false
        environmentGroup = nil
        isOutsideViewingArea = false
        viewingCenter = nil
        areaOpacity = 1
        worldRoot.components.remove(OpacityComponent.self)
        scene = nil
        phase = .idle
        // The sky texture (shared cache) goes too: nothing of the scene stays in memory.
        EnvironmentBuilder.purgeCaches()
    }

    private func load(_ scene: RenderedScene, token: Int) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scene.usdzURL.path) else {
            fail("The scene file is missing. Delete “\(scene.title)” and download it again.", token: token)
            return
        }
        let fileBytes = RenderedFiles.fileSize(scene.usdzURL) ?? scene.sizeBytes
        let limit = scene.environment != nil ? Self.maxEnvironmentFileBytes : Self.maxFileBytes
        if fileBytes > limit {
            fail("“\(scene.title)” is \(RenderedFiles.byteText(fileBytes)): too big for the headset. Re-bake it within the budget (USDZ up to about 500 MB, at most eight 4096 px atlases).", token: token)
            return
        }

        let sidecarURL = scene.sidecarURL
        let sidecar: RenderedSidecar? = await Task.detached(priority: .userInitiated) {
            sidecarURL.flatMap(RenderedFiles.loadSidecar)
        }.value
        guard token == loadToken else { return }

        phase = .loading("Loading “\(scene.title)” (\(RenderedFiles.byteText(fileBytes)))…", nil)
        let loaded: Entity
        do {
            loaded = try await Entity(contentsOf: scene.usdzURL)
        } catch {
            var message = "“\(scene.title)” couldn't be opened: \(error.localizedDescription)"
            if fileBytes > Self.budgetFileBytes {
                message += " It is \(RenderedFiles.byteText(fileBytes)), above the ~500 MB budget: it may not fit in memory. Re-bake with smaller or fewer atlases."
            } else {
                message += " The file may be damaged or not a USDZ."
            }
            fail(message, token: token)
            return
        }
        guard token == loadToken else { return }

        // Materials -> unlit, lights and shadows off (yields so the UI stays responsive).
        phase = .loading("Preparing “\(scene.title)”…", 0)
        let foundSkyByName = await prepare(loaded, token: token)
        guard token == loadToken else { return }

        // Bounds in placement space: the loaded entity has no parent yet, so "world" = its parent space.
        let bounds = loaded.visualBounds(relativeTo: nil)
        guard !bounds.isEmpty, Self.isFinite(bounds.extents) else {
            fail("“\(scene.title)” contains no visible geometry.", token: token)
            return
        }
        sceneSize = bounds.extents
        sceneBounds = bounds

        // Start point + yaw (sidecar in USDZ coordinates -> placement space via the root transform).
        let rootMatrix = loaded.transform.matrix
        let environmentMode = sidecar?.isEnvironment ?? false
        if environmentMode, let center = sidecar?.viewingAreaCenter {
            let c = rootMatrix * SIMD4<Float>(center.x, center.y, center.z, 1)
            viewingCenter = SIMD3<Float>(c.x, c.y, c.z)
        } else {
            viewingCenter = nil
        }
        viewingRadius = sidecar?.viewingAreaRadius ?? 1.5
        if let start = sidecar?.startPosition ?? (environmentMode ? sidecar?.viewingAreaCenter : nil) {
            let p = rootMatrix * SIMD4<Float>(start.x, start.y, start.z, 1)
            startPoint = SIMD3<Float>(p.x, p.y, p.z)
            let yaw = (sidecar?.startYawDegrees ?? 0) * .pi / 180
            let forwardLocal = SIMD4<Float>(-sin(yaw), 0, -cos(yaw), 0)
            let f = rootMatrix * forwardLocal
            let flat = SIMD2<Float>(f.x, f.z)
            startYaw = simd_length(flat) > 1e-5 ? atan2(-f.x, -f.z) : yaw
            startAtEyeHeight = sidecar?.eyeHeightIncluded ?? false
        } else {
            // No sidecar: bounds centre at floor level, looking along -Z.
            startPoint = SIMD3<Float>(bounds.center.x, bounds.min.y, bounds.center.z)
            startYaw = 0
            startAtEyeHeight = false
        }

        // Sky: the sidecar decides; otherwise a "sky" object or a huge enclosing sphere counts.
        let maxExtent = Swift.max(bounds.extents.x, Swift.max(bounds.extents.y, bounds.extents.z))
        hasOwnSky = sidecar?.hasSky ?? (foundSkyByName || maxExtent > Self.skyGeometryExtent)
        if !hasOwnSky {
            let dome = await EnvironmentBuilder.makeSkyOnly(.daylight)
            guard token == loadToken else { return }
            dome.name = "RenderedSky"
            skyBaseScale = dome.scale
            let radius = Swift.min(Self.maxSkyRadius, Swift.max(Self.minSkyRadius, maxExtent * Self.skyExtentFactor))
            var baseRadius = EnvironmentBuilder.skyRadius
            if let meshBounds = dome.components[ModelComponent.self]?.mesh.bounds, !meshBounds.isEmpty {
                let e = meshBounds.extents
                let r = 0.5 * Swift.max(e.x, Swift.max(e.y, e.z))
                if r.isFinite, r > 1 { baseRadius = r }
            }
            skyScaleFactor = radius / baseRadius
            dome.scale = skyBaseScale * skyScaleFactor
            worldRoot.addChild(dome)
            sky = dome
        }

        // Viewpoints (D2): Start first, then the sidecar's named places (classic scenes only:
        // an Environment is seen from its viewing area).
        var places = [Viewpoint(id: 0, name: "Start", point: startPoint, yaw: startYaw, atEyeHeight: startAtEyeHeight)]
        for (index, viewpoint) in (environmentMode ? [] : (sidecar?.usableViewpoints ?? [])).enumerated() {
            let p = rootMatrix * SIMD4<Float>(viewpoint.position.x, viewpoint.position.y, viewpoint.position.z, 1)
            let yaw = viewpoint.yawDegrees * .pi / 180
            let f = rootMatrix * SIMD4<Float>(-sin(yaw), 0, -cos(yaw), 0)
            let mappedYaw = simd_length(SIMD2<Float>(f.x, f.z)) > 1e-5 ? atan2(-f.x, -f.z) : yaw
            let point = SIMD3<Float>(p.x, p.y, p.z)
            guard Self.isFinite(point) else { continue }
            places.append(Viewpoint(id: index + 1, name: viewpoint.name, point: point, yaw: mappedYaw,
                                    atEyeHeight: startAtEyeHeight))
        }
        viewpoints = places

        // B3: come back where the user was last time, if that is somewhere else than Start.
        var initial = places[0]
        resumedLastPosition = false
        if !environmentMode, let last = Self.loadLastPose(sceneID: scene.id, bounds: bounds, atEyeHeight: startAtEyeHeight),
           simd_distance(last.point, startPoint) > 0.5 {
            initial = last
            resumedLastPosition = true
        }

        isEnvironment = environmentMode
        environmentGroup = environmentMode ? (sidecar?.groupName ?? "Environments") : nil

        let fadeIn = fadeInWhenReady
        fadeInWhenReady = false
        if fadeIn {
            fadeOpacity = 0
            root.components.set(OpacityComponent(opacity: 0))
        }

        content = loaded
        place(initial, devicePose: hands.devicePose())
        placement.addChild(loaded)
        updateSky()

        fly.speed = speed
        // E3: no fist-fly in an Environment: you look around and walk.
        fly.isEnabled = !environmentMode
        frameReady = true
        phase = .ready

        if fadeIn {
            fadeTask?.cancel()
            fadeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.fade(to: 1, seconds: 0.35)
                guard !Task.isCancelled else { return }
                self.clearFade()
                self.isSwitchingRoom = false
            }
        } else {
            isSwitchingRoom = false
        }
    }

    /// E3: another room of the same group. Fade out, unload this one, load the next, fade in.
    func switchRoom(to next: RenderedScene) {
        guard scene?.id != next.id else { return }
        switchTask?.cancel()
        isSwitchingRoom = true
        switchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.frameReady {
                self.fadeTask?.cancel()
                self.fadeTask = nil
                await self.fade(to: 0, seconds: 0.3)
            }
            guard !Task.isCancelled else { return }
            self.begin(next)
            self.fadeInWhenReady = true
            self.isSwitchingRoom = true
        }
    }

    private func fail(_ message: String, token: Int) {
        guard token == loadToken else { return }
        frameReady = false
        fadeInWhenReady = false
        isSwitchingRoom = false
        clearFade()
        phase = .failed(message)
    }

    // MARK: - Controls

    /// Back to the start position (with the short fade).
    func resetToStart() {
        guard let start = viewpoints.first else { return }
        go(to: start)
    }

    /// Moves the user to `viewpoint`: fade out, re-place the scene so that point is under the
    /// feet (wherever the user physically stands now), fade in. No sliding motion (comfort).
    func go(to viewpoint: Viewpoint) {
        guard content != nil, frameReady else { return }
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fade(to: 0, seconds: 0.16)
            guard !Task.isCancelled, self.frameReady else { return }
            self.fly.resetOffset(worldRoot: self.worldRoot)
            self.place(viewpoint, devicePose: self.hands.devicePose())
            self.updateSky()
            self.resumedLastPosition = false
            await self.fade(to: 1, seconds: 0.22)
            guard !Task.isCancelled else { return }
            self.clearFade()
        }
    }

    func changeSpeed(by delta: Float) {
        speed = Self.clampSpeed((speed + delta).rounded())
    }

    private func fade(to target: Float, seconds: Double) async {
        let steps = 8
        let from = fadeOpacity
        for step in 1...steps {
            if Task.isCancelled { return }
            fadeOpacity = from + (target - from) * Float(step) / Float(steps)
            root.components.set(OpacityComponent(opacity: fadeOpacity))
            try? await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1_000_000_000))
        }
    }

    private func clearFade() {
        fadeOpacity = 1
        root.components.remove(OpacityComponent.self)
    }

    // MARK: - Last position (B3)

    private static func lastPoseKey(_ sceneID: String) -> String {
        "rendered.lastPose." + sceneID
    }

    static func forgetLastPose(sceneID: String) {
        UserDefaults.standard.removeObject(forKey: lastPoseKey(sceneID))
    }

    private static func loadLastPose(sceneID: String, bounds: BoundingBox, atEyeHeight: Bool) -> Viewpoint? {
        guard let values = UserDefaults.standard.array(forKey: lastPoseKey(sceneID)) as? [Double], values.count == 4 else { return nil }
        let point = SIMD3<Float>(Float(values[0]), Float(values[1]), Float(values[2]))
        let yaw = Float(values[3])
        guard isFinite(point), yaw.isFinite else { return nil }
        // Ignore a position far outside the scene (the file may have been replaced).
        let margin = SIMD3<Float>(repeating: 60)
        let low = bounds.min - margin
        let high = bounds.max + margin
        guard point.x >= low.x, point.y >= low.y, point.z >= low.z,
              point.x <= high.x, point.y <= high.y, point.z <= high.z else { return nil }
        return Viewpoint(id: -1, name: "Last position", point: point, yaw: yaw, atEyeHeight: atEyeHeight)
    }

    /// E3: fades the scene (worldRoot) while the user stands more than `outsideMargin` beyond the
    /// viewing area, and raises `isOutsideViewingArea` for the "Step back to the centre" hint.
    private func updateViewingArea(deltaTime: Float) {
        guard let center = viewingCenter, let headWorld = lastHeadWorld else { return }
        let head = placement.convert(position: headWorld, from: nil)
        guard Self.isFinite(head) else { return }
        let distance = simd_length(SIMD2<Float>(head.x - center.x, head.z - center.z))
        let excess = distance - viewingRadius - Self.outsideMargin
        let target: Float = excess <= 0 ? 1 : Swift.max(Self.minAreaOpacity, 1 - excess / Self.fadeDistance * (1 - Self.minAreaOpacity))
        // Slow, smooth change (about half a second).
        let blend = Swift.min(1, Swift.max(deltaTime, 0) * 2.5)
        areaOpacity += (target - areaOpacity) * blend
        if areaOpacity > 0.995 {
            if worldRoot.components.has(OpacityComponent.self) {
                areaOpacity = 1
                worldRoot.components.remove(OpacityComponent.self)
            }
        } else {
            worldRoot.components.set(OpacityComponent(opacity: areaOpacity))
        }
        let outside = excess > 0
        if outside != isOutsideViewingArea { isOutsideViewingArea = outside }
    }

    /// Stores where the user stands in the scene (placement space) and where they look.
    private func saveLastPose(force: Bool) {
        guard let scene, content != nil, !isEnvironment, let pose = hands.devicePose() else { return }
        let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let forward = -SIMD3<Float>(pose.columns.2.x, 0, pose.columns.2.z)
        guard Self.isFinite(head), simd_length(forward) > 0.05 else { return }
        let standing = SIMD3<Float>(head.x, startAtEyeHeight ? head.y : 0, head.z)
        let point = placement.convert(position: standing, from: nil)
        let direction = placement.convert(direction: forward, from: nil)
        guard Self.isFinite(point), simd_length(SIMD2<Float>(direction.x, direction.z)) > 1e-4 else { return }
        let yaw = atan2(-direction.x, -direction.z)
        let value = SIMD4<Float>(point.x, point.y, point.z, yaw)
        if !force, let last = lastSavedPose, simd_distance(last, value) < 0.15 { return }
        lastSavedPose = value
        UserDefaults.standard.set([Double(point.x), Double(point.y), Double(point.z), Double(yaw)],
                                  forKey: Self.lastPoseKey(scene.id))
    }

    // MARK: - Per frame

    /// Called every frame by RenderedImmersiveView.
    func updateFrame(deltaTime: Float, devicePose: simd_float4x4?) {
        guard frameReady else { return }
        if let pose = devicePose {
            let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            if Self.isFinite(head) { lastHeadWorld = head }
            if needsPosePlacement && !fly.isFlying, let target = currentTarget {
                needsPosePlacement = false
                fly.resetOffset(worldRoot: worldRoot)
                place(target, devicePose: pose)
            }
        }
        if isEnvironment {
            updateViewingArea(deltaTime: deltaTime)
        } else {
            fly.update(deltaTime: deltaTime, worldRoot: worldRoot)
        }
        updateSky()

        // Remember where the user is every couple of seconds (survives a crash or a force quit).
        poseSaveClock += deltaTime
        if poseSaveClock > 2, !fly.isFlying, fadeTask == nil || fadeOpacity >= 1 {
            poseSaveClock = 0
            saveLastPose(force: false)
        }
    }

    // MARK: - Private

    /// placement = T(target) · R_y(headYaw − yaw) · T(−point), with worldRoot at identity.
    private func place(_ viewpoint: Viewpoint, devicePose: simd_float4x4?) {
        currentTarget = viewpoint
        var target = SIMD3<Float>(0, 0, 0)
        var headYaw: Float = 0
        if let pose = devicePose {
            let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            let forward = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
            if Self.isFinite(head) {
                // The ImmersiveSpace origin is on the floor: feet = head projected to y = 0.
                target = SIMD3<Float>(head.x, viewpoint.atEyeHeight ? head.y : 0, head.z)
            }
            if simd_length(SIMD2<Float>(forward.x, forward.z)) > 0.05 {
                headYaw = atan2(-forward.x, -forward.z)
            }
            needsPosePlacement = false
        } else {
            target = SIMD3<Float>(0, viewpoint.atEyeHeight ? 1.6 : 0, 0)
            needsPosePlacement = true
        }
        let rotation = simd_quatf(angle: headYaw - viewpoint.yaw, axis: SIMD3<Float>(0, 1, 0))
        placement.transform = Transform(
            scale: SIMD3<Float>(1, 1, 1),
            rotation: rotation,
            translation: target - rotation.act(viewpoint.point)
        )
    }

    /// The dome stays centred on the head (translation only, in worldRoot space).
    private func updateSky() {
        guard let sky else { return }
        let headWorld = lastHeadWorld ?? SIMD3<Float>(0, 1.6, 0)
        let head = worldRoot.convert(position: headWorld, from: nil)
        guard Self.isFinite(head) else { return }
        sky.position = head
    }

    /// Converts every material to unlit and strips lights / shadows / IBL receivers.
    /// Returns true if an entity is named like a sky.
    private func prepare(_ root: Entity, token: Int) async -> Bool {
        var all: [Entity] = []
        var stack: [Entity] = [root]
        while let entity = stack.popLast() {
            all.append(entity)
            stack.append(contentsOf: entity.children)
        }

        var foundSky = false
        var graphMaterials = 0
        var bakedMaterials = 0
        let total = all.count
        for (index, entity) in all.enumerated() {
            if !foundSky {
                let name = entity.name.lowercased()
                if name.contains("sky") || name.contains("skydome") || name.contains("environment_sphere") {
                    foundSky = true
                }
            }
            if var model = entity.components[ModelComponent.self] {
                for material in model.materials {
                    if material is ShaderGraphMaterial { graphMaterials += 1 } else { bakedMaterials += 1 }
                }
                model.materials = model.materials.map(Self.unlit)
                entity.components.set(model)
            }
            entity.components.remove(GroundingShadowComponent.self)
            entity.components.remove(ImageBasedLightComponent.self)
            entity.components.remove(ImageBasedLightReceiverComponent.self)
            entity.components.remove(DirectionalLightComponent.self)
            entity.components.remove(PointLightComponent.self)
            entity.components.remove(SpotLightComponent.self)

            if index % 150 == 149 {
                phase = .loading(phaseMessage, Double(index + 1) / Double(max(total, 1)))
                await Task.yield()
                guard token == loadToken else { return foundSky }
            }
        }
        if graphMaterials > 0 {
            shadingSummary = "HD shading: \(graphMaterials) shader-graph material\(graphMaterials == 1 ? "" : "s") · \(bakedMaterials) baked"
        } else {
            shadingSummary = "Baked shading (\(bakedMaterials) material\(bakedMaterials == 1 ? "" : "s"))"
        }
        return foundSky
    }

    private var phaseMessage: String {
        "Preparing “\(scene?.title ?? "scene")”…"
    }

    /// Baked look: base colour texture × tint, opacity kept, no lighting, no tone mapping.
    private static func unlit(_ material: any Material) -> any Material {
        if let pbr = material as? PhysicallyBasedMaterial {
            var result = UnlitMaterial(applyPostProcessToneMap: false)
            result.color = .init(tint: pbr.baseColor.tint, texture: pbr.baseColor.texture)
            result.faceCulling = pbr.faceCulling
            result.opacityThreshold = pbr.opacityThreshold
            if case .transparent(let opacity) = pbr.blending,
               opacity.scale < 0.999 || opacity.texture != nil {
                result.blending = .transparent(opacity: .init(scale: opacity.scale, texture: opacity.texture))
            }
            return result
        }
        if let unlitMaterial = material as? UnlitMaterial {
            // Already unlit (e.g. exported as such): keep its colour and blending, drop tone mapping.
            var result = UnlitMaterial(applyPostProcessToneMap: false)
            result.color = unlitMaterial.color
            result.blending = unlitMaterial.blending
            result.faceCulling = unlitMaterial.faceCulling
            result.opacityThreshold = unlitMaterial.opacityThreshold
            return result
        }
        // ShaderGraph / other materials: left as they are (they still render).
        return material
    }

    private static func clampSpeed(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return Swift.min(Swift.max(value, speedRange.lowerBound), speedRange.upperBound)
    }

    private static func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}
