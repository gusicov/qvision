# Agent 2: Stage, mixed/immersive modes, environments, hand menu

**Role:** You are a senior RealityKit / visionOS spatial engineer. You've shipped immersive apps (ImmersiveSpace, RealityView attachments, entity gestures, IBL lighting, procedural meshes and textures) and know how STAGEit Creator presents scenes: objects you grab directly, sky domes, a ground, and an immersive "isolated" mode.

**Repository:** `C:\All Docs\06_Apple vision pro\qvision`. First read `docs/ARCHITECTURE.md` (the binding contract), `App/Sources/Core/Models.swift` and `App/Sources/QVisionApp.swift`. Other agents are writing AppModel, LayersPanelView, HandTrackingService and FlyController right now. Call them exactly as the contract says.

**You own ONLY these files (create them):**
- `App/Sources/Stage/StageComponents.swift`: `struct ItemComponent: Component { var id: UUID }` and `enum StageComponents { static func register() }`.
- `App/Sources/Stage/StageController.swift`: the full contract.
- `App/Sources/Stage/StageView.swift`: the full contract.
- `App/Sources/Stage/EnvironmentBuilder.swift`: the full contract.

Do not touch any other file.

## Requirements
**StageController**
- `root` → `worldRoot` → { `environmentRoot`, item entities }.
- Loading an asset: `try await Entity(contentsOf: url)`, wrapped in an item root `Entity`. The primitive cube is `ModelEntity(mesh: .generateBox(size: 0.3, cornerRadius: 0.03), materials: [SimpleMaterial(color: .systemTeal, roughness: 0.35, isMetallic: false)])`.
- Fit logic for `fit == true`, using `visualBounds(relativeTo:)`:
  - scale so the max extent is 0.6 m;
  - pivot at the bottom centre (offset the child, not the root);
  - root at `placement`.
- Collision: a single box from the root's bounds (minimum 2 cm per axis), set AFTER fitting, in root space. Also add InputTargetComponent, HoverEffectComponent, `ItemComponent(id:)`, and GroundingShadowComponent(castsShadow: true) on every descendant that has a ModelComponent. Play `availableAnimations` on repeat.
- Keep `[UUID: Entity]`. `apply(layers:items:)` sets `isEnabled` from visibility, and removes or adds InputTargetComponent for locked layers.
- `setSelected`: show a thin wireframe-like bounds indicator. A simple approach: 12 thin box edges (UnlitMaterial, white, alpha 0.8), built from the bounds in the item's root space and parented to the item, named "selection". Remove it from the previous selection.
- `placementPoint(devicePose:slot:)`:
  - If a pose is given: forward = -Z column of the pose, flattened to XZ and normalised; point = head + forward·1.5 m, y = head.y − 0.35, plus sideways (slot % 3 − 1)·0.7 m. Convert world → worldRoot space with `worldRoot.convert(position:from: nil)`.
  - With no pose: (−0.7…0.7, 1.0, −1.5) in worldRoot space.
- `setEnvironment(preset, mode)`: build lazily (cache per preset) via `EnvironmentBuilder.make`. Enable it only when `mode == .full`; in `.mixed` nothing extra is shown. Because it's async, use a Task and guard against races with a generation counter.

**EnvironmentBuilder**
- **Sky dome**: `MeshResource.generateSphere(radius: 400)` with scale `[-1, 1, 1]` (so it's visible from inside) and an `UnlitMaterial` whose `color.texture` is a vertical-gradient CGImage (e.g. 16×512) made with a CoreGraphics `CGContext`. Create the texture with `try await TextureResource(image: cg, options: .init(semantic: .color))`. If that throws, fall back to a solid UnlitMaterial colour.
- **Ground**: `MeshResource.generatePlane(width: 80, depth: 80)` at y = 0, with a generated grid texture (1024², lines every 1 m look). Use `PhysicallyBasedMaterial` or `UnlitMaterial` with tiling via `textureCoordinateTransform` if available; otherwise skip tiling.
- **Lighting**: `ImageBasedLightComponent(source: .single(env))` + `ImageBasedLightReceiverComponent(imageBasedLight:)` on worldRoot. The env is created from an equirect gradient CGImage via `try await EnvironmentResource(equirectangular: cg)` inside `if #available(visionOS 2.0, *)` and do/catch. Also add a `DirectionalLight`-style entity with `DirectionalLightComponent(color:intensity:)` + `DirectionalLightComponent.Shadow()`, inside `#available(visionOS 2.0, *)`.
- **Presets** (top→horizon colours, ground tint, light intensity):
  - studio: neutral greys
  - daylight: blue sky, pale horizon
  - sunset: deep blue → orange
  - night: navy → dark, dim light

**StageView**
- `RealityView { content, attachments in … } update: { … } attachments: { … }`.
- In make:
  - `content.add(model.stage.root)` and `content.add(model.fly.indicator)`.
  - Fetch the attachment entities for "palmMenu" and "layersPanel". Add them to content, give the layers panel a `BillboardComponent()`, and start them disabled.
  - Subscribe `content.subscribe(to: SceneEvents.Update.self) { event in MainActor.assumeIsolated { … } }` and keep the returned `EventSubscription` in `@State`.
- Per frame:
  1. Call fly.update.
  2. Palm menu: shown when `model.hands.left.isTracked && model.hands.left.palmFacingUser`. Position it at `palmCenter + normalize(head − palmCenter)·0.06`, where head = `model.hands.devicePose()` translation (if nil, keep it hidden). Orient it to face the head, e.g. a `look(at:from:relativeTo:)` variant or a BillboardComponent.
  3. Layers panel: when `model.isLayersPanelVisible` turns true, place it once ~0.45 m in front of the head, slightly left and at eye height. Show it while true and hide it when false.
- Attachments:
  - "palmMenu": a small capsule button "Layers" (square.3.layers.3d) that toggles `model.isLayersPanelVisible`.
  - "layersPanel": `LayersPanelView(compact: true).environment(model)`.
- Gestures on `.targetedToAnyEntity()`, resolving the item root by walking parents until one has ItemComponent:
  - DragGesture: move using scene-space conversions. On first change remember the start location (`value.convert(value.startLocation3D, from: .local, to: .scene)`) and the entity's world position; then `setPosition(startPos + (current − startLoc), relativeTo: nil)`.
  - MagnifyGesture: scale from the start scale, clamped 0.01…100.
  - RotateGesture3D(constrainedToAxis: .y): convert `value.rotation.quaternion` (simd_quatd) to simd_quatf component-wise and set `orientation = delta * start`.
  - TapGesture: `model.select(id)`; tapping empty space can't be detected, so leave that.
  - Use `.simultaneousGesture` for magnify, rotate and tap.
  - Skip locked items.
  - In every `onEnded`, call `model.itemTransformChanged(id, transform: root.transform)` and clear the start state, kept in a `@State` final class.
- `.task { await model.hands.start() }` and `.onDisappear { model.hands.stop() }`.

## Rules
- Swift 5 mode. Use `SwiftUI.` or `RealityKit.` prefixes where names clash (`Scene`). UIColor is available on visionOS.
- visionOS 2.0 APIs; wrap anything newer in `#available`.
- No compiler is available, so be precise and conservative, and prefer APIs you are sure exist.
- When finished, reply with: the files created, extra public symbols, and any API you were unsure about, with your fallback.
