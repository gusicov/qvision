import Foundation
import RealityKit
import UIKit
import simd

/// STAGEit-style fly mode.
///
/// Clench BOTH fists to grab. While held:
/// - moving the fists' midpoint away from where you clenched flies you in that direction
///   (nonlinear speed curve: precise near the grab point, much faster farther out; deadzone + cap);
/// - twisting the fists around each other like a horizontal steering wheel turns you
///   (right fist forward / left fist back = turn left).
/// Opening either hand releases; motion then decays smoothly to zero.
///
/// The user never moves: `worldRoot` is moved the opposite way (translation + yaw about the head).
@MainActor final class FlyController {
    /// false -> stops immediately, hides the indicator.
    var isEnabled: Bool = false {
        didSet {
            if !isEnabled { cancelFlight() }
        }
    }

    /// Multiplier on translation gain and max speed. Default 1.
    var speed: Float = 1

    private(set) var isFlying: Bool = false

    /// Small ring (+ direction arrow) shown at the grab point while flying. StageView adds it to content
    /// at the top level (NOT under worldRoot), so it stays fixed relative to the user.
    let indicator: Entity

    // MARK: Private state

    private let hands: HandTrackingService
    private let ring: ModelEntity
    private let arrow: ModelEntity
    /// Pre-built materials per speed bucket (cyan -> white), so a bucket change only swaps arrays.
    private let ringMaterials: [UnlitMaterial]
    private let arrowMaterials: [UnlitMaterial]
    private var speedBucket: Int = 0

    private var grabMidpoint: SIMD3<Float> = .zero     // M0, world space
    private var grabYaw: Float = 0                     // θ0
    private var grabYawValid = false
    private var grabHead: SIMD3<Float>?                // H at grab time (fallback pivot)
    private var lastHead: SIMD3<Float>?

    private var velocity: SIMD3<Float> = .zero         // smoothed user velocity (m/s, world)
    private var yawRate: Float = 0                     // smoothed user yaw rate (rad/s, + = turn left)
    private var heldTargetVelocity: SIMD3<Float> = .zero
    private var heldTargetYawRate: Float = 0
    private var trackingLossTime: Float = 0

    // MARK: Tuning

    // Translation: x = max(0, |d| - deadzone);  speed(x) = (linear·x + quadratic·x²) · speed, capped.
    private static let translationDeadzone: Float = 0.025      // m
    private static let translationLinearGain: Float = 2.5       // (m/s) per m, × speed
    private static let translationQuadraticGain: Float = 45     // (m/s) per m², × speed
    private static let maxSpeed: Float = 14                     // m/s, × speed
    // Yaw: a = max(0, |Δθ| - deadzone);  ω = linear·a + quadratic·a², capped.
    private static let yawDeadzone: Float = 5 * Float.pi / 180  // rad
    private static let yawLinearGain: Float = 1.2               // (rad/s) per rad
    private static let yawQuadraticGain: Float = 2.0            // (rad/s) per rad²
    private static let maxYawRate: Float = 1.6                  // rad/s
    /// Exponential smoothing rate while the grab is held (speed-up / steering).
    private static let holdDamping: Float = 10                  // 1/s
    /// Exponential smoothing rate after release (fists opened): smooth stop.
    private static let releaseDamping: Float = 6                // 1/s
    private static let maxDeltaTime: Float = 0.05               // s
    /// A hand that briefly LOSES TRACKING (fists self-occlude) does not end the grab for this long.
    /// A hand that is tracked and OPEN ends it immediately.
    private static let trackingGrace: Float = 0.15              // s
    /// Below this horizontal fist separation the yaw angle is unreliable; yaw input is ignored.
    private static let minYawBarLength: Float = 0.08            // m
    private static let restEpsilon: Float = 0.001
    private static let arrowMinSpeed: Float = 0.05              // m/s
    // Indicator feedback.
    private static let ringRadius: Float = 0.05                 // m
    private static let arrowGap: Float = 0.01                   // m between ring edge and arrow base
    private static let arrowMeshLength: Float = 0.04            // m, unscaled cone height
    private static let arrowMinLength: Float = 0.03             // m, at rest
    private static let arrowMaxLength: Float = 0.12             // m, at >= arrowFullSpeed
    private static let arrowFullSpeed: Float = 5                // m/s
    /// Upper bounds (m/s) of speed buckets 0...2; bucket 3 is everything above the last one.
    private static let speedBucketLimits: [Float] = [0.75, 2, 5]

    // MARK: Init

