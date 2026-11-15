# Installing QVision on Apple Vision Pro from Windows ($0)

## Once only: pairing
1. Connect the PC and the Vision Pro to **the same Wi-Fi network**.
2. Run iloader:
   `C:\All Docs\06_Apple vision pro\tools\iloader-visionos\src-tauri\target\release\iloader.exe`
   - If Windows Firewall asks, choose **Allow** on private networks. It needs this to find the headset over mDNS.
3. On the headset: **Settings → General → Remote Devices**. The headset shows a 6-digit code.
4. In iloader, the Vision Pro appears in the device list. Select it and enter the code.
5. In iloader, sign in with **your Apple ID** (free). Only you type the password.

## Every new version
1. Get the IPA: `powershell -ExecutionPolicy Bypass -File scripts\fetch-build.ps1`
   It ends up in `qvision\dist\QVision-<commit>.ipa`.
2. In iloader: select the Vision Pro → **Import IPA** (sideload) → pick the file above.
3. On the headset, the first time only: **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.
   If it asks for **Developer Mode**: **Settings → Privacy & Security → Developer Mode → On** (the headset restarts).
4. Launch **QVision** from the Home View. It has its own icon.

## Rendered mode: PC library (v0.8, once)
1. As administrator: `powershell -ExecutionPolicy Bypass -File "C:\All Docs\06_Apple vision pro\qvision\tools\library-server\add-library-firewall.ps1"`. It adds the "QVision Library (TCP 8770)" rule (Private, LocalSubnet) to the "QVision CloudXR" group. Your Wi-Fi/Ethernet network must be set to **Private**.
2. Start **Desktop › Vision Pro › QVision Library (PC)** whenever you want to download scenes. It prints the address to type on the headset.
3. The first time QVision talks to the PC, visionOS asks to allow **Local Network**: allow it.

## Every 7 days
A free Apple ID's certificate expires after 7 days. The app stops opening, but its data stays.
To fix it: in iloader, sideload the same IPA again (or a newer one).

## Real-device test checklist (proof that it is NOT a simulator)
- [ ] The app icon (cube on a stage) appears in the headset's Home View.
- [ ] Opening it shows the "QVision" window, floating in the room.
- [ ] "Open stage" → the turquoise cube appears about 1.2 m in front of you, in your real room (passthrough).
- [ ] Pinching the cube and moving your hand moves it; two hands scale and rotate it.
- [ ] The floating "Stage" panel: Hide cube / Show cube / Reset scene work.
- [ ] Import a .usdz from iCloud Drive → Place → the model appears and casts a shadow on the floor.
- [ ] Settings → General → VPN & Device Management shows your Apple ID with the app.
