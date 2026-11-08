# QVision v0.2: architecture and module contracts

Written by the orchestrator. Every agent MUST implement exactly the public API listed for its module, because the other modules call it. Do not rename, re-type or remove anything in a contract. You may add private helpers and extra internal API.

## Product (target: STAGEit-like private viewer, no accounts, offline)
1. **Home = All Projects.** A grid of projects (name, date, object count) with New / Rename / Duplicate / Delete. Opening a project opens the 3D stage.
2. **Inside a project, one main panel (the app window)** is always there. It holds every control (mode, environment, fly, import, reset, hide/show, objects, inspector, layers). There is no second floating control panel.
3. **Two viewing modes:**
   - **Mixed**: passthrough, models in your real room.
   - **Immersive**: full immersion. You see only a generated environment (sky dome + ground) and the stage area.
4. **Layers panel opened from the hand.** Turning the LEFT palm toward your face shows a small "Layers" button on the palm. Tapping it toggles a floating Layers panel. The same layers UI is also reachable from the main panel.
5. **Fly mode (STAGEit-style).** When enabled, clench BOTH fists to start moving:
   - Push both fists forward/back/left/right/up/down from where you clenched to move in that direction. Speed is proportional to the distance (with a deadzone).
   - Rotate both fists around each other (like a steering wheel) to turn left/right.
   - Opening either hand stops. "Recenter" returns to the start.
6. Projects persist on device: `Documents/Projects/<uuid>/project.json` plus `Documents/Projects/<uuid>/Assets/*`.

## Platform constraints
- visionOS deployment target **2.0**, built with Xcode 26.x SDK. **Swift 5 language mode** (`SWIFT_VERSION 5.0`).
- Everything UI/RealityKit is `@MainActor`. Inside RealityKit closures that are not main-actor-annotated, use `MainActor.assumeIsolated { }`.
- `Scene` is ambiguous (SwiftUI vs RealityKit), so always write `SwiftUI.Scene` in App code.
- There is NO compiler available to agents. Write conservative, well-known API only. When unsure about an API, pick the simplest documented form, and add `if #available(visionOS 2.0, *)` where relevant.
- Free Apple ID signing: no special entitlements. Hand tracking needs only `NSHandsTrackingUsageDescription` (already in Info.plist).

## Files and owners

| File (App/Sources/…) | Owner |
|---|---|
| `QVisionApp.swift`, `Core/Models.swift` | orchestrator (done; read-only for agents) |
| `Core/AppModel.swift`, `Core/ProjectStore.swift`, `UI/RootView.swift`, `UI/ProjectsHomeView.swift`, `UI/ProjectWorkspaceView.swift`, `UI/LayersPanelView.swift` | **Agent 1 (projects + UI)** |
| `Stage/StageController.swift`, `Stage/StageView.swift`, `Stage/EnvironmentBuilder.swift`, `Stage/StageComponents.swift` | **Agent 2 (stage + environments + hand menu)** |
| `Input/HandTrackingService.swift`, `Input/FlyController.swift` | **Agent 3 (hands + fly)** |

The old files `AppModel.swift`, `ControlPanelView.swift`, `StageController.swift` and `StageView.swift` in `App/Sources/` (root) are deleted by the orchestrator. Do not recreate them there.

---
## Contract: Core/Models.swift (exists, orchestrator)
`ViewMode {mixed, full}`, `EnvironmentPreset {studio, daylight, sunset, night}`, `StoredTransform` (Codable, `init(_ Transform)`, `.transform`, `.identity`), `Layer`, `ProjectItem` (with `Primitive {cube}`), `Project` (with `static func new(name:)`, `defaultLayerID`). Read the file.

