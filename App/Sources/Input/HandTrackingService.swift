import Foundation
import ARKit
import QuartzCore
import Observation
import simd

// MARK: - HandState

/// Snapshot of one hand, in world space (ARKit origin == ImmersiveSpace origin).
struct HandState: Equatable {
    var isTracked: Bool
    var isFist: Bool                    // index+middle+ring+little curled (tips near palm), hysteresis
    var palmFacingUser: Bool            // palm normal points toward the head (needs device pose)
    var palmCenter: SIMD3<Float>        // world space
    var wristTransform: simd_float4x4   // world space

    static let untracked = HandState(
        isTracked: false,
        isFist: false,
        palmFacingUser: false,
        palmCenter: .zero,
        wristTransform: matrix_identity_float4x4
    )

    // Explicit `==` so we never depend on simd matrix Equatable conformance.
    static func == (lhs: HandState, rhs: HandState) -> Bool {
        lhs.isTracked == rhs.isTracked
            && lhs.isFist == rhs.isFist
            && lhs.palmFacingUser == rhs.palmFacingUser
            && lhs.palmCenter == rhs.palmCenter
            && lhs.wristTransform.columns.0 == rhs.wristTransform.columns.0
            && lhs.wristTransform.columns.1 == rhs.wristTransform.columns.1
            && lhs.wristTransform.columns.2 == rhs.wristTransform.columns.2
            && lhs.wristTransform.columns.3 == rhs.wristTransform.columns.3
    }
}

// MARK: - HandTrackingService

@MainActor @Observable final class HandTrackingService {
    enum Status: Equatable {
        case idle, running, unsupported, denied, failed(String)
    }

    private(set) var status: Status = .idle

    /// NOT observed (updated at ~90 Hz). Read once per frame from the render loop.
    @ObservationIgnored private(set) var left: HandState = .untracked
    @ObservationIgnored private(set) var right: HandState = .untracked

    // ARKit objects. Providers cannot be re-run after a stop, so start() always creates fresh ones.
    @ObservationIgnored private var session: ARKitSession?
    @ObservationIgnored private var handProvider: HandTrackingProvider?
    @ObservationIgnored private var worldProvider: WorldTrackingProvider?

    @ObservationIgnored private var anchorTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var isStarting = false
    /// Bumped by every start()/stop(); stale async work compares against it and bails out.
    @ObservationIgnored private var generation: UInt64 = 0

    // Hysteresis latches.
    @ObservationIgnored private var leftFistLatched = false
    @ObservationIgnored private var rightFistLatched = false
    /// Raw hysteresis latch of the palm-facing test (before the minimum-hold debounce).
    @ObservationIgnored private var leftPalmLatched = false
    @ObservationIgnored private var rightPalmLatched = false
    /// Debounced value actually published in `HandState.palmFacingUser`.
    @ObservationIgnored private var leftPalmOutput = false
    @ObservationIgnored private var rightPalmOutput = false
    /// When the raw latch first disagreed with the published value (nil = they agree).
    @ObservationIgnored private var leftPalmPendingSince: CFTimeInterval?
    @ObservationIgnored private var rightPalmPendingSince: CFTimeInterval?

    // Tuning.
    private static let fistEnterDistance: Float = 0.075   // all four tips closer than this -> fist
    private static let fistExitDistance: Float = 0.095    // any tip farther than this -> open
    private static let palmFacingEnter: Float = 0.55      // cos(angle) palm normal vs. direction to head: > enter -> facing
    private static let palmFacingExit: Float = 0.35       // < exit -> not facing (wide hysteresis band)
    /// A change of the raw palm latch must persist this long before it is published, so every
    /// published state lasts at least this long (no single-frame flicker of the hand panel).
    private static let palmFacingMinHold: CFTimeInterval = 0.12

    init() {}

    // MARK: Lifecycle

