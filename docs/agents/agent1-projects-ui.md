# Agent 1: Projects, persistence and the main panel UI

**Role:** You are a senior visionOS product engineer (SwiftUI on visionOS, glass UI, ornaments, NavigationStack) who knows STAGEit Creator's UX well. In STAGEit, a project library is the home, and inside a project one clean control panel drives everything.

**Repository:** `C:\All Docs\06_Apple vision pro\qvision`. First read `docs/ARCHITECTURE.md` (the binding contract), `App/Sources/Core/Models.swift` and `App/Sources/QVisionApp.swift`. Use the contracts there for `StageController`, `HandTrackingService`, `FlyController` and `ItemComponent`. Other agents are writing those right now, so call them exactly as specified.

**You own ONLY these files (create them):**
- `App/Sources/Core/AppModel.swift`: implement the full AppModel contract.
- `App/Sources/Core/ProjectStore.swift`: disk persistence.
- `App/Sources/UI/RootView.swift`
- `App/Sources/UI/ProjectsHomeView.swift`
- `App/Sources/UI/ProjectWorkspaceView.swift`
- `App/Sources/UI/LayersPanelView.swift`

Do not touch any other file.

## Requirements
**ProjectStore** (a plain final class or struct, used by AppModel)
- Root: `Documents/Projects/`. Each project lives in `<uuid>/project.json` (JSONEncoder, ISO8601 dates, `.atomic` write) with an `Assets/` subfolder.
- `loadAll() -> [Project]`, `save(_:)`, `delete(id:)`, `duplicate(_:) -> Project` (copies the folder, new id and name "… copy", new item ids are fine), `assetsFolder(for:) -> URL`.
- `importAsset(from url: URL, into project: Project) throws -> String` returns the stored file name:
  - Handle security-scoped access.
  - Avoid name collisions by appending -2, -3 and so on.
  - `.obj` files are converted with ModelIO: `MDLAsset(url:)` then `asset.export(to: <name>.usdc)`. Check `MDLAsset.canExportFileExtension("usdc")` first and throw a clear error if it can't. Keep the original `.obj` next to it too.

**AppModel**: implement exactly the contract.
- `init()` creates `StageController()`, `HandTrackingService()` and `FlyController(hands:)`, then loads projects.
- Mutations go through one private helper, `mutate(_ body: (inout Project) -> Void)`. It applies the change to `currentProject`, bumps `modifiedAt`, saves, and refreshes `projects`.
- `openProject` sets `currentProject` and `selectedItemID = nil`, then calls `await stage.load(project:assetURL:)` and `stage.setEnvironment(project.environment, mode: project.viewMode)`.
- `importAssets`: for each URL, store the asset, then create a `ProjectItem` (name = file name without extension, layer = `defaultLayerID`). Then call `let t = try await stage.addItem(item, assetURL:, fit: true, placement: stage.placementPoint(devicePose: hands.devicePose(), slot: index))`. Set the item's `transform` and `initialTransform` to `StoredTransform(t)` and append it. Errors go to `lastError`, and `isLoading` is true while working.
- `addTestCube` works the same way with `primitive: .cube` and no asset.
- `duplicateItem` makes a new id, offsets the copy by +0.3 m in x, and passes `fit: false`.
- `itemTransformChanged` updates the item's transform and saves.
- `resetScene` sets each item's `transform = initialTransform`, calls `stage.setTransform`, then `recenter()`.
- Layer operations update the project, then call `stage.apply(layers:items:)`.
- `viewMode` and `environment` setters: if no project is open, ignore. Otherwise mutate and call `stage.setEnvironment`.
- `isFlyModeEnabled` didSet sets `fly.isEnabled = isFlyModeEnabled`.
- `closeProject` sets `isFlyModeEnabled = false` and `isLayersPanelVisible = false`, then `stage.clear()` and `currentProject = nil`.

**RootView**
- Switches between Home and Workspace.
- Watches `model.currentProject?.id` with `.onChange`. When a project opens and the stage isn't open, it opens the ImmersiveSpace. When `currentProject` becomes nil it dismisses it.
- If `openImmersiveSpace` doesn't return `.opened`, set `stageState = .closed` and `lastError`.
- Show a single global `.alert` for `lastError` and a loading overlay.

**ProjectsHomeView ("All Projects")**
- A large title, then an adaptive `LazyVGrid` of project cards. Each card has a glass/material background, a cube-stack SF Symbol, the name, the relative modified date and an "N objects" count.
- Tapping a card opens it (`await model.openProject`). A context menu offers Rename (alert with TextField), Duplicate and Delete (confirmationDialog).
- A prominent "New Project" button (alert with TextField, default "Project N") creates the project and opens it.
- An empty state explains what QVision is in one line.

**ProjectWorkspaceView (the one main panel inside a project)**, top to bottom:
1. **Header**: a back button "All Projects" (calls `closeProject`), the project name, and the object count.
2. **View**: a segmented Picker Mixed / Immersive bound to `model.viewMode`. When Immersive is selected, an Environment picker (Studio/Daylight/Sunset/Night) bound to `model.environment` appears.
3. **Navigate**:
   - A "Fly mode" Toggle bound to `isFlyModeEnabled`, with a 1-line hint: "Clench both fists, then push to move, twist to turn. Open a hand to stop."
   - If `model.hands.status` is `.denied`, `.unsupported` or `.failed`, show a warning line.
   - A "Recenter" button.
4. **Scene**: buttons "Import models" (`.fileImporter`, multiple, `AppModel.supportedTypes`), "Add test cube", "Reset scene", and "Layers…" (toggles `isLayersPanelVisible`).
5. **Objects**: a List of items. Each row has the name, a layer badge, an eye button (`setItemHidden`) and a selection highlight. Tap selects. Swipe or context menu offers Duplicate, Move to layer ▸ (menu of layers) and Delete.
6. **Inspector** (when an item is selected): the name, Hide/Show, Duplicate and Delete.
- Keep everything on one scrollable panel; no extra floating panels. Use `.glassBackgroundEffect()` where it fits and visionOS-sized hit targets.

**LayersPanelView(compact:)**
- Each layer row has a visibility eye, a lock, a name (rename via context menu) and its item count.
- Expanding a layer (DisclosureGroup) lists its items. Tap selects, and an eye toggles hidden.
- "+ New Layer" button. Delete via context menu (disabled when only 1 layer).
- In compact mode, add a header "Layers" with a close (xmark) button that sets `isLayersPanelVisible = false`.

## Rules
- Swift 5 mode, `@MainActor` on the model, `@Observable` with `@Bindable` where bindings are needed: `@Bindable var model = model` inside body, or `Binding(get:set:)`.
- visionOS 2.0 APIs only. Import UniformTypeIdentifiers and ModelIO where used.
- No compiler is available, so be precise and conservative. Avoid exotic modifiers.
- When finished, reply with: the files created, every public symbol you added beyond the contract, and any API you were unsure about.
