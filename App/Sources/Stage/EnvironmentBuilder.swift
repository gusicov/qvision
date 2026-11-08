import Foundation
import CoreGraphics
import ImageIO
import Metal
import RealityKit
import UIKit
import simd

/// Builds the environment shown in Immersive (`.full`) mode.
///
/// Primary path ("baked"): textures generated offline by `tools/make_environments.py`
/// (bundled from `App/Resources/Environments/`):
/// - an equirectangular sky on an inward-facing dome (radius 450 m),
/// - a PBR near floor (albedo + normal + roughness, one 4 m tile = 4 x 4 slabs of 1 m),
/// - a far ground disc that fades into the sky haze through a radial opacity texture,
/// - image-based lighting made from the same sky image,
/// - a directional sun / moon with shadows, aligned with the sun painted in the sky.
///
/// Fallback path ("procedural"): the previous gradient sky + grid floor, used when any
/// bundled resource is missing or fails to load, so the app never shows nothing.
enum EnvironmentBuilder {
    /// Name of the child entity that carries the `ImageBasedLightComponent`.
    /// StageController looks it up to point `ImageBasedLightReceiverComponent` at it.
    static let imageBasedLightName = "QVEnvironmentIBL"

    @MainActor static func make(_ preset: EnvironmentPreset) async -> Entity {
        let look = Look.forPreset(preset)
        if let baked = await makeBaked(preset, look: look) {
            return baked
        }
        return await makeProcedural(preset, look: look)
    }

    // MARK: - Look (baked resources + lighting per preset)

    private struct FloorTextures {
        var albedo: String
        var normal: String
        var roughness: String
    }

    private struct Look {
        /// Sky image (jpg). The sun / moon is painted at the image centre (u = 0.5).
        var sky: String
        var floor: FloorTextures
        /// Mean albedo of the floor texture (sRGB, printed by the generator) - the far ground
        /// uses it so the end of the textured floor is invisible.
        var farGroundColor: UIColor
        var farGroundRoughness: Float

        /// Sun azimuth in the world: 0 = straight ahead (-Z), +90 = to the right (+X).
        var sunAzimuthDegrees: Float
        /// Elevation of the light. Usually the painted sun's elevation; the sunset light sits a
        /// few degrees higher than the painted disc so shadows stay a usable length.
        var lightElevationDegrees: Float
        var lightColor: UIColor
        var lightIntensity: Float
        var iblIntensityExponent: Float

        /// World direction from the origin towards the sun.
        var sunDirection: SIMD3<Float> {
            let azimuth = sunAzimuthDegrees * .pi / 180
            let elevation = lightElevationDegrees * .pi / 180
            return SIMD3<Float>(
                sin(azimuth) * cos(elevation),
                sin(elevation),
                -cos(azimuth) * cos(elevation)
            )
        }

