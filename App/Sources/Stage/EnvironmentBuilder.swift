import Foundation
import CoreGraphics
import Metal
import RealityKit
import UIKit
import simd

/// Builds the procedural environment shown in Immersive (`.full`) mode:
/// a gradient sky dome, a gridded ground plane at y = 0, image-based lighting
/// made from the same gradient, and a directional "sun" with shadows.
/// No external assets are used.
enum EnvironmentBuilder {
    /// Name of the child entity that carries the `ImageBasedLightComponent`.
    /// StageController looks it up to point `ImageBasedLightReceiverComponent` at it.
    static let imageBasedLightName = "QVEnvironmentIBL"

    @MainActor static func make(_ preset: EnvironmentPreset) async -> Entity {
        let palette = Palette.forPreset(preset)

        let root = Entity()
        root.name = "Environment-\(preset.rawValue)"

        root.addChild(await makeSkyDome(palette))
        root.addChild(await makeGround(palette))
        if let ibl = await makeImageBasedLight(palette) {
            root.addChild(ibl)
        }
        if let sun = makeSun(palette) {
            root.addChild(sun)
        }
        return root
    }

    // MARK: - Palette

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

        static func forPreset(_ preset: EnvironmentPreset) -> Palette {
            switch preset {
            case .studio:
                return Palette(
                    zenith: rgb(0.30, 0.31, 0.33),
                    upperSky: rgb(0.45, 0.46, 0.48),
                    horizon: rgb(0.72, 0.73, 0.75),
                    belowHorizon: rgb(0.40, 0.40, 0.42),
                    nadir: rgb(0.22, 0.22, 0.23),
                    groundBase: rgb(0.46, 0.47, 0.49),
                    gridMinor: rgb(0.55, 0.56, 0.58),
                    gridMajor: rgb(0.66, 0.67, 0.70),
                    lightColor: rgb(1.0, 1.0, 1.0),
                    lightIntensity: 1800,
                    lightDirection: [-0.3, -1.0, -0.4],
                    iblIntensityExponent: 0.3
                )
            case .daylight:
                return Palette(
                    zenith: rgb(0.16, 0.38, 0.78),
                    upperSky: rgb(0.36, 0.58, 0.90),
                    horizon: rgb(0.84, 0.90, 0.96),
                    belowHorizon: rgb(0.56, 0.59, 0.56),
                    nadir: rgb(0.32, 0.34, 0.32),
                    groundBase: rgb(0.50, 0.55, 0.48),
                    gridMinor: rgb(0.59, 0.64, 0.57),
                    gridMajor: rgb(0.72, 0.77, 0.70),
                    lightColor: rgb(1.0, 0.97, 0.92),
                    lightIntensity: 3000,
                    lightDirection: [-0.4, -1.0, -0.3],
                    iblIntensityExponent: 0.6
                )
            case .sunset:
                return Palette(
                    zenith: rgb(0.06, 0.08, 0.28),
                    upperSky: rgb(0.30, 0.20, 0.45),
                    horizon: rgb(1.0, 0.55, 0.24),
                    belowHorizon: rgb(0.36, 0.22, 0.18),
                    nadir: rgb(0.14, 0.10, 0.10),
                    groundBase: rgb(0.36, 0.29, 0.27),
                    gridMinor: rgb(0.45, 0.36, 0.32),
                    gridMajor: rgb(0.60, 0.45, 0.36),
                    lightColor: rgb(1.0, 0.68, 0.42),
                    lightIntensity: 1600,
                    // Low sun ahead of the user (towards -Z), light travelling towards +Z.
                    lightDirection: [0.15, -0.35, 1.0],
                    iblIntensityExponent: 0.1
                )
            case .night:
                return Palette(
                    zenith: rgb(0.01, 0.02, 0.07),
                    upperSky: rgb(0.03, 0.05, 0.13),
                    horizon: rgb(0.10, 0.13, 0.22),
                    belowHorizon: rgb(0.05, 0.05, 0.08),
                    nadir: rgb(0.02, 0.02, 0.03),
                    groundBase: rgb(0.12, 0.13, 0.17),
                    gridMinor: rgb(0.18, 0.20, 0.27),
                    gridMajor: rgb(0.26, 0.30, 0.42),
                    lightColor: rgb(0.62, 0.72, 1.0),
                    lightIntensity: 350,
                    lightDirection: [0.3, -1.0, 0.2],
                    iblIntensityExponent: -1.0
                )
            }
        }

        private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: 1)
        }
    }

    // MARK: - Sky dome

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

    // MARK: - Ground

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

    private static func repeatingSampler() -> MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = 8
        return MaterialParameters.Texture.Sampler(descriptor)
    }

    // MARK: - Lighting

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

    @MainActor private static func makeSun(_ palette: Palette) -> Entity? {
        if #available(visionOS 2.0, *) {
            let sun = Entity()
            sun.name = "Sun"
            sun.components.set(DirectionalLightComponent(color: palette.lightColor, intensity: palette.lightIntensity))
            sun.components.set(DirectionalLightComponent.Shadow())
            // A directional light shines along its local -Z axis.
            let direction = simd_normalize(palette.lightDirection)
            sun.orientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: direction)
            sun.position = [0, 6, 0]
            return sun
        }
        return nil
    }

    // MARK: - CoreGraphics images

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
