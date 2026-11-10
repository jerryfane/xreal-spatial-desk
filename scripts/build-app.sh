#!/usr/bin/env bash
# Build XRealDesk.app (the menu bar app) on a Mac. Needs Xcode or the Command Line Tools (Swift 5.9+), macOS 14+.
#
#   scripts/build-app.sh                         # release build → build/XRealDesk.app
#   scripts/build-app.sh OUT_DIR [SWIFT ARGS...] # e.g. scripts/build-app.sh ~/xreal-desk -c debug --scratch-path ...
#
# The app is ad-hoc signed. macOS ties its Screen Recording permission to this exact build, so a rebuilt app
# needs the permission switched on again. VERSION sets CFBundleVersion (default: the git commit, or "dev").
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/build}
[[ $# -gt 0 ]] && shift
args=("$@")
[[ ${#args[@]} -eq 0 ]] && args=(-c release)
version=${VERSION:-$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo dev)}

xcrun swift build --package-path "$root/app" "${args[@]}" --product XRealDesk
bin=$(xcrun swift build --package-path "$root/app" "${args[@]}" --show-bin-path)/XRealDesk
[[ -x $bin ]] || { echo "build failed: $bin missing" >&2; exit 1; }

app=$out/XRealDesk.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/XRealDesk"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jerryfane.xrealdesk</string>
  <key>CFBundleName</key><string>XRealDesk</string>
  <key>CFBundleExecutable</key><string>XRealDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.jerryfane.xrealdesk "$app"
echo "built $app"
