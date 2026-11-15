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
        release()
        self.scene = scene
        loadToken += 1
        let token = loadToken
        phase = .loading("Opening “\(scene.title)” (\(RenderedFiles.byteText(scene.sizeBytes)))…", nil)
        loadTask = Task { @MainActor [weak self] in
            await self?.load(scene, token: token)
        }
    }

    /// Removes the scene and the sky, stops fly mode, cancels a running load. After this
    /// nothing of the scene is referenced, so RealityKit frees its meshes and textures.
    func release() {
        loadToken += 1
        loadTask?.cancel()
        loadTask = nil
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
        scene = nil
        phase = .idle
    }

    private func load(_ scene: RenderedScene, token: Int) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scene.usdzURL.path) else {
            fail("The scene file is missing. Delete “\(scene.title)” and download it again.", token: token)
            return
        }
        let fileBytes = RenderedFiles.fileSize(scene.usdzURL) ?? scene.sizeBytes
        if fileBytes > Self.maxFileBytes {
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

        // Start point + yaw (sidecar in USDZ coordinates -> placement space via the root transform).
        let rootMatrix = loaded.transform.matrix
        if let start = sidecar?.startPosition {
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

        content = loaded
        placeAtStart(devicePose: hands.devicePose())
        placement.addChild(loaded)
        updateSky()

        fly.speed = speed
        fly.isEnabled = true
        frameReady = true
        phase = .ready
    }

    private func fail(_ message: String, token: Int) {
        guard token == loadToken else { return }
        frameReady = false
        phase = .failed(message)
    }

    // MARK: - Controls

    /// Back to the start position: fly offset cleared, start point under the feet again (wherever
    /// the user physically stands now), facing the start direction.
    func resetToStart() {
        guard content != nil else { return }
        fly.resetOffset(worldRoot: worldRoot)
        placeAtStart(devicePose: hands.devicePose())
        updateSky()
    }

    func changeSpeed(by delta: Float) {
        speed = Self.clampSpeed((speed + delta).rounded())
    }

    // MARK: - Per frame

    /// Called every frame by RenderedImmersiveView.
    func updateFrame(deltaTime: Float, devicePose: simd_float4x4?) {
        guard frameReady else { return }
        if let pose = devicePose {
            let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            if Self.isFinite(head) { lastHeadWorld = head }
            if needsPosePlacement && !fly.isFlying {
                needsPosePlacement = false
                fly.resetOffset(worldRoot: worldRoot)
                placeAtStart(devicePose: pose)
            }
        }
        fly.update(deltaTime: deltaTime, worldRoot: worldRoot)
        updateSky()
    }

    // MARK: - Private

    /// placement = T(target) · R_y(headYaw − startYaw) · T(−startPoint), with worldRoot at identity.
    private func placeAtStart(devicePose: simd_float4x4?) {
        var target = SIMD3<Float>(0, 0, 0)
        var headYaw: Float = 0
        if let pose = devicePose {
            let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            let forward = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
            if Self.isFinite(head) {
                // The ImmersiveSpace origin is on the floor: feet = head projected to y = 0.
                target = SIMD3<Float>(head.x, startAtEyeHeight ? head.y : 0, head.z)
            }
            if simd_length(SIMD2<Float>(forward.x, forward.z)) > 0.05 {
                headYaw = atan2(-forward.x, -forward.z)
            }
            needsPosePlacement = false
        } else {
            target = SIMD3<Float>(0, startAtEyeHeight ? 1.6 : 0, 0)
            needsPosePlacement = true
        }
        let rotation = simd_quatf(angle: headYaw - startYaw, axis: SIMD3<Float>(0, 1, 0))
        placement.transform = Transform(
            scale: SIMD3<Float>(1, 1, 1),
            rotation: rotation,
            translation: target - rotation.act(startPoint)
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