    /// Starts hand + world tracking. Idempotent: returns immediately if already running or starting.
    func start() async {
        if status == .running || isStarting { return }

        guard HandTrackingProvider.isSupported else {
            status = .unsupported
            return
        }

        generation &+= 1
        let gen = generation
        isStarting = true
        defer {
            if gen == generation { isStarting = false }
        }

        let session = ARKitSession()
        let hands = HandTrackingProvider()
        let world = WorldTrackingProvider()
        self.session = session
        self.handProvider = hands
        self.worldProvider = world

        let auth = await session.requestAuthorization(for: [.handTracking])
        guard gen == generation else { return }   // stop() was called while we waited
        if auth[.handTracking] == .denied {
            status = .denied
            return
        }

        do {
            var providers: [any DataProvider] = [hands]
            if WorldTrackingProvider.isSupported {
                providers.append(world)
            }
            try await session.run(providers)
        } catch {
            guard gen == generation else { return }
            status = .failed(error.localizedDescription)
            return
        }

        guard gen == generation else {
            // stop() ran while session.run was in flight: make sure nothing keeps running.
            session.stop()
            return
        }

        status = .running

        // These Tasks are created from a @MainActor method, so they inherit the main actor:
        // every write to `left` / `right` / `status` below happens on the main actor.
        anchorTask = Task { [weak self] in
            for await update in hands.anchorUpdates {
                if Task.isCancelled { return }
                guard let self, self.generation == gen else { return }
                self.handle(update)
            }
            self?.anchorStreamEnded(generation: gen)
        }

        eventTask = Task { [weak self] in
            for await event in session.events {
                if Task.isCancelled { return }
                guard let self, self.generation == gen else { return }
                switch event {
                case .authorizationChanged(let type, let newStatus):
                    if type == .handTracking && newStatus == .denied {
                        self.teardown(finalStatus: .denied)
                    }
                case .dataProviderStateChanged(_, let newState, let error):
                    if case .stopped = newState, let error {
                        self.teardown(finalStatus: .failed(error.localizedDescription))
                    }
                default:
                    break
                }
            }
        }
    }

    func stop() {
        teardown(finalStatus: .idle)
    }

    /// World-space head pose (device anchor), or nil when not running / not available.
    func devicePose() -> simd_float4x4? {
        guard status == .running, let world = worldProvider else { return nil }
        guard case .running = world.state else { return nil }
        return world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
    }

    // MARK: Private

    private func teardown(finalStatus: Status) {
        generation &+= 1
        isStarting = false
        anchorTask?.cancel()
        anchorTask = nil
        eventTask?.cancel()
        eventTask = nil
        session?.stop()
        session = nil
        handProvider = nil
        worldProvider = nil
        status = finalStatus
        resetHands()
    }

    private func anchorStreamEnded(generation gen: UInt64) {
        guard gen == generation else { return }
        resetHands()
    }

    private func resetHands() {
        left = .untracked
        right = .untracked
        leftFistLatched = false
        rightFistLatched = false
        leftPalmLatched = false
        rightPalmLatched = false
        leftPalmOutput = false
        rightPalmOutput = false
        leftPalmPendingSince = nil
        rightPalmPendingSince = nil
    }

    private func handle(_ update: AnchorUpdate<HandAnchor>) {
        let anchor = update.anchor
        let isLeft = anchor.chirality == .left

        let newState: HandState
        if update.event == .removed {
            resetLatches(isLeft: isLeft)
            newState = .untracked
        } else {
            newState = makeState(from: anchor, isLeft: isLeft)
        }

        if isLeft {
            left = newState
        } else {
            right = newState
        }
    }

    private func resetLatches(isLeft: Bool) {
        if isLeft {
            leftFistLatched = false
            leftPalmLatched = false
            leftPalmOutput = false
            leftPalmPendingSince = nil
        } else {
            rightFistLatched = false
            rightPalmLatched = false
            rightPalmOutput = false
            rightPalmPendingSince = nil
        }
    }

    /// Minimum-hold debounce: the published value follows `raw` only after `raw` has disagreed
    /// with it continuously for `palmFacingMinHold` seconds.
    private func debouncedPalmFacing(raw: Bool, isLeft: Bool, now: CFTimeInterval) -> Bool {
        var output = isLeft ? leftPalmOutput : rightPalmOutput
        var pendingSince = isLeft ? leftPalmPendingSince : rightPalmPendingSince

        if raw == output {
            pendingSince = nil
        } else if let since = pendingSince {
            if now - since >= Self.palmFacingMinHold {
                output = raw
                pendingSince = nil
            }
        } else {
            pendingSince = now
        }

        if isLeft {
            leftPalmOutput = output
            leftPalmPendingSince = pendingSince
        } else {
            rightPalmOutput = output
            rightPalmPendingSince = pendingSince
        }
        return output
    }

