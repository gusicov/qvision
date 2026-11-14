# QVision Server mode: test plan (PC first, then the office VM)

QVision's **Server** tab is a NVIDIA CloudXR client (CloudXRKit **6.2.0**, pinned). The server runs the **CloudXR Runtime** plus an OpenXR app (a test app first, then Unreal). **Client and Runtime versions must match** (NVIDIA FAQ), so use Runtime **6.2.x**.

## Status (2026-11-14)
- ✅ PC prepared: `tools/cloudxr-lovr-sample` built with CloudXR Runtime **6.2.0**. A smoke run shows the service created and listening on TCP 48010.
- ✅ Windows Firewall group **"QVision CloudXR"**: TCP 48010, plus UDP 47998, 47999, 48000, 48002, 48005, 48008 and 48012, Private profile, LocalSubnet only. Remove it with `Get-NetFirewallRule -Group "QVision CloudXR" | Remove-NetFirewallRule`.
- ✅ Desktop shortcut **"CloudXR Test Server"** (`tools/cloudxr-lovr-sample/run-qvision.cmd`; it clears `NoDefaultCurrentDirectoryInExePath` so `run.bat` can find lovr.exe).
- ⏳ Next: install QVision 0.5 on the headset → Server → My PC `192.168.0.87` → Connect.

## Phase 1: Home PC smoke test (no Unreal yet)
Goal: prove that the headset ↔ PC stream works with NVIDIA's tiny OpenXR test app (LÖVR).

| On the PC | Notes |
|---|---|
| CloudXR Runtime 6.2 (`CloudXR-6.2.x-Win64-sdk.zip`) | NVIDIA NGC → CloudXR → File Browser. Sign-in listed as optional. |
| `NVIDIA/cloudxr-lovr-sample` | GitHub. Copy the Runtime zip into the folder. |
| Visual Studio 2022+ with C++ and CMake | Already installed (VS Community 2026, C++ tools). |
| `build.bat`, then `run.bat` | Run from a Developer PowerShell. |
| Windows Firewall | Allow the runtime/sample on **Private** networks (NVIDIA's quick start temporarily disables the firewall; we'll add a rule instead). |
| PC IP | Currently `192.168.0.87` (Ethernet). |

**On the headset:** QVision → **Server** tab → Add server (`My PC`, `192.168.0.87`) → Connect. Expect the stream to open, with blue cubes following your finger joints (LÖVR sample).

## Phase 2: Unreal on the PC
- NVIDIA's Unreal guide targets **UE 5.5 + OpenXR plugin** and adds a small C++ plugin (runtime management + data channel). It points UE's OpenXR loader at CloudXR with `XR_RUNTIME_JSON=<path>\openxr_cloudxr.json`.
- Alternative to evaluate: **Stream Manager** (Windows service from NGC) to manage Runtime instances, so packaged UE builds don't need custom code.
- Content: 3ds Max (Corona) → Datasmith → UE 5.5 (Collab Viewer AEC template for multi-user later).
- GPU: RTX 3070 8 GB. Fine for testing; keep scenes light.

## Phase 3: Office VM (Blackwell, 96 GB)
Ask IT:
1. Windows 11 / Server or Linux? Is the GPU passthrough or vGPU (not a virtual display adapter)?
2. Can CloudXR + Unreal run as a service or with Stream Manager, so they don't depend on an RDP session being connected?
3. Can the Wi-Fi reach the VM on the CloudXR ports? (Check NVIDIA's "Network Setup" page for the exact list; the default stream port is in the 48010 / 55000 family.)
4. Two concurrent sessions (two headsets) → two Runtime + UE instances (Stream Manager), each on its own port.

In QVision, only the server address changes (add a second server entry: `Office`).