---
## Contract: Agent 1, `AppModel` (Core/AppModel.swift)
```swift
@MainActor @Observable final class AppModel {
    static let mainWindowID = "main"
    static let stageSpaceID = "stage"
    static let supportedTypes: [UTType]            // usdz, usd, realityFile, + UTType(filenameExtension: "obj")
    static let supportedExtensions: Set<String>    // usdz usd usda usdc reality obj

    enum StageState { case closed, transitioning, open }
    var stageState: StageState

    private(set) var projects: [Project]           // sorted by modifiedAt, newest first
    private(set) var currentProject: Project?      // nil = Home screen
    var selectedItemID: UUID?                       // didSet -> stage.setSelected
    var isLoading: Bool
    var lastError: String?
    var isLayersPanelVisible: Bool                  // toggled by hand menu + main panel

    var viewMode: ViewMode                          // computed: currentProject?.viewMode ?? .mixed; set saves + stage.setEnvironment
    var environment: EnvironmentPreset              // computed the same way
    var isFlyModeEnabled: Bool                      // stored; didSet -> fly.isEnabled

    @ObservationIgnored let stage: StageController
    @ObservationIgnored let hands: HandTrackingService
    @ObservationIgnored let fly: FlyController

    init()                                          // creates stage/hands/fly, loads projects

    // Projects
    @discardableResult func createProject(named name: String) -> Project
    func renameProject(_ id: UUID, to name: String)
    func duplicateProject(_ id: UUID)
    func deleteProject(_ id: UUID)
    func openProject(_ id: UUID) async               // sets currentProject, stage.load(...)
    func closeProject()                              // saves, stage.clear(), currentProject = nil

    // Items
    func importAssets(_ urls: [URL]) async           // copy into project Assets (OBJ -> USDC via ModelIO), place each
    func addTestCube() async
    func duplicateItem(_ id: UUID) async
    func removeItem(_ id: UUID)
    func setItemHidden(_ id: UUID, _ hidden: Bool)
    func moveItem(_ id: UUID, toLayer layerID: UUID)
    func itemTransformChanged(_ id: UUID, transform: Transform)   // called by gestures on end; persists
    func resetScene()                                // items -> initialTransform, recenter fly
    func recenter()                                  // fly.resetOffset(worldRoot: stage.worldRoot)
    func select(_ id: UUID?)
    func isItemLocked(_ id: UUID) -> Bool            // item's layer locked
    func assetURL(for item: ProjectItem) -> URL?

    // Layers
    func addLayer(named name: String)
    func renameLayer(_ id: UUID, to name: String)
    func deleteLayer(_ id: UUID)                     // never deletes the last layer; items move to first remaining
    func setLayerVisible(_ id: UUID, _ visible: Bool)
    func setLayerLocked(_ id: UUID, _ locked: Bool)
}
```
Every mutation updates `currentProject`, bumps `modifiedAt`, saves via ProjectStore (JSON, atomic), and pushes the change to `stage`.

## Contract: Agent 1, `LayersPanelView` (UI/LayersPanelView.swift)
`struct LayersPanelView: View { init(compact: Bool = false) }` reads `@Environment(AppModel.self)`. Agent 2 embeds it as a RealityView attachment (compact = true, ~420x560 pt, glass background). The main panel shows it with compact = false.

## Contract: Agent 1, `RootView` (UI/RootView.swift)
`struct RootView: View`. It shows ProjectsHomeView when `currentProject == nil`, otherwise ProjectWorkspaceView. RootView owns opening and dismissing the ImmersiveSpace: open it when a project opens, dismiss it when the project closes. It uses `openImmersiveSpace(id: AppModel.stageSpaceID)` and `dismissImmersiveSpace()`, keeping `stageState` in sync.

---
## Contract: Agent 2, `StageController` (Stage/StageController.swift)
```swift
@MainActor final class StageController {
    let root: Entity          // added once to RealityView content
    let worldRoot: Entity     // child of root. ALL project content + environment live under it. FlyController moves it.
    init()
    func load(project: Project, assetURL: (ProjectItem) -> URL?) async   // clear + build every item (sequential awaits ok), apply layers, environment
    func clear()
    /// Creates the entity. If `fit` is true (fresh import) it scales the model to ~0.6 m max extent, puts its pivot at
    /// bottom-centre and places it at `placement`, then returns the resulting transform (relative to worldRoot).
    /// If `fit` is false it applies item.transform and returns it.
    @discardableResult func addItem(_ item: ProjectItem, assetURL: URL?, fit: Bool, placement: SIMD3<Float>) async throws -> Transform
    func removeItem(_ id: UUID)
    func setTransform(_ id: UUID, _ transform: Transform)
    func apply(layers: [Layer], items: [ProjectItem])   // visibility = !item.isHidden && layer.isVisible ; locked -> no InputTargetComponent
    func setEnvironment(_ preset: EnvironmentPreset, mode: ViewMode)  // sky dome + ground only visible in .full
    func setSelected(_ id: UUID?)                        // subtle highlight (e.g. scaled outline-less: use HoverEffect + a small ring/bounds box)
    func entity(for id: UUID) -> Entity?
    /// Point ~1.5 m in front of the head at chest height, in worldRoot space; `slot` spreads items sideways.
    func placementPoint(devicePose: simd_float4x4?, slot: Int) -> SIMD3<Float>
}
```
Items are direct children of `worldRoot` (layers are logical only), so a transform is always relative to worldRoot. Each item root gets `ItemComponent(id: UUID)` (Stage/StageComponents.swift) plus a single bounding-box CollisionComponent, InputTargetComponent, HoverEffectComponent and GroundingShadowComponent on its meshes. `StageComponents.register()` registers custom components; QVisionApp calls it.

