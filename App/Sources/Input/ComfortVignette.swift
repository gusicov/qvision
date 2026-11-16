import CoreGraphics
import Foundation
import RealityKit
import UIKit
import simd

/// v0.9 D4: a soft dark vignette at the edge of the view while flying fast or turning, which
/// reduces motion discomfort. Head-anchored (RealityKit keeps it locked to the view), fully
/// transparent in the centre, and invisible (disabled) when not moving fast.
///
/// One instance per immersive view: add `anchor` to the RealityView content, call `prepare()`
/// once and `update(...)` every frame.
@MainActor
final class ComfortVignette {
    let anchor: Entity

    private var plane: ModelEntity?
    private var isPreparing = false
    private var shown: Float = 0
    private var applied: Float = -1

    // Tuning: the vignette starts at `speedStart` m/s and is full at `speedFull`.
    private static let speedStart: Float = 4
    private static let speedFull: Float = 14
    private static let yawStart: Float = 0.5      // rad/s
    private static let yawFull: Float = 1.4
    private static let maxOpacity: Float = 0.9
    private static let distance: Float = 0.35     // m in front of the eyes
    private static let size: Float = 1.7          // m (covers the whole field of view)

    init() {
        let head = AnchorEntity(.head)
        head.name = "ComfortVignetteAnchor"
        anchor = head
    }

    /// Builds the vignette (a small generated texture on one plane). Safe to call repeatedly.
    func prepare() async {
        guard plane == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        guard let image = Self.maskImage(size: 256),
              let texture = try? await TextureResource(image: image, options: .init(semantic: .raw)) else { return }
        guard plane == nil else { return }

        var material = UnlitMaterial(color: .black)
        material.blending = .transparent(opacity: .init(scale: 1, texture: .init(texture)))
        let entity = ModelEntity(mesh: .generatePlane(width: Self.size, height: Self.size), materials: [material])
        entity.name = "ComfortVignette"
        entity.position = SIMD3<Float>(0, 0, -Self.distance)
        entity.isEnabled = false
        anchor.addChild(entity)
        plane = entity
    }

    /// `speed` in m/s, `yawRate` in rad/s (FlyController.currentSpeed / currentYawRate).
    func update(speed: Float, yawRate: Float, enabled: Bool, deltaTime: Float) {
        guard let plane else { return }
        var target: Float = 0
        if enabled {
            let bySpeed = (speed - Self.speedStart) / (Self.speedFull - Self.speedStart)
            let byYaw = (yawRate - Self.yawStart) / (Self.yawFull - Self.yawStart)
            target = Swift.min(Swift.max(Swift.max(bySpeed, byYaw), 0), 1) * Self.maxOpacity
        }
        let blend = Swift.min(1, Swift.max(deltaTime, 0) * 6)
        shown += (target - shown) * blend

        if shown < 0.02 {
            if plane.isEnabled {
                plane.isEnabled = false
                applied = -1
            }
            return
        }
        if !plane.isEnabled { plane.isEnabled = true }
        if abs(shown - applied) > 0.02 {
            applied = shown
            plane.components.set(OpacityComponent(opacity: shown))
        }
    }

    func hide() {
        shown = 0
        applied = -1
        plane?.isEnabled = false
    }

    /// Radial mask: 0 in the centre, 1 at the edge. Every channel carries the value, so it works
    /// whichever channel the opacity input samples.
    private static func maskImage(size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [
            UIColor(white: 1, alpha: 0).cgColor,
            UIColor(white: 1, alpha: 0).cgColor,
            UIColor(white: 1, alpha: 1).cgColor
        ] as CFArray
        let locations: [CGFloat] = [0, 0.38, 1]
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return nil }
        let centre = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                   endCenter: centre, endRadius: CGFloat(size) * 0.36,
                                   options: [.drawsAfterEndLocation])
        return context.makeImage()
    }
}
