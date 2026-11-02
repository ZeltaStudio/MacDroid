#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/dist/MacDroid.app"
if [[ ! -x "$app/Contents/MacOS/MacDroid" ]]; then
    echo 'Build the release first: ./scripts/build-app.sh release' >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
architecture="$(/usr/bin/lipo -archs "$app/Contents/MacOS/MacDroid")"
if [[ "$architecture" != arm64 ]]; then echo "Unexpected architecture: $architecture" >&2; exit 1; fi
output_dir="${1:-$PWD/dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
stage="$(mktemp -d "$PWD/.build/dmg.XXXXXX")"
/usr/bin/ditto "$app" "$stage/MacDroid.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Install MacDroid.txt" <<'TEXT'
MacDroid — Apple Silicon Mac

INSTALL
1. Quit the running MacDroid app. Let any active transfers finish first.
2. Drag MacDroid.app onto the Applications shortcut in this window.
3. Open MacDroid from your Applications folder.
4. Eject this disk image when installation is complete.

Requires macOS 13 or later and an Apple Silicon (M-series) Mac.
Android Platform Tools (ADB) are included; no Android app is required.
Use USB debugging for a cable connection, or Wireless debugging for Wi-Fi.
Your remembered phone and preferences stay available after installation.

This is a locally signed development build, not an Apple-notarized release.
If macOS blocks it, review the app in System Settings > Privacy & Security.

Deleted files can be restored from Recovery in MacDroid. Overwritten files
are not backed up. Keep the app running while using the phone in Finder.

Bundled Android Platform Tools notices are inside the app at
Contents/Resources/Platform-Tools-NOTICE.txt.
TEXT
image="$output_dir/MacDroid-$version-macos-arm64.dmg"
hdiutil create -ov -format UDZO -volname "MacDroid $version" -srcfolder "$stage" "$image"
hdiutil verify "$image"
(cd "$output_dir" && shasum -a 256 "$(basename "$image")" > "$(basename "$image").sha256")
printf 'Installer: %s\n' "$image"
