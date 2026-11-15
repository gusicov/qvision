# QVision

A private, native visionOS app (SwiftUI + RealityKit + ARKit) for viewing 3D models in Apple Vision Pro, in the spirit of STAGEit Creator. It has no accounts and no server; everything stays on the headset.

## Features (v0.2)
- **All Projects**: a library of projects. Each project has its own models, layers, mode and environment, and is saved automatically.
- **One main panel** inside a project: mode, environment, fly mode, import, reset, objects, inspector, layers.
- **Mixed / Immersive**: your real room, or full isolation with a generated environment (Studio, Daylight, Sunset, Night).
- **Layers**: visibility and lock per layer, items per layer. Opened from the main panel or from your **left palm** (turn your palm toward your face, then tap "Layers").
- **Fly mode**: clench **both fists**, then move them in the direction you want to go (forward, back, sideways, up, down). Turn them like a steering wheel to rotate. Open a hand to stop. "Recenter" returns to the start.
- Gestures on objects: pinch + move = move, two hands = scale, two-hand twist = rotate, tap = select.
- **View / Edit / Inspect** modes: every project opens in **View** (models locked, so gaze and pinch always reach panels and the palm button); **Edit** moves, scales and rotates; **Inspect** shows details. While Fly mode is on, models are always locked.

## Three ways to view a model (v0.8)

| Home tab | What | Lighting | Runs on |
|---|---|---|---|
| **Projects** | arrange and edit any USDZ | real-time (IBL + shadows) | headset |
| **Rendered** | walk through one photoreal pre-lit scene | baked into the textures, shown unlit | headset, offline once downloaded |
| **Server** | Unreal stream via NVIDIA CloudXR | live on the PC | PC / office server |

### Rendered mode
A *Rendered package* is `<Name>.usdz` (Y-up, metres, final lit colour baked into the base-colour textures) plus an optional `<Name>.json` sidecar (`title`, `start.position` = floor point for your feet, `start.yawDegrees` = view direction, 0 = along -Z, 90 = along -X) and an optional `<Name>.jpg` thumbnail. QVision shows every material unlit with no extra lights, so what you see is exactly the bake, at 90 fps. Client models never go into this repo or the IPA: they stay on the PC in `assets\Rendered\` and are downloaded over the LAN.

**Start the QVision Library on the PC**
1. First time only, as administrator: `powershell -ExecutionPolicy Bypass -File tools\library-server\add-library-firewall.ps1` (Private profile, LocalSubnet, TCP 8770).
2. Double-click **Desktop › Vision Pro › QVision Library (PC)**. The window shows the PC's address (e.g. `192.168.0.87`) and logs every request. Keep it open while downloading.
   (It runs `tools\library-server\qvision_library.py`: Python 3 stdlib, port 8770, LAN clients only, serves `C:\All Docs\06_Apple vision pro\assets\Rendered`.)

**On the headset**
1. Home › **Rendered** › *On my PC*: the address comes from your saved "My PC" server (edit it if needed) → **Connect**.
2. **Download** (progress bar, Cancel). The scene moves to *On this Vision Pro* and works offline. A failed or cancelled download leaves nothing behind. Delete frees the space.
3. Tap the scene to open it (full immersion). You stand at the start position. Clench both fists to fly (1×–10×). Turn your **left palm** toward you for **Exit · Start · Speed**. Exit returns to Home › Rendered.
4. *Import from Files* takes a `.usdz` (select its `.json` and `.jpg` together with it) for packages that arrive another way.

Budget per scene: about 1.5 M triangles, at most eight 4096² atlases, USDZ up to about 500 MB.

## Supported 3D formats

| Format | Status | Notes |
|---|---|---|
| **.usdz** | ✅ recommended | Everything: geometry, PBR materials, textures and animations in a single file |
| **.usd / .usda / .usdc** | ✅ | Textures must be embedded or next to the file; prefer .usdz |
| **.reality** | ✅ | Exported from Reality Composer Pro |
| **.obj** | ⚠️ experimental | Converted to USDC on the headset (ModelIO); materials/textures may be lost |
| .fbx / .glb / .gltf / .ifc / .rvt / .skp / .3dm | ❌ for now | Convert to .usdz first (see below) |

### How to prepare models (USDZ)
- **Blender**: File › Export › Universal Scene Description, choose the `.usdz` extension. Tick *Materials* and set *Path Mode: Copy* (or *Pack Images*), then apply the transforms.
- **SketchUp**: export *USDZ* (SketchUp 2024+) or *glTF*, then convert (Reality Converter on a Mac, or Blender).
- **Revit / ArchiCAD**: export FBX/glTF → import into Blender → export USDZ. Twinmotion also exports USDZ.
- **Rhino 8**: export USDZ directly.
- **3ds Max / Cinema 4D**: USD exporter → USDZ.

### Recommendations (Vision Pro performance)
- Units in **meters**, model at real scale (the "1:1" option shows it in its true size).
- Up to roughly **500k–1M triangles** per scene for smooth movement; remove hidden interior geometry.
- **2K textures** (4K at most), PBR (Base Color, Roughness, Metallic, Normal).
- One `.usdz` per object or zone is better than one huge file.

### Large models (100 MB+)
- QVision is signed with **Increased Memory Limit** (iloader Vision Pro build, since v0.3), so large scenes have more memory available.
- Import reads through iCloud correctly (it waits for the full download) and shows progress.
- If a model still fails: reduce the textures (4K → 2K roughly halves memory), remove hidden/interior geometry, or split the model (structure, furniture, landscape) into several `.usdz` files and use **Layers**.

### Getting files onto the headset
Put the `.usdz` on **iCloud Drive** from Windows (iCloud for Windows or icloud.com). On the headset, open the project, tap **Import models**, then **iCloud Drive** › your file.

## The $0 pipeline (Windows + Vision Pro, no Mac)

| Step | Where | Tool |
|---|---|---|
| Code | Windows | any editor |
| Compile | GitHub Actions `macos-26` (free, public repo) | XcodeGen + xcodebuild → unsigned .ipa |
| Sign + install | Windows → headset over Wi-Fi | iloader (Vision Pro build, `tools/iloader-visionos`) + free Apple ID |

See `INSTALL.md` for the full steps and `docs/ARCHITECTURE.md` for the code structure.