        /// Yaw of the sky dome (and IBL) that puts the image centre (painted sun) at `sunAzimuthDegrees`.
        /// A rotation of b about +Y moves azimuth a to a - b, so b = -azimuth.
        var skyYaw: simd_quatf {
            simd_quatf(angle: -sunAzimuthDegrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        }

        static func forPreset(_ preset: EnvironmentPreset) -> Look {
            let pavers = FloorTextures(
                albedo: "qv_env_pavers_albedo",
                normal: "qv_env_pavers_normal",
                roughness: "qv_env_pavers_roughness"
            )
            switch preset {
            case .studio:
                return Look(
                    sky: "qv_env_sky_studio",
                    floor: FloorTextures(
                        albedo: "qv_env_epoxy_albedo",
                        normal: "qv_env_epoxy_normal",
                        roughness: "qv_env_epoxy_roughness"
                    ),
                    farGroundColor: srgbColor(0.70, 0.70, 0.705),
                    farGroundRoughness: 0.58,
                    // Key light from behind-right, high, like a studio softbox.
                    sunAzimuthDegrees: 143,
                    lightElevationDegrees: 55,
                    lightColor: srgbColor(1.0, 1.0, 1.0),
                    lightIntensity: 1800,
                    iblIntensityExponent: 0.35
                )
            case .daylight:
                return Look(
                    sky: "qv_env_sky_daylight",
                    floor: pavers,
                    farGroundColor: srgbColor(0.637, 0.617, 0.576),
                    farGroundRoughness: 0.42,
                    // Sun to the right and slightly behind at 45 deg: form-revealing side light.
                    sunAzimuthDegrees: 120,
                    lightElevationDegrees: 45,
                    lightColor: srgbColor(1.0, 0.97, 0.92),
                    lightIntensity: 3000,
                    iblIntensityExponent: 0.6
                )
            case .sunset:
                return Look(
                    sky: "qv_env_sky_sunset",
                    floor: pavers,
                    farGroundColor: srgbColor(0.637, 0.617, 0.576),
                    farGroundRoughness: 0.42,
                    // Low sun ahead of the user, slightly left (painted at 5 deg, light at 9 deg).
                    sunAzimuthDegrees: -15,
                    lightElevationDegrees: 9,
                    lightColor: srgbColor(1.0, 0.68, 0.42),
                    lightIntensity: 1600,
                    iblIntensityExponent: 0.25
                )
            case .night:
                return Look(
                    sky: "qv_env_sky_night",
                    floor: FloorTextures(
                        albedo: "qv_env_pavers_wet_albedo",
                        normal: "qv_env_pavers_normal",
                        roughness: "qv_env_pavers_wet_roughness"
                    ),
                    farGroundColor: srgbColor(0.485, 0.479, 0.475),
                    farGroundRoughness: 0.24,
                    // Moon front-left at 32 deg.
                    sunAzimuthDegrees: -35,
                    lightElevationDegrees: 32,
                    lightColor: srgbColor(0.62, 0.72, 1.0),
                    lightIntensity: 400,
                    iblIntensityExponent: -0.25
                )
            }
        }
    }

    // MARK: - Geometry constants

    private static let skyRadius: Float = 450
    private static let nearFloorSize: Float = 120  // +-60 m
    private static let floorTileMeters: Float = 4  // one 2048 px texture tile
    private static let farGroundRadius: Float = 440

    // MARK: - Caches (main actor)

    @MainActor private static var textureCache: [String: TextureResource] = [:]
    @MainActor private static var environmentCache: [EnvironmentPreset: EnvironmentResource] = [:]
    @MainActor private static var skyMeshCache: MeshResource?

    // MARK: - Baked build

    @MainActor private static func makeBaked(_ preset: EnvironmentPreset, look: Look) async -> Entity? {
        // Required resources: without any of these, use the procedural environment instead.
        guard
            let sky = await loadTexture(look.sky, ext: "jpg", semantic: .color),
            let albedo = await loadTexture(look.floor.albedo, ext: "jpg", semantic: .color),
            let normal = await loadTexture(look.floor.normal, ext: "png", semantic: .normal),
            let roughness = await loadTexture(look.floor.roughness, ext: "png", semantic: .raw)
        else {
            return nil
        }
        // Optional: without it the far ground is opaque (its edge is ~0.2 deg below the horizon).
        let fade = await loadTexture("qv_env_ground_fade", ext: "png", semantic: .raw)

        let root = Entity()
        root.name = "Environment-\(preset.rawValue)"
        root.addChild(makeBakedSky(sky, look: look))
        root.addChild(makeNearFloor(albedo: albedo, normal: normal, roughness: roughness))
        root.addChild(makeFarGround(look: look, fade: fade))

        if let ibl = await makeBakedImageBasedLight(preset, look: look) {
            root.addChild(ibl)
        } else if let ibl = await makeImageBasedLight(Palette.forPreset(preset, look: look)) {
            root.addChild(ibl)
        }
        if let sun = makeSun(direction: look.sunDirection, color: look.lightColor, intensity: look.lightIntensity) {
            root.addChild(sun)
        }
        return root
    }

