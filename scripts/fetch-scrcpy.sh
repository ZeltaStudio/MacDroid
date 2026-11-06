#!/bin/bash
# Download the official scrcpy Apple Silicon release and its server.
# Checksums are pinned from that release's SHA256SUMS.txt.
set -euo pipefail
cd "$(dirname "$0")/.."

version="5.0.1"
prefix="scrcpy-macos-aarch64-v${version}"
archive="${prefix}.tar.gz"
server_name="scrcpy-server-v${version}"
archive_sha256="33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b"
server_sha256="764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
base_url="https://github.com/Genymobile/scrcpy/releases/download/v${version}"
dest=".build/downloads/scrcpy"
mkdir -p "$dest"

if [[ -x "$dest/scrcpy" && -f "$dest/scrcpy-server" && -f "$dest/LICENSE" ]]; then
    current="$(shasum -a 256 "$dest/scrcpy-server" | awk '{print $1}')"
    if [[ "$current" == "$server_sha256" ]]; then
        printf 'scrcpy %s is already downloaded\n' "$version"
        exit 0
    fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 --retry-delay 2 -o "$work/$archive" "$base_url/$archive"
curl -fsSL --retry 3 --retry-delay 2 -o "$work/$server_name" "$base_url/$server_name"
(
    cd "$work"
    printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 -c -
    printf '%s  %s\n' "$server_sha256" "$server_name" | shasum -a 256 -c -
)
tar -xzf "$work/$archive" -C "$work"
extracted="$work/$prefix"
test -f "$extracted/scrcpy"
test -f "$extracted/LICENSE"
cmp -s "$extracted/scrcpy-server" "$work/$server_name"
# The archive also contains an adb binary. MacDroid bundles Platform Tools on its own.
cp "$extracted/scrcpy" "$dest/scrcpy"
cp "$work/$server_name" "$dest/scrcpy-server"
cp "$extracted/LICENSE" "$dest/LICENSE"
chmod 755 "$dest/scrcpy"
chmod 644 "$dest/scrcpy-server" "$dest/LICENSE"
if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$dest" || true
fi
printf '%s  %s\n' "$server_sha256" "$dest/scrcpy-server" | shasum -a 256 -c -
printf 'Downloaded scrcpy %s for Apple Silicon\n' "$version"