## Contract: Agent 2, `StageView` (Stage/StageView.swift)
`struct StageView: View`. It contains the RealityView: `content.add(model.stage.root)`, `content.add(model.fly.indicator)`, and the attachments (palm "Layers" button + floating `LayersPanelView(compact: true)`). It subscribes to `SceneEvents.Update`, and on every frame:
1. `model.fly.update(deltaTime:worldRoot: model.stage.worldRoot)`.
2. It places/shows the palm button only while `model.hands.left.isTracked && model.hands.left.palmFacingUser`, at `left.palmCenter`, offset ~6 cm off the palm toward the face.
3. It shows the layers panel when `model.isLayersPanelVisible` (placed once where the hand was when opened, billboarded).

Gestures: drag (move), magnify (scale), RotateGesture3D(y) and tap (select). They work on `ItemComponent` roots, are skipped if `model.isItemLocked(id)`, and call `model.itemTransformChanged(id, transform:)` in `onEnded`. `.task { await model.hands.start() }` runs on appear and `model.hands.stop()` on disappear.

## Contract: Agent 2, EnvironmentBuilder (Stage/EnvironmentBuilder.swift)
`enum EnvironmentBuilder { @MainActor static func make(_ preset: EnvironmentPreset) async -> Entity }`. It builds a procedural sky dome (inverted sphere with radius ~400 m and an UnlitMaterial gradient texture generated with CoreGraphics), a ground (a ~60 m disc or plane with a generated grid texture, at y = 0), and lighting (ImageBasedLight from the same gradient + DirectionalLight with shadows, with `#available` guards). There are no external assets.

---
## Contract: Agent 3, `HandTrackingService` (Input/HandTrackingService.swift)
```swift
struct HandState: Equatable {
    var isTracked: Bool
    var isFist: Bool                    // index+middle+ring+little curled (tips near palm), hysteresis
    var palmFacingUser: Bool            // palm normal points toward the head (needs device pose)
    var palmCenter: SIMD3<Float>        // world space
    var wristTransform: simd_float4x4   // world space
    static let untracked: HandState
}
@MainActor @Observable final class HandTrackingService {
    enum Status: Equatable { case idle, running, unsupported, denied, failed(String) }
    private(set) var status: Status
    @ObservationIgnored private(set) var left: HandState     // NOT observed (updated ~90 Hz); read per frame
    @ObservationIgnored private(set) var right: HandState
    init()
    func start() async      // ARKitSession: HandTrackingProvider + WorldTrackingProvider; idempotent
    func stop()
    func devicePose() -> simd_float4x4?   // WorldTrackingProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
}
```

## Contract: Agent 3, `FlyController` (Input/FlyController.swift)
```swift
@MainActor final class FlyController {
    init(hands: HandTrackingService)
    var isEnabled: Bool          // false -> stops immediately, hides indicator
    var speed: Float             // multiplier, default 1
    private(set) var isFlying: Bool
    let indicator: Entity        // small ring/arrow shown at the fists' midpoint while flying; managed internally
    func update(deltaTime: Float, worldRoot: Entity)
    func resetOffset(worldRoot: Entity)   // worldRoot.transform = .identity
}
```
Movement is applied by moving `worldRoot` the opposite way, so the user appears to move: translation, plus yaw rotation about the user's head position. There's no pitch or roll and no scaling. Apply smoothing (critically damped), a deadzone (~3 cm / ~5°) and a max speed.