    init(hands: HandTrackingService) {
        self.hands = hands

        let root = Entity()
        root.name = "FlyIndicator"

        // Tint per speed bucket: cyan at rest -> white at high speed.
        let bucketCount = FlyController.speedBucketLimits.count + 1
        var ringMats: [UnlitMaterial] = []
        var arrowMats: [UnlitMaterial] = []
        for i in 0..<bucketCount {
            let t = CGFloat(i) / CGFloat(bucketCount - 1)
            let color = UIColor(
                red: 0.2 + 0.8 * t,
                green: 0.9 + 0.1 * t,
                blue: 1.0,
                alpha: 1.0
            )
            var ringMat = UnlitMaterial(color: color)
            ringMat.blending = .transparent(opacity: .init(floatLiteral: 0.6))
            ringMats.append(ringMat)
            var arrowMat = UnlitMaterial(color: color)
            arrowMat.blending = .transparent(opacity: .init(floatLiteral: 0.85))
            arrowMats.append(arrowMat)
        }

        // Ring: a thin flat cylinder (disc), lying horizontally (cylinder axis = +Y).
        let ring = ModelEntity(
            mesh: MeshResource.generateCylinder(height: 0.004, radius: FlyController.ringRadius),
            materials: [ringMats[0]]
        )
        ring.name = "FlyIndicator.ring"
        root.addChild(ring)

        // Arrow: a cone along +Y (visionOS 2), box fallback. Oriented along the velocity each frame,
        // and stretched along its local Y to show the current speed.
        let arrowMesh: MeshResource
        if #available(visionOS 2.0, *) {
            arrowMesh = MeshResource.generateCone(height: FlyController.arrowMeshLength, radius: 0.012)
        } else {
            arrowMesh = MeshResource.generateBox(width: 0.016, height: FlyController.arrowMeshLength, depth: 0.016)
        }
        let arrow = ModelEntity(mesh: arrowMesh, materials: [arrowMats[0]])
        arrow.name = "FlyIndicator.arrow"
        arrow.isEnabled = false
        root.addChild(arrow)

        root.isEnabled = false

