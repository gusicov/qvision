# QVision

A private, native visionOS app (SwiftUI + RealityKit + ARKit) for viewing 3D models in Apple Vision Pro, in the spirit of STAGEit Creator. It has no accounts and no server; everything stays on the headset.

## Features (v0.2)
- **All Projects**: a library of projects. Each project has its own models, layers, mode and environment, and is saved automatically.
- **One main panel** inside a project: mode, environment, fly mode, import, reset, objects, inspector, layers.
- **Mixed / Immersive**: your real room, or full isolation with a generated environment (Studio, Daylight, Sunset, Night).
- **Layers**: visibility and lock per layer, items per layer. Opened from the main panel or from your **left palm** (turn your palm toward your face, then tap "Layers").
- **Fly mode**: clench **both fists**, then move them in the direction you want to go (forward, back, sideways, up, down). Turn them like a steering wheel to rotate. Open a hand to stop. "Recenter" returns to the start.
- Gestures on objects: pinch + move = move, two hands = scale, two-hand twist = rotate, tap = select.

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

### Getting files onto the headset
Put the `.usdz` on **iCloud Drive** from Windows (iCloud for Windows or icloud.com). On the headset, open the project, tap **Import models**, then **iCloud Drive** › your file.

## The $0 pipeline (Windows + Vision Pro, no Mac)

| Step | Where | Tool |
|---|---|---|
| Code | Windows | any editor |
| Compile | GitHub Actions `macos-26` (free, public repo) | XcodeGen + xcodebuild → unsigned .ipa |
| Sign + install | Windows → headset over Wi-Fi | iloader (Vision Pro build, `tools/iloader-visionos`) + free Apple ID |

See `INSTALL.md` for the full steps and `docs/ARCHITECTURE.md` for the code structure.
