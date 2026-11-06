# Changelog

## Unreleased

### Added

- Mirror and control the phone’s screen from the main window or the menu bar. The packaged app includes scrcpy and uses that copy first. A release build downloads the official Apple Silicon release, checks its checksums, and embeds the binary, server, and license. Finder keeps working when scrcpy is missing.
- Speed up Finder and Quick Look thumbnails, especially over Wi-Fi. Preview reads reuse a cache of real file bytes. Photos up to 8 MB are fetched once. Larger videos are read from the requested offset instead of copying the whole file. Opening a file still downloads it completely, and partial responses keep the byte ranges fixed in 0.2.2.
- Empty Recovery, with confirmation, from the recovery window and the menu bar. Permanently delete one recovered item from the list. Optionally delete recovered items older than a chosen number of days; that setting is off unless you turn it on.
- Put Mirror, Open in Finder, Recovery, and Eject in the main window sidebar. The menu bar is unchanged.

## 0.2.2 — 2026-11-02

### Fixed

- Serve the requested byte offsets for partial file reads. This addresses incomplete or grey-bottomed images when Finder, Quick Look, or Preview reads a mounted phone file in sections.
- Return correct partial-response lengths, content ranges, and image content types.
- Check file versions when a client resumes a partial read and reject incomplete staged downloads.
- Finish HTTP responses with a graceful write-close before releasing the connection.

### Added

- Regression checks for byte ranges, file validators, JPEG reconstruction, and image integrity through a mounted Android phone.
- MIT license and separate third-party notices.
- GitHub Actions build checks and bug/feature issue templates.
- Public installer release with a SHA-256 checksum.

## 0.2.1 — 2026-11-02

- Added the turquoise drive app icon for Finder and the Dock.
- Packaged an Apple Silicon DMG with an Applications shortcut, bundled ADB, and vendor notices.

## 0.2.0 — 2026-11-02

- Added automatic reconnect using physical phone identity.
- Added readable device names and USB/Wi-Fi labels.
- Added transfer progress, speed, per-stage estimates, and cancellation.
- Added recoverable deletion and conflict-safe restoration.
- Added menu bar controls and phone storage information.
- Improved safe mounting and ejection.

## 0.1.0 — 2026-11-02

- Initial SwiftUI Mac app with wireless ADB pairing and connection controls.
- Mounted Android shared storage in Finder through a loopback WebDAV bridge.
- Supported browsing, copying, creating folders, renaming, and deleting over authorized USB or Wi-Fi connections.
