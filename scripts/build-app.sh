#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" == "release" ]]; then
    ./scripts/fetch-scrcpy.sh
fi
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
package_dir="$(mktemp -d "$PWD/.build/package.XXXXXX")"
app="$package_dir/MacDroid.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/MacDroid" "$app/Contents/MacOS/MacDroid"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/MacDroid-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Third-Party-Notices.md"
if [[ -x .build/downloads/platform-tools/adb ]]; then
    cp .build/downloads/platform-tools/adb "$app/Contents/Resources/adb"
    if [[ -f .build/downloads/platform-tools/NOTICE.txt ]]; then
        cp .build/downloads/platform-tools/NOTICE.txt "$app/Contents/Resources/Platform-Tools-NOTICE.txt"
    fi
fi
if [[ -x .build/downloads/scrcpy/scrcpy && -f .build/downloads/scrcpy/scrcpy-server ]]; then
    cp .build/downloads/scrcpy/scrcpy "$app/Contents/Resources/scrcpy"
    cp .build/downloads/scrcpy/scrcpy-server "$app/Contents/Resources/scrcpy-server"
    if [[ -f .build/downloads/scrcpy/LICENSE ]]; then
        cp .build/downloads/scrcpy/LICENSE "$app/Contents/Resources/scrcpy-LICENSE.txt"
    fi
fi
if [[ "$configuration" == "release" ]]; then
    test -x "$app/Contents/Resources/scrcpy"
    test -f "$app/Contents/Resources/scrcpy-server"
    test -f "$app/Contents/Resources/scrcpy-LICENSE.txt"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacDroid</string>
<key>CFBundleIdentifier</key><string>ai.zeltalabs.macdroid</string>
<key>CFBundleName</key><string>MacDroid</string>
<key>CFBundleDisplayName</key><string>MacDroid</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Connect to your Android phone using wireless debugging on your local Wi-Fi.</string>
</dict></plist>
PLIST
if [[ -x "$app/Contents/Resources/adb" ]]; then codesign --force --sign - "$app/Contents/Resources/adb"; fi
if [[ -x "$app/Contents/Resources/scrcpy" ]]; then codesign --force --sign - "$app/Contents/Resources/scrcpy"; fi
codesign --force --sign - "$app"
mkdir -p "$PWD/dist"
if [[ -d "$PWD/dist/MacDroid.app" ]]; then mv "$PWD/dist/MacDroid.app" "$package_dir/previous.app"; fi
mv "$app" "$PWD/dist/MacDroid.app"
printf 'Built %s\n' "$PWD/dist/MacDroid.app"
