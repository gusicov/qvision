import Foundation
import RealityKit
import UIKit
import simd

/// STAGEit-style fly mode.
///
/// Clench BOTH fists to grab. While held:
/// - moving the fists' midpoint away from where you clenched flies you in that direction
///   (speed proportional to distance, with a deadzone and a max speed);
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

    private static let translationDeadzone: Float = 0.03       // m
    private static let translationGain: Float = 4               // (m/s) per m, × speed
    private static let maxSpeed: Float = 3                      // m/s, × speed
    private static let yawDeadzone: Float = 5 * Float.pi / 180  // rad
    private static let yawGain: Float = 1.5                     // (rad/s) per rad
    private static let maxYawRate: Float = 1.2                  // rad/s
    private static let damping: Float = 8                       // 1/s, exponential smoothing rate
    private static let maxDeltaTime: Float = 0.05               // s
    /// A hand that briefly LOSES TRACKING (fists self-occlude) does not end the grab for this long.
    /// A hand that is tracked and OPEN ends it immediately.
    private static let trackingGrace: Float = 0.15              // s
    /// Below this horizontal fist separation the yaw angle is unreliable; yaw input is ignored.
    private static let minYawBarLength: Float = 0.08            // m
    private static let restEpsilon: Float = 0.001
    private static let arrowMinSpeed: Float = 0.05              // m/s

    // MARK: Init

    init(hands: HandTrackingService) {
        self.hands = hands

        let root = Entity()
        root.name = "FlyIndicator"

        let cyan = UIColor(red: 0.2, green: 0.9, blue: 1.0, alpha: 1.0)

        // Ring: a thin flat cylinder (disc), lying horizontally (cylinder axis = +Y).
        var ringMaterial = UnlitMaterial(color: cyan)
        ringMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.6))
        let ring = ModelEntity(
            mesh: MeshResource.generateCylinder(height: 0.004, radius: 0.05),
            materials: [ringMaterial]
        )
        ring.name = "FlyIndicator.ring"
        root.addChild(ring)

        // Arrow: a cone along +Y (visionOS 2), box fallback. Oriented along the velocity each frame.
        var arrowMaterial = UnlitMaterial(color: cyan)
        arrowMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let arrowMesh: MeshResource
        if #available(visionOS 2.0, *) {
            arrowMesh = MeshResource.generateCone(height: 0.04, radius: 0.012)
        } else {
            arrowMesh = MeshResource.generateBox(width: 0.016, height: 0.04, depth: 0.016)
        }
        let arrow = ModelEntity(mesh: arrowMesh, materials: [arrowMaterial])
        arrow.name = "FlyIndicator.arrow"
        arrow.isEnabled = false
        root.addChild(arrow)

        root.isEnabled = false

        self.ring = ring
        self.arrow = arrow
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

        // Exponential (critically damped style) smoothing toward the target; on release target = 0.
        let alpha = 1 - exp(-dt * Self.damping)
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

    /// v = d' * gain, |v| <= maxSpeed. Direction is exactly where the fists moved.
    private func translationTarget(midpoint: SIMD3<Float>) -> SIMD3<Float> {
        let s = max(0, speed)
        let d = midpoint - grabMidpoint
        let length = simd_length(d)
        guard length > Self.translationDeadzone else { return .zero }
        let dPrime = d * ((length - Self.translationDeadzone) / length)
        var v = dPrime * (Self.translationGain * s)
        let maxV = Self.maxSpeed * s
        let vLength = simd_length(v)
        if vLength > maxV && vLength > 0 {
            v *= maxV / vLength
        }
        return v
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
        let magnitude = max(0, abs(delta) - Self.yawDeadzone)
        let omega = (delta < 0 ? -magnitude : magnitude) * Self.yawGain
        return min(max(omega, -Self.maxYawRate), Self.maxYawRate)
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
        if vLength > Self.arrowMinSpeed {
            let direction = velocity / vLength
            arrow.isEnabled = true
            arrow.position = direction * 0.085
            arrow.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
        } else if arrow.isEnabled {
            arrow.isEnabled = false
        }
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