    @MainActor private static func makeBakedSky(_ texture: TextureResource, look: Look) -> Entity {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture, sampler: skySampler()))

        let sky: ModelEntity
        if let mesh = skyDomeMesh() {
            sky = ModelEntity(mesh: mesh, materials: [material])
        } else {
            // Fallback: RealityKit's sphere (lower tessellation, assumed same u/v layout).
            sky = ModelEntity(mesh: MeshResource.generateSphere(radius: skyRadius), materials: [material])
        }
        sky.name = "SkyDome"
        // Mirror on X so the outward-facing triangles are seen from the inside, like the
        // classic generateSphere + scale [-1, 1, 1] panorama setup. The dome mesh below is built
        // so that, after this mirror, u = 0.5 points at -Z and u increases to the right.
        sky.scale = [-1, 1, 1]
        sky.orientation = look.skyYaw
        return sky
    }

    /// Sky texture is magnified everywhere (4096 px / 360 deg is below the display density), so no
    /// mipmaps: this also avoids the blurry "pinch" equirect maps get at the zenith with mip selection.
    private static func skySampler() -> MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .clampToEdge
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        return MaterialParameters.Texture.Sampler(descriptor)
    }

    @MainActor private static func makeNearFloor(
        albedo: TextureResource,
        normal: TextureResource,
        roughness: TextureResource
    ) -> Entity {
        let sampler = repeatingSampler()
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(albedo, sampler: sampler))
        material.normal = .init(texture: .init(normal, sampler: sampler))
        material.roughness = .init(scale: 1.0, texture: .init(roughness, sampler: sampler))
        material.metallic = .init(floatLiteral: 0.0)
        let repeats = nearFloorSize / floorTileMeters
        material.textureCoordinateTransform.scale = [repeats, repeats]

        let floor = ModelEntity(
            mesh: MeshResource.generatePlane(width: nearFloorSize, depth: nearFloorSize),
            materials: [material]
        )
        floor.name = "Ground"
        floor.position = [0, 0, 0]
        return floor
    }

    /// Large lit disc under the near floor in the floor's mean colour, dissolving into the sky
    /// towards its rim (radial opacity texture on a square plane = a soft-edged disc).
    @MainActor private static func makeFarGround(look: Look, fade: TextureResource?) -> Entity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: look.farGroundColor)
        material.roughness = .init(floatLiteral: look.farGroundRoughness)
        material.metallic = .init(floatLiteral: 0.0)
        if let fade {
            material.blending = .transparent(opacity: .init(scale: 1.0, texture: .init(fade)))
        }
        let size = farGroundRadius * 2
        let ground = ModelEntity(mesh: MeshResource.generatePlane(width: size, depth: size), materials: [material])
        ground.name = "FarGround"
        ground.position = [0, -0.01, 0]
        return ground
    }

    @MainActor private static func makeBakedImageBasedLight(_ preset: EnvironmentPreset, look: Look) async -> Entity? {
        if #available(visionOS 2.0, *) {
            let resource: EnvironmentResource
            if let cached = environmentCache[preset] {
                resource = cached
            } else {
                // The same sky image, decoded at 1024 x 512 off the main thread: plenty for IBL.
                guard let image = await decodeImage(named: look.sky, ext: "jpg", maxPixelSize: 1024) else { return nil }
                do {
                    let created = try await EnvironmentResource(equirectangular: image)
                    environmentCache[preset] = created
                    resource = created
                } catch {
                    return nil
                }
            }
            let entity = Entity()
            entity.name = imageBasedLightName
            // Assumes the equirect centre faces -Z like the dome; yaw it the same way so the
            // bright sky region lines up with the directional light.
            entity.orientation = look.skyYaw
            entity.components.set(
                ImageBasedLightComponent(source: .single(resource), intensityExponent: look.iblIntensityExponent)
            )
            return entity
        }
        return nil
    }

    // MARK: - Sky dome mesh

    /// How RealityKit's own `generateSphere` lays out its texture coordinates and winding.
    /// Read from a probe sphere at runtime so the custom dome matches it exactly.
    private struct SphereConvention {
        /// true when the top (+Y) of the sphere has v = 0.
        var topIsVZero: Bool
        /// true when triangles are counter-clockwise seen from outside (right-hand normal outward).
        var outwardCCW: Bool
    }

    @MainActor private static func sphereConvention() -> SphereConvention? {
        let probe = MeshResource.generateSphere(radius: 1)
        for model in probe.contents.models {
            for part in model.parts {
                let positions = part.positions.elements
                guard
                    let uvs = part.textureCoordinates?.elements,
                    let indices = part.triangleIndices?.elements,
                    uvs.count == positions.count,
                    positions.count > 3,
                    indices.count >= 3
                else { continue }

                var top = 0
                for i in positions.indices where positions[i].y > positions[top].y {
                    top = i
                }
                var score: Float = 0
                var t = 0
                while t + 2 < indices.count {
                    let a = positions[Int(indices[t])]
                    let b = positions[Int(indices[t + 1])]
                    let c = positions[Int(indices[t + 2])]
                    score += simd_dot(simd_cross(b - a, c - a), a + b + c)
                    t += 3
                }
                guard score != 0 else { continue }
                return SphereConvention(topIsVZero: uvs[top].y < 0.5, outwardCCW: score > 0)
            }
        }
        return nil
    }

    /// Finely tessellated UV sphere (128 x 64) with an explicit equirect mapping:
    /// after the entity's [-1, 1, 1] mirror, u = 0.5 looks at -Z, u grows towards +X,
    /// and the top image row is the zenith. Tiny polar caps (2.8 deg) keep zenith distortion invisible.
    @MainActor private static func skyDomeMesh() -> MeshResource? {
        if let cached = skyMeshCache { return cached }
        guard let convention = sphereConvention() else { return nil }

        let lonSegments = 128
        let latSegments = 64
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity((lonSegments + 1) * (latSegments + 1))
        normals.reserveCapacity((lonSegments + 1) * (latSegments + 1))
        uvs.reserveCapacity((lonSegments + 1) * (latSegments + 1))

        for j in 0...latSegments {
            let vImage = Float(j) / Float(latSegments)  // 0 = top row of the image
            let elevation = (0.5 - vImage) * .pi
            for i in 0...lonSegments {
                var u = Float(i) / Float(lonSegments)
                // Pole rows: sample the middle of each segment (avoids a twisted fan).
                if j == 0 || j == latSegments {
                    u = min(1, (Float(i) + 0.5) / Float(lonSegments))
                }
                let azimuth = 2 * .pi * u - .pi
                let world = SIMD3<Float>(
                    sin(azimuth) * cos(elevation),
                    sin(elevation),
                    -cos(azimuth) * cos(elevation)
                )
                // Pre-mirror local position: the entity scale [-1, 1, 1] maps it back to `world`.
                let local = SIMD3<Float>(-world.x, world.y, world.z)
                positions.append(local * skyRadius)
                normals.append(local)
                uvs.append(SIMD2<Float>(u, convention.topIsVZero ? vImage : 1 - vImage))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(lonSegments * latSegments * 6)
        let row = lonSegments + 1
        func addTriangle(_ a: Int, _ b: Int, _ c: Int) {
            let pa = positions[a], pb = positions[b], pc = positions[c]
            let n = simd_cross(pb - pa, pc - pa)
            if simd_length_squared(n) < 1e-8 { return }  // degenerate (at a pole)
            let isOutwardCCW = simd_dot(n, pa + pb + pc) > 0
            if isOutwardCCW == convention.outwardCCW {
                indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
            } else {
                indices.append(contentsOf: [UInt32(a), UInt32(c), UInt32(b)])
            }
        }
        for j in 0..<latSegments {
            for i in 0..<lonSegments {
                let a = j * row + i
                let b = (j + 1) * row + i
                let c = (j + 1) * row + i + 1
                let d = j * row + i + 1
                addTriangle(a, b, c)
                addTriangle(a, c, d)
            }
        }

        var descriptor = MeshDescriptor(name: "QVSkyDome")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            skyMeshCache = mesh
            return mesh
        } catch {
            return nil
        }
    }

    // MARK: - Texture loading

    /// Bundle image -> TextureResource. Decoding runs off the main thread; the TextureResource
    /// is created on the main actor and cached by file name (shared between presets).
    @MainActor private static func loadTexture(
        _ name: String,
        ext: String,
        semantic: TextureResource.Semantic
    ) async -> TextureResource? {
        let key = "\(name).\(ext)"
        if let cached = textureCache[key] { return cached }
        guard let image = await decodeImage(named: name, ext: ext, maxPixelSize: nil) else { return nil }
        do {
            let texture = try await TextureResource(image: image, options: .init(semantic: semantic))
            textureCache[key] = texture
            return texture
        } catch {
            return nil
        }
    }

    /// Decodes a bundled image on a background thread. `maxPixelSize` downsamples (longest side).
    private static func decodeImage(named name: String, ext: String, maxPixelSize: Int?) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard
                let url = Bundle.main.url(forResource: name, withExtension: ext),
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else { return nil }
            if let maxPixelSize {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    private static func repeatingSampler() -> MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = 16
        return MaterialParameters.Texture.Sampler(descriptor)
    }

    // MARK: - Sun / moon

    @MainActor private static func makeSun(direction towardsSun: SIMD3<Float>, color: UIColor, intensity: Float) -> Entity? {
        if #available(visionOS 2.0, *) {
            let sun = Entity()
            sun.name = "Sun"
            sun.components.set(DirectionalLightComponent(color: color, intensity: intensity))
            sun.components.set(DirectionalLightComponent.Shadow())
            // A directional light shines along its local -Z axis: travel direction = -towardsSun.
            let travel = simd_normalize(-towardsSun)
            sun.orientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: travel)
            sun.position = [0, 6, 0]
            return sun
        }
        return nil
    }

    // MARK: - Procedural fallback (no bundled assets)

    @MainActor private static func makeProcedural(_ preset: EnvironmentPreset, look: Look) async -> Entity {
        let palette = Palette.forPreset(preset, look: look)

        let root = Entity()
        root.name = "Environment-\(preset.rawValue)"

        root.addChild(await makeSkyDome(palette))
        root.addChild(await makeGround(palette))
        if let ibl = await makeImageBasedLight(palette) {
            root.addChild(ibl)
        }
        if let sun = makeSun(
            direction: -palette.lightDirection,
            color: palette.lightColor,
            intensity: palette.lightIntensity
        ) {
            root.addChild(sun)
        }
        return root
    }

    private struct Palette {
        var zenith: UIColor
        var upperSky: UIColor
        var horizon: UIColor
        var belowHorizon: UIColor
        var nadir: UIColor

        var groundBase: UIColor
        var gridMinor: UIColor
        var gridMajor: UIColor

        var lightColor: UIColor
        var lightIntensity: Float
        /// Direction the light travels (world space, pointing away from the "sun").
        var lightDirection: SIMD3<Float>
        var iblIntensityExponent: Float

        /// Gradient stops from the top of the image (zenith, location 0) to the bottom (nadir, location 1).
        /// The horizon sits at 0.5 so the same image works as an equirectangular map.
        var skyStops: [(UIColor, CGFloat)] {
            [
                (zenith, 0.0),
                (upperSky, 0.28),
                (horizon, 0.5),
                (belowHorizon, 0.53),
                (nadir, 1.0)
            ]
        }

        /// Colours of the procedural look; light direction / colour / intensity follow the baked look
        /// so both paths light the models the same way.
        static func forPreset(_ preset: EnvironmentPreset, look: Look) -> Palette {
            let light = -look.sunDirection
            switch preset {
            case .studio:
                return Palette(
                    zenith: srgbColor(0.30, 0.31, 0.33),
                    upperSky: srgbColor(0.45, 0.46, 0.48),
                    horizon: srgbColor(0.72, 0.73, 0.75),
                    belowHorizon: srgbColor(0.40, 0.40, 0.42),
                    nadir: srgbColor(0.22, 0.22, 0.23),
                    groundBase: srgbColor(0.46, 0.47, 0.49),
                    gridMinor: srgbColor(0.55, 0.56, 0.58),
                    gridMajor: srgbColor(0.66, 0.67, 0.70),
                    lightColor: look.lightColor,
                    lightIntensity: look.lightIntensity,
                    lightDirection: light,
                    iblIntensityExponent: 0.3
                )
            case .daylight:
                return Palette(
                    zenith: srgbColor(0.16, 0.38, 0.78),
                    upperSky: srgbColor(0.36, 0.58, 0.90),
                    horizon: srgbColor(0.84, 0.90, 0.96),
                    belowHorizon: srgbColor(0.56, 0.59, 0.56),
                    nadir: srgbColor(0.32, 0.34, 0.32),
                    groundBase: srgbColor(0.50, 0.55, 0.48),
                    gridMinor: srgbColor(0.59, 0.64, 0.57),
                    gridMajor: srgbColor(0.72, 0.77, 0.70),
                    lightColor: look.lightColor,
                    lightIntensity: look.lightIntensity,
                    lightDirection: light,
                    iblIntensityExponent: 0.6
                )
            case .sunset:
                return Palette(
                    zenith: srgbColor(0.06, 0.08, 0.28),
                    upperSky: srgbColor(0.30, 0.20, 0.45),
                    horizon: srgbColor(1.0, 0.55, 0.24),
                    belowHorizon: srgbColor(0.36, 0.22, 0.18),
                    nadir: srgbColor(0.14, 0.10, 0.10),
                    groundBase: srgbColor(0.36, 0.29, 0.27),
                    gridMinor: srgbColor(0.45, 0.36, 0.32),
                    gridMajor: srgbColor(0.60, 0.45, 0.36),
                    lightColor: look.lightColor,
                    lightIntensity: look.lightIntensity,
                    lightDirection: light,
                    iblIntensityExponent: 0.1
                )
            case .night:
                return Palette(
                    zenith: srgbColor(0.01, 0.02, 0.07),
                    upperSky: srgbColor(0.03, 0.05, 0.13),
                    horizon: srgbColor(0.10, 0.13, 0.22),
                    belowHorizon: srgbColor(0.05, 0.05, 0.08),
                    nadir: srgbColor(0.02, 0.02, 0.03),
                    groundBase: srgbColor(0.12, 0.13, 0.17),
                    gridMinor: srgbColor(0.18, 0.20, 0.27),
                    gridMajor: srgbColor(0.26, 0.30, 0.42),
                    lightColor: look.lightColor,
                    lightIntensity: look.lightIntensity,
                    lightDirection: light,
                    iblIntensityExponent: -1.0
                )
            }
        }
    }

    @MainActor private static func makeSkyDome(_ palette: Palette) async -> Entity {
        let mesh = MeshResource.generateSphere(radius: 400)

        var material = UnlitMaterial(color: palette.horizon)
        if let image = gradientImage(width: 16, height: 512, stops: palette.skyStops) {
            do {
                let texture = try await TextureResource(image: image, options: .init(semantic: .color))
                var textured = UnlitMaterial()
                textured.color = .init(tint: .white, texture: .init(texture))
                material = textured
            } catch {
                // Keep the solid horizon colour.
            }
        }

        let sky = ModelEntity(mesh: mesh, materials: [material])
        sky.name = "SkyDome"
        // Mirror on X so the sphere's faces are visible from the inside.
        sky.scale = [-1, 1, 1]
        return sky
    }

    @MainActor private static func makeGround(_ palette: Palette) async -> Entity {
        let mesh = MeshResource.generatePlane(width: 80, depth: 80)

        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: palette.groundBase)
        material.roughness = .init(floatLiteral: 0.92)
        material.metallic = .init(floatLiteral: 0.0)

        // One texture tile = 8 m x 8 m (minor line every 1 m, major line on the tile edge).
        // The 80 m plane repeats it 10 times.
        if let image = gridImage(
            size: 1024,
            cells: 8,
            base: palette.groundBase,
            minor: palette.gridMinor,
            major: palette.gridMajor
        ) {
            do {
                let texture = try await TextureResource(image: image, options: .init(semantic: .color))
                material.baseColor = .init(tint: .white, texture: .init(texture, sampler: repeatingSampler()))
                material.textureCoordinateTransform.scale = [10, 10]
            } catch {
                // Keep the plain tinted ground.
            }
        }

        let ground = ModelEntity(mesh: mesh, materials: [material])
        ground.name = "Ground"
        ground.position = [0, 0, 0]
        return ground
    }

    @MainActor private static func makeImageBasedLight(_ palette: Palette) async -> Entity? {
        guard let image = gradientImage(width: 256, height: 128, stops: palette.skyStops) else { return nil }
        if #available(visionOS 2.0, *) {
            do {
                let resource = try await EnvironmentResource(equirectangular: image)
                let entity = Entity()
                entity.name = imageBasedLightName
                entity.components.set(
                    ImageBasedLightComponent(source: .single(resource), intensityExponent: palette.iblIntensityExponent)
                )
                return entity
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: - CoreGraphics images (procedural fallback)

    private static func makeContext(width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func sRGBSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Vertical gradient; the first stop is the top row of the resulting image.
    private static func gradientImage(width: Int, height: Int, stops: [(UIColor, CGFloat)]) -> CGImage? {
        let space = sRGBSpace()
        guard let context = makeContext(width: width, height: height, space: space) else { return nil }
        let colors = stops.map { $0.0.cgColor } as CFArray
        let locations: [CGFloat] = stops.map { $0.1 }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return nil }
        // CoreGraphics' origin is bottom-left: y = height is the top of the image.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: 0, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        return context.makeImage()
    }

    /// Seamlessly tiling grid: `cells` minor cells per side, major line on the tile border.
    private static func gridImage(size: Int, cells: Int, base: UIColor, minor: UIColor, major: UIColor) -> CGImage? {
        guard let context = makeContext(width: size, height: size, space: sRGBSpace()) else { return nil }
        let full = CGFloat(size)
        let cell = full / CGFloat(max(cells, 1))

        context.setFillColor(base.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: full, height: full))

        let minorWidth: CGFloat = 3
        let majorWidth: CGFloat = 6

        for index in 0..<max(cells, 1) {
            let isMajor = index == 0
            let width = isMajor ? majorWidth : minorWidth
            let offset = CGFloat(index) * cell
            context.setFillColor((isMajor ? major : minor).cgColor)
            // Vertical and horizontal line centred on `offset`.
            context.fill(CGRect(x: offset - width / 2, y: 0, width: width, height: full))
            context.fill(CGRect(x: 0, y: offset - width / 2, width: full, height: width))
            if isMajor {
                // Wrap the half of the border line that falls outside the tile.
                context.fill(CGRect(x: full - width / 2, y: 0, width: width, height: full))
                context.fill(CGRect(x: 0, y: full - width / 2, width: full, height: width))
            }
        }
        return context.makeImage()
    }
}

/// sRGB colour helper for the environment palettes.
private func srgbColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
    UIColor(red: r, green: g, blue: b, alpha: 1)
}
