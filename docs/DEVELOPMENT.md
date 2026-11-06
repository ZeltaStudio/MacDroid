# MacDroid 0.2.2 — Android files in Finder

A native SwiftUI Mac app that exposes Android shared storage in Finder through a local WebDAV bridge backed by ADB. Nothing is installed on Android. Requires macOS 13+ and Android 11+ for cable-free pairing. An authorized USB debugging connection also works.

## Use

Open `dist/MacDroid.app`. This development build includes Google's ADB executable and notices. It is ad-hoc signed, not notarized for distribution.

**Wi-Fi:** Enable Developer options → Wireless debugging on Android. Choose Pair device with pairing code and enter its address and six-digit code in MacDroid. After pairing, use the different connection IP:port from the main Wireless debugging screen. Click Connect, select the phone, then Open Android in Finder.

**USB:** Enable USB debugging, connect a data-capable USB cable, and approve the debugging prompt. Select the USB entry, then Open Android in Finder.

Keep MacDroid running while using the mounted volume. The menu bar icon stays available even when the main window is closed. Use Eject before disconnecting; wait for transfers or cancel them first.

## New in 0.2

1. **Automatic reconnect.** Every five seconds, MacDroid looks for authorized devices, discovers remembered phones through ADB mDNS, and retries a saved Wi-Fi address if necessary. A physical device identity keeps a mounted volume attached to the same phone when an address changes or another transport becomes available. A working transport stays selected; USB is preferred when a replacement connection is needed. The bridge waits up to 20 seconds for a missing phone during an operation. Interrupted file transfers fail rather than being silently replayed. Refresh the Finder folder after reconnection if macOS cached an error. Explicit Eject (including Finder eject) stops remounting. Normal Quit remembers the last mounted phone for the next launch when reconnect is enabled.
2. **Readable device names.** The device picker and menu show the phone's reported marketing name/model and a USB or Wi-Fi label. The mounted volume uses the phone name; transport changes appear in the app's status.
3. **Transfer progress and cancellation.** Finder GET/PUT operations are tracked, including receiving uploads, ADB reads/writes, and delivery to Finder. The app shows bytes, stage progress, speed, and an estimated remaining time for the current stage. Cancel terminates the ADB transfer or local HTTP connection. Uploads are staged before replacement; cancelled staging uploads are removed when the phone is reachable. Finder may display an error or offer to retry. These are per-stage estimates, not whole-folder estimates. Finder background reads and metadata writes may also appear in the list. Recently completed transfers can be cleared.
4. **Recoverable deletion.** Finder DELETE moves files/folders into `/.MacDroid Recovery/` on shared storage, along with their original location and deletion time. Open Recovery in the app or menu bar to restore. Restore never overwrites an existing item and requires the original parent folder to exist. The recovery folder is protected against modification through this bridge. There is no automatic expiry or permanent-empty command yet: recovered files continue using phone storage. File replacements are not versioned/backed up, and deletions made outside MacDroid are not intercepted.
5. **Menu bar controls.** Mount an available phone, connect the saved Wi-Fi address, open Finder, access Recovery, mirror the screen, eject, toggle reconnect, or reopen the main window. Quit first ejects the volume and stops mirroring; active operations must finish or be cancelled.
6. **Screen mirroring.** Mirror screen launches scrcpy with the selected phone’s serial and this app’s ADB. The scrcpy window shows the display and accepts keyboard and pointer control. The executable is the bundled copy, a saved path, or a Homebrew, MacPorts, `/usr/local`, or `~/bin` install. The server jar is passed through `SCRCPY_SERVER_PATH` when it sits next to that executable or in the Homebrew prefix. A missing tool produces an explanation instead of a failed launch. Finder mounting does not require scrcpy.
7. **Storage capacity.** Used/free space appears in the main window and free space in the menu. It refreshes about every 30 seconds while connected. Finder’s own free-space display may remain unavailable; use the app’s indicator.

## Architecture and limits

- Shared storage (`/sdcard`) only. Android permission restrictions still apply; private app data is not exposed.
- Built-in macOS WebDAV mounting; no FUSE driver or system extension. The listener binds only to 127.0.0.1 and uses a random URL per session, so it is not exposed to the Wi-Fi network. ADB manages pairing keys.
- Uploads and downloads are disk-backed. Downloads are staged on the Mac before delivery to Finder, so temporary space for a complete file is needed.
- ADB file operations are serialized. Large folders can be slow, and Finder can cache directory contents. Automatic reconnect does not resume partially completed transfers.
- No support yet for arbitrary extended attributes, macOS timestamp preservation, server-side COPY, recursive directory locks, or PROPPATCH. Finder may create `.DS_Store` and `._` metadata files on the phone. Existing directories cannot be replaced by MOVE.
- File names must be valid on Android's filesystem. Storage figures cover shared internal storage, not a separately selectable SD card.
- Wireless discovery requires a network that permits device-to-device communication/mDNS; manual IP:port entry remains available. Revoked Android authorizations require pairing again.