    private func makeState(from anchor: HandAnchor, isLeft: Bool) -> HandState {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            resetLatches(isLeft: isLeft)
            return .untracked
        }

        let origin = anchor.originFromAnchorTransform

        func worldTransform(_ name: HandSkeleton.JointName) -> simd_float4x4 {
            origin * skeleton.joint(name).anchorFromJointTransform
        }
        func worldPosition(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            Self.translation(of: worldTransform(name))
        }

        let wristTransform = worldTransform(.wrist)
        let wrist = Self.translation(of: wristTransform)
        let middleKnuckle = worldPosition(.middleFingerKnuckle)
        let indexKnuckle = worldPosition(.indexFingerKnuckle)
        let littleKnuckle = worldPosition(.littleFingerKnuckle)

        // Palm centre: halfway between the wrist and the middle-finger knuckle.
        let palmCenter = (wrist + middleKnuckle) * 0.5

        // MARK: Fist (with hysteresis)
        let tips: [HandSkeleton.JointName] = [.indexFingerTip, .middleFingerTip, .ringFingerTip, .littleFingerTip]
        var maxTipDistance: Float = 0
        for tip in tips {
            maxTipDistance = max(maxTipDistance, simd_distance(worldPosition(tip), palmCenter))
        }

        var fist = isLeft ? leftFistLatched : rightFistLatched
        if fist {
            if maxTipDistance > Self.fistExitDistance { fist = false }   // any tip left the palm
        } else {
            if maxTipDistance < Self.fistEnterDistance { fist = true }   // all four tips at the palm
        }
        if isLeft { leftFistLatched = fist } else { rightFistLatched = fist }

        // MARK: Palm normal
        // a = wrist -> index knuckle, b = wrist -> little knuckle, n = a x b.
        //
        // RIGHT hand, palm down, fingers forward (-Z), thumb on the left (-X):
        //   a ~ (-0.02, 0, -0.09), b ~ (+0.03, 0, -0.08)
        //   n.y = a.z*b.x - a.x*b.z = (-0.09)(0.03) - (-0.02)(-0.08) = -0.0043  -> points DOWN = out of the palm. Keep.
        //
        // LEFT hand (mirror image), palm down, thumb on the right (+X):
        //   a ~ (+0.02, 0, -0.09), b ~ (-0.03, 0, -0.08)
        //   n.y = (-0.09)(-0.03) - (0.02)(-0.08) = +0.0043  -> points UP = out of the back of the hand. Flip.
        var palmNormal = simd_cross(indexKnuckle - wrist, littleKnuckle - wrist)
        if isLeft { palmNormal = -palmNormal }

        // MARK: Palm facing the user
        // 1) Hysteresis latch: enter > 0.55, exit < 0.35. If the alignment can't be measured this
        //    frame (no head pose, degenerate geometry) the latch keeps its previous value.
        // 2) Minimum-hold debounce on top, so the published value never flickers.
        var rawFacing = isLeft ? leftPalmLatched : rightPalmLatched
        let normalLength = simd_length(palmNormal)
        if normalLength > 1e-6, let pose = devicePose() {
            let head = Self.translation(of: pose)
            let toHead = head - palmCenter
            let distance = simd_length(toHead)
            if distance > 1e-4 {
                let alignment = simd_dot(palmNormal / normalLength, toHead / distance)
                if rawFacing {
                    if alignment < Self.palmFacingExit { rawFacing = false }
                } else {
                    if alignment > Self.palmFacingEnter { rawFacing = true }
                }
            }
        }
        if isLeft { leftPalmLatched = rawFacing } else { rightPalmLatched = rawFacing }
        let facing = debouncedPalmFacing(raw: rawFacing, isLeft: isLeft, now: CACurrentMediaTime())

        return HandState(
            isTracked: true,
            isFist: fist,
            palmFacingUser: facing,
            palmCenter: palmCenter,
            wristTransform: wristTransform
        )
    }

    private static func translation(of m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
}
