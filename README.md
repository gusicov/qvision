# QVision

A private, native visionOS app (SwiftUI + RealityKit) for importing 3D models and viewing them in your room on Apple Vision Pro, in the spirit of STAGEit. It has no accounts and no server.

## The $0 pipeline (Windows + Vision Pro, no Mac)

| Step | Where | Tool |
|---|---|---|
| Write code | Windows | any editor |
| Compile | GitHub Actions `macos-26` runner (free for public repos) | XcodeGen + xcodebuild → **unsigned .ipa** |
| Sign | Windows | iloader (Vision Pro branch) + free Apple ID (7-day cert) |
| Install | Windows → headset over Wi-Fi | iloader, RemotePairing tunnel |

Loop: edit → `git commit` → `scripts\fetch-build.ps1 -Push` → iloader → Import IPA → launch on the headset.

## Features (v0.1)
- Import `.usdz`, `.usd`, and `.reality` files from the Files app (iCloud Drive works well) into the app's own library.
- An immersive stage in mixed reality, with your room visible.
- Place models auto-fit (~60 cm, table height) or at real-world 1:1 scale on the floor.
- Pinch-drag to move, two-hand pinch to scale, two-hand twist to rotate. Pinch-tap to select.
- A demo cube, plus a floating stage panel (show/hide cube, reset scene, remove selected).
- Model animations play automatically, and models cast grounding shadows.

## Getting models in
Export USDZ from Blender (File › Export › Universal Scene Description, `.usdz`), SketchUp, Revit (via plugins), or Reality Composer. Put the file on iCloud Drive from Windows (iCloud for Windows or icloud.com). Then on the headset tap **Import** and pick it.

## Free Apple ID limits
- The signing certificate expires after **7 days**. Re-sign and reinstall with iloader.
- At most 3 sideloaded apps per device, and 10 App IDs per 7 days.
