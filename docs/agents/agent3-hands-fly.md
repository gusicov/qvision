# Agent 3: Hand tracking + STAGEit-style fly mode

**Role:** You are a senior visionOS ARKit / interaction engineer. You specialise in hand-tracking locomotion, comfort (vection, acceleration limits) and gesture recognition with HandTrackingProvider. You've studied STAGEit Creator's fly mode: clench both fists to grab, then push or pull and twist to fly through the scene.

**Repository:** `C:\All Docs\06_Apple vision pro\qvision`. First read `docs/ARCHITECTURE.md` (the binding contract) and `App/Sources/Core/Models.swift`. Other agents call your types exactly as specified there.

**You own ONLY these files (create them):**
- `App/Sources/Input/HandTrackingService.swift`
- `App/Sources/Input/FlyController.swift`

Do not touch any other file.

## HandTrackingService
- `import ARKit`, `import QuartzCore`. One `ARKitSession`, a `HandTrackingProvider()` and a `WorldTrackingProvider()`.
- `start()`:
  - If already running, return.
  - Check `HandTrackingProvider.isSupported`; if not, set status = .unsupported.
  - `let auth = await session.requestAuthorization(for: [.handTracking])`; if denied, set status = .denied.
  - `try await session.run([hands, world])`, then spawn a `Task` consuming `hands.anchorUpdates`. Use `for await update in …`, and for each update read `update.anchor` (HandAnchor) and update `left` or `right` according to `anchor.chirality`.
  - Catch errors and set `.failed(msg)`.
- `stop()`: cancel the task, `session.stop()`, status = .idle, and set both hands to `.untracked`. A new session/providers instance is needed after stop, because providers can't be re-run. Recreate them in `start()`.
- **Per anchor:**
  - Get `origin = anchor.originFromAnchorTransform`. If `!anchor.isTracked` or the skeleton is nil, mark the hand untracked.
  - Joint world transform = `origin * skeleton.joint(name).anchorFromJointTransform`.
  - `palmCenter` = the average of the wrist and middleFingerMetacarpal/Knuckle positions. Use joint names that exist: `.wrist`, `.middleFingerKnuckle`, `.indexFingerKnuckle`, `.littleFingerKnuckle`, `.indexFingerTip`, `.middleFingerTip`, `.ringFingerTip`, `.littleFingerTip`.
  - **Fist**: for each of the index, middle, ring and little fingers, the tip-to-palmCenter distance must be < 0.075 m. Use hysteresis: enter below 0.075, exit above 0.095.
  - **Palm normal**: the cross product of (indexKnuckle − wrist) and (littleKnuckle − wrist). Flip the sign by chirality so it points out of the palm; verify the sign logic with comments for both hands, because left/right mirror.
  - `palmFacingUser` = dot(palmNormal, normalize(head − palmCenter)) > 0.6, with head from `devicePose()`. If there's no pose, it's false.
- `devicePose()`: `world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform`, returning nil when not running.
- `left` and `right` are `@ObservationIgnored`. Only `status` is observed.

## FlyController (STAGEit-style)
- **Engage**: when `isEnabled` and both hands are tracked AND both fists are held, start a grab. Record:
  - the midpoint M0 of the two palmCenters;
  - the yaw of the vector right→left (atan2 of x,z) as θ0;
  - the head position H.
- **While held**, each frame:
  - `d = M − M0` (world). Deadzone 0.03 m on the length: `d' = d * max(0, |d| − 0.03)/|d|`.
  - Target velocity `v = d' * gain` (gain ≈ 4 /s × speed), then clamp |v| ≤ 3 m/s × speed. The direction is exactly where the fists moved: forward = forward, up = up.
  - Yaw rate: `Δθ = wrap(θ − θ0)`, with a deadzone of 5°, giving `ω = Δθ' * 1.5 rad/s` (clamp ±1.2).
  - Smooth with exponential damping: `vel += (v − vel)·(1 − exp(−dt·8))`, and the same for ω. When released, decay to 0 using the same damping, so stopping isn't abrupt.
  - **Apply to worldRoot (the world moves the opposite way):**
    - translation: `worldRoot.position -= vel·dt`. The position is in root space; root is identity so world space works.
    - yaw: rotate worldRoot about the vertical axis through the CURRENT head position H: `p' = R(−ω·dt)·(p − H) + H` and `orientation = R(−ω·dt) * orientation`.
- **Indicator**:
  - A small ring: a thin torus is not available as a mesh, so use a flat cylinder ring `generateCylinder(height: 0.004, radius: 0.05)` with an UnlitMaterial in cyan at alpha ~0.6, plus a smaller arrow/cone (`generateCone` is visionOS 2: `MeshResource.generateCone(height:radius:)` in `#available`, otherwise a box) pointing along vel.
  - Show it at M0 while flying and hide it otherwise.
  - `indicator` is a top-level Entity that StageView adds to content.
- `isEnabled = false` cancels the grab, zeroes the velocities and hides the indicator.
- `resetOffset(worldRoot:)` sets `worldRoot.transform = .identity` and zeroes the velocities.
- `deltaTime` is clamped to ≤ 0.05.

## Rules
- Swift 5 mode, `@MainActor` classes. HandAnchor is Sendable; hop to the main actor when writing state, since the class is `@MainActor` and the Task inherits it.
- visionOS 2.0 APIs; `#available` for anything newer. No compiler is available, so be precise.
- When finished, reply with: the files created, extra public symbols, and any API you were unsure about, with your fallback.