## Build

Only the macOS Command Line Tools are needed:

```sh
swift build
./scripts/build-app.sh debug
# Optimized build:
./scripts/build-app.sh release
```

The build script packages into a fresh staging directory before replacing the app, avoiding modification of a running signed executable. It embeds ADB when `.build/downloads/platform-tools/adb` exists; otherwise use an installed copy via Select adb. Common Android SDK and Homebrew locations are detected. It embeds scrcpy when `.build/downloads/scrcpy/scrcpy` exists, plus `scrcpy-server` from that directory when present.

Official Google tools used for the local build:
https://dl.google.com/android/repository/platform-tools-latest-darwin.zip

ADB documentation: https://developer.android.com/tools/adb

## Image-reading regression checks

Version 0.2.2 adds HTTP single-byte-range support (closed, open-ended, and suffix ranges), cache validators, and graceful response completion. Staged downloads must match the advertised file size before being sent. Image checks reconstruct a generated JPEG from out-of-order ranges and compare actual mounted-phone reads against a direct ADB copy. Test images contain generated noise, not user photos.

```sh
MACDROID_CHECK_FILTER='image' swift run MacDroidCheck
```

## Checks

The standalone check executable runs without XCTest or full Xcode:

```sh
swift run MacDroidCheck
# Include a real macOS WebDAV mount against disposable local files:
MACDROID_TEST_MOUNT=1 swift run MacDroidCheck
# Include an already-authorized physical phone:
MACDROID_ADB_PATH=/absolute/path/to/adb MACDROID_TEST_SERIAL=your-device-serial swift run MacDroidCheck
```

Checks cover reconnect selection/phone identity isolation, transport labels, scrcpy launch arguments and tool detection, cancellation of subprocesses and HTTP uploads, byte progress, recoverable deletion and restoration, restore conflicts, storage parsing, file lifecycle, locks, overwrites, traversal, foreign destinations, binary and chunked transfers, macOS filesystem mounting, and real Android transfer/recovery operations.

Physical-phone checks create a dedicated `/sdcard/Download/.macdroid-check-UUID` folder. Test files and their recovery records are cleaned up. Existing user files are not changed.

For protocol debugging, launch with `MACDROID_DAV_TRACE=1`. Traces include file paths and the local session URL; don't publish them.

## Source

- `Sources/MacDroid/App.swift`: SwiftUI window, menu bar, connection/mount lifecycle, recovery and transfer views.
- `Sources/MacDroidCore/Devices.swift`: discovery, identity-based transport selection, reconnecting backend.
- `Sources/MacDroidCore/Transfers.swift`: progress state, transfer history, cancellation tokens.
- `Sources/MacDroidCore/Recovery.swift`: protected recovery storage, manifests, restoration.
- `Sources/MacDroidCore/Storage.swift`: validated capacity parsing.
- `Sources/MacDroidCore/ADB.swift`: command execution, shell quoting, Android file operations.
- `Sources/MacDroidCore/ScreenMirror.swift`: scrcpy detection, server-jar lookup, and the launch command for the selected phone.
- `Sources/MacDroidCore/WebDAV.swift`: local server, disk-backed transport, Finder protocol.
- `Tests/MacDroidCoreTests/`: executable checks and disposable backends.

## Installable disk image

```sh
./scripts/build-app.sh release
./scripts/package-dmg.sh
# Optional destination folder:
./scripts/package-dmg.sh /absolute/output/directory
```

The DMG contains MacDroid.app, an Applications shortcut, and installation instructions. It includes ADB and the vendor notices. The current package targets Apple Silicon Macs (macOS 13+), is locally signed, and is not notarized. Quit the running development copy before dragging the app into Applications; launch the installed copy afterward. Preferences use the same bundle identifier and are preserved.

## App icon

The Finder/Dock icon uses the same turquoise drive symbol as the sidebar, on a dark rounded tile. Its vector source renderer is `scripts/generate-icon.swift`. Regenerate it with:

```sh
swift scripts/generate-icon.swift Resources
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

The app build embeds `Resources/AppIcon.icns` and declares it in Info.plist before signing.