        self.ring = ring
        self.arrow = arrow
        self.ringMaterials = ringMats
        self.arrowMaterials = arrowMats
        self.indicator = root
    }

    // MARK: Per-frame

    func update(deltaTime: Float, worldRoot: Entity) {
        guard isEnabled else { return }
        let dt = min(max(deltaTime, 0), Self.maxDeltaTime)
        guard dt > 0 else { return }

        let left = hands.left
        let right = hands.right
        let headNow = currentHeadPosition()

        var targetVelocity: SIMD3<Float> = .zero
        var targetYawRate: Float = 0

        if left.isTracked && right.isTracked && left.isFist && right.isFist {
            trackingLossTime = 0
            let midpoint = (left.palmCenter + right.palmCenter) * 0.5
            let bar = left.palmCenter - right.palmCenter   // right -> left

            if !isFlying {
                beginGrab(midpoint: midpoint, bar: bar, head: headNow)
            }
            targetVelocity = translationTarget(midpoint: midpoint)
            targetYawRate = yawTarget(bar: bar)
            heldTargetVelocity = targetVelocity
            heldTargetYawRate = targetYawRate
        } else if isFlying {
            let handOpened = (left.isTracked && !left.isFist) || (right.isTracked && !right.isFist)
            if !handOpened && trackingLossTime + dt <= Self.trackingGrace {
                // Tracking dropout only: keep the last command for a moment.
                trackingLossTime += dt
                targetVelocity = heldTargetVelocity
                targetYawRate = heldTargetYawRate
            } else {
                endGrab()
            }
        }

        // Exponential smoothing toward the target: snappy while held, gentler after release
        // (target = 0) so stopping stays smooth.
        let rate = isFlying ? Self.holdDamping : Self.releaseDamping
        let alpha = 1 - exp(-dt * rate)
        velocity += (targetVelocity - velocity) * alpha
        yawRate += (targetYawRate - yawRate) * alpha
        if !isFlying {
            if simd_length(velocity) < Self.restEpsilon { velocity = .zero }
            if abs(yawRate) < Self.restEpsilon { yawRate = 0 }
        }

        // Apply to worldRoot: the world moves the opposite way to the user.
        // worldRoot's parent (stage.root) is identity, so its position is effectively world space.
        if velocity != .zero {
            worldRoot.position -= velocity * dt
        }
        if yawRate != 0 {
            // Rotate the world about the vertical axis through the CURRENT head position.
            let pivot = headNow ?? grabHead ?? lastHead ?? .zero
            let q = simd_quatf(angle: -yawRate * dt, axis: SIMD3<Float>(0, 1, 0))
            let p = worldRoot.position
            worldRoot.position = q.act(p - pivot) + pivot
            worldRoot.orientation = (q * worldRoot.orientation).normalized
        }

        updateIndicator()
    }

    /// Recenter: worldRoot back to identity, motion stopped. If the fists are still clenched,
    /// a fresh grab starts next frame from the current hand position.
    func resetOffset(worldRoot: Entity) {
        worldRoot.transform = .identity
        velocity = .zero
        yawRate = 0
        endGrab()
    }

    // MARK: Private

    private func beginGrab(midpoint: SIMD3<Float>, bar: SIMD3<Float>, head: SIMD3<Float>?) {
        isFlying = true
        grabMidpoint = midpoint
        grabHead = head ?? lastHead
        trackingLossTime = 0
        heldTargetVelocity = .zero
        heldTargetYawRate = 0
        if Self.horizontalLength(bar) >= Self.minYawBarLength {
            grabYaw = Self.yaw(of: bar)
            grabYawValid = true
        } else {
            grabYawValid = false
        }
    }

    private func endGrab() {
        isFlying = false
        trackingLossTime = 0
        heldTargetVelocity = .zero
        heldTargetYawRate = 0
        grabYawValid = false
        hideIndicator()
    }

    private func cancelFlight() {
        endGrab()
        velocity = .zero
        yawRate = 0
    }

    /// x = |d| - deadzone,  |v| = (2.5·x + 45·x²)·speed,  |v| <= 14·speed.
    /// Direction is exactly where the fists moved (d normalised).
    private func translationTarget(midpoint: SIMD3<Float>) -> SIMD3<Float> {
        let s = max(0, speed)
        guard s > 0 else { return .zero }
        let d = midpoint - grabMidpoint
        let length = simd_length(d)
        guard length > Self.translationDeadzone else { return .zero }
        let x = length - Self.translationDeadzone
        let curve = Self.translationLinearGain * x + Self.translationQuadraticGain * x * x
        let magnitude = min(curve * s, Self.maxSpeed * s)
        return d * (magnitude / length)
    }

    /// ω from the twist of the right->left fist vector around the vertical axis.
    /// θ = atan2(x, z) is a right-handed angle about +Y, so Δθ > 0 (right fist forward, left back,
    /// i.e. the bar turns counter-clockwise seen from above) means "turn left" (user yaw +).
    private func yawTarget(bar: SIMD3<Float>) -> Float {
        guard Self.horizontalLength(bar) >= Self.minYawBarLength else { return 0 }
        let theta = Self.yaw(of: bar)
        if !grabYawValid {
            // Fists were too close together horizontally at grab time: anchor the yaw now.
            grabYaw = theta
            grabYawValid = true
            return 0
        }
        let delta = Self.wrapAngle(theta - grabYaw)
        let a = max(0, abs(delta) - Self.yawDeadzone)
        let rate = min(Self.yawLinearGain * a + Self.yawQuadraticGain * a * a, Self.maxYawRate)
        return delta < 0 ? -rate : rate
    }

    private func currentHeadPosition() -> SIMD3<Float>? {
        guard let pose = hands.devicePose() else { return nil }
        let head = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        lastHead = head
        return head
    }

    private func updateIndicator() {
        guard isFlying else {
            hideIndicator()
            return
        }
        if !indicator.isEnabled { indicator.isEnabled = true }
        // Indicator is top-level content, so world space == its parent space.
        indicator.setPosition(grabMidpoint, relativeTo: nil)

        let vLength = simd_length(velocity)
        setSpeedBucket(Self.bucket(forSpeed: vLength))

        if vLength > Self.arrowMinSpeed {
            let direction = velocity / vLength
            let t = min(vLength / Self.arrowFullSpeed, 1)
            let arrowLength = Self.arrowMinLength + (Self.arrowMaxLength - Self.arrowMinLength) * t
            if !arrow.isEnabled { arrow.isEnabled = true }
            // Mesh is centred on its origin: put the base just outside the ring.
            arrow.position = direction * (Self.ringRadius + Self.arrowGap + arrowLength * 0.5)
            arrow.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
            arrow.scale = SIMD3<Float>(1, arrowLength / Self.arrowMeshLength, 1)
        } else if arrow.isEnabled {
            arrow.isEnabled = false
        }
    }

    /// Swaps the tint materials only when the bucket actually changes.
    private func setSpeedBucket(_ bucket: Int) {
        guard bucket != speedBucket,
              bucket >= 0, bucket < ringMaterials.count, bucket < arrowMaterials.count else { return }
        speedBucket = bucket
        ring.model?.materials = [ringMaterials[bucket]]
        arrow.model?.materials = [arrowMaterials[bucket]]
    }

    private static func bucket(forSpeed v: Float) -> Int {
        for (i, limit) in speedBucketLimits.enumerated() where v < limit {
            return i
        }
        return speedBucketLimits.count
    }

    private func hideIndicator() {
        if indicator.isEnabled { indicator.isEnabled = false }
        if arrow.isEnabled { arrow.isEnabled = false }
    }

    private static func yaw(of v: SIMD3<Float>) -> Float {
        atan2(v.x, v.z)
    }

    private static func horizontalLength(_ v: SIMD3<Float>) -> Float {
        (v.x * v.x + v.z * v.z).squareRoot()
    }

    /// Wraps an angle to (-π, π].
    private static func wrapAngle(_ a: Float) -> Float {
        atan2(sin(a), cos(a))
    }
}
