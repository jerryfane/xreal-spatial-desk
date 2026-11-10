#!/usr/bin/env bash
# Build XRealDesk.app on the Mac Studio and run it in the owner's GUI session, from a Linux seat.
#
#   scripts/studio-app.sh build [commit]            # compile and bundle only; nothing is launched
#   scripts/studio-app.sh probe [commit]            # 10 s: create the virtual display, list displays, remove it
#   scripts/studio-app.sh run [commit]              # 60 s against tools/fake_glasses.py; PNG snapshots
#   scripts/studio-app.sh crash [commit]            # start, kill -9 after 8 s, check the virtual display is gone
#
# Footprint agreed with the macserve owner (gitmoot 446303/446319): account jerry, ~/xreal-desk only, ad-hoc signed
# app at the stable path ~/xreal-desk/XRealDesk.app (one Screen Recording entry), nothing installed, fake glasses
# and app killed on exit. Prints UTC start/end of every app run. Output (log, PNGs) is copied to
# OUT (default ./studio-output/<commit>-<mode>/).
set -euo pipefail

mode=${1:?usage: studio-app.sh build|probe|run|crash [commit]}
sha=$(git rev-parse --verify "${2:-HEAD}^{commit}")
studio=${STUDIO:-jerry@100.111.92.43}
out=${OUT:-studio-output/$sha-$mode}
mkdir -p "$out"

if ssh "$studio" 'pgrep -fl macserve-admin'; then
  echo "a macserve admin step is in progress on the Studio; not running" >&2
  exit 3
fi

git archive --format=tar "$sha" | ssh "$studio" "mkdir -p ~/xreal-desk/$sha && tar -x -C ~/xreal-desk/$sha"

set +e
ssh "$studio" bash -s -- "$sha" "$mode" <<'REMOTE' 2>&1 | tee "$out/console.txt"
set -euo pipefail
sha=$1 mode=$2
work=~/xreal-desk/$sha
app=~/xreal-desk/XRealDesk.app
exe=$app/Contents/MacOS/XRealDesk
run=$work/run
cd "$work"
fake=
cleanup() {
  pkill -9 -f "^$exe" 2>/dev/null || true
  [[ -n $fake ]] && kill "$fake" 2>/dev/null && wait "$fake" 2>/dev/null || true
  if lsof -nP -iTCP:52998 -iTCP:52999 -sTCP:LISTEN; then echo "LISTENER LEFT ON 52998/52999" >&2; exit 1; fi
}
trap cleanup EXIT
displays() { system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:' || true; }

echo "== build $sha on $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
swiftpm=(--package-path app --scratch-path "$work/.build" --cache-path "$work/.swiftpm/cache"
         --config-path "$work/.swiftpm/config" --security-path "$work/.swiftpm/security")
taskpolicy -b nice -n 10 xcrun swift build "${swiftpm[@]}" --product XRealDesk 2>&1 | grep -E 'error|warning:|Compiling|Build' || true
bin=$(xcrun swift build "${swiftpm[@]}" --show-bin-path)/XRealDesk
[[ -x $bin ]] || { echo "build failed"; exit 1; }

mkdir -p "$app/Contents/MacOS"
cp "$bin" "$exe"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jerryfane.xrealdesk</string>
  <key>CFBundleName</key><string>XRealDesk</string>
  <key>CFBundleExecutable</key><string>XRealDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>${sha:0:7}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.jerryfane.xrealdesk "$app"
echo "== app: $app ($(codesign -dv "$app" 2>&1 | grep -E '^CDHash=' || true))"
mkdir -p "$run"

launch() {  # args for the app; returns once `open` has launched it (or, with -W, once it quit)
  open "$@" --stdout "$run/stdout.txt" --stderr "$run/stderr.txt" "$app" --args --out "$run" "${appargs[@]}"
}

echo "== displays before: $(displays)"
case $mode in
  build)
    echo "== build only; nothing launched"
    exit 0
    ;;
  probe)
    appargs=(--probe --seconds 10)
    echo "== app start UTC $(date -u +%FT%TZ)"
    launch -n -W
    echo "== app end UTC $(date -u +%FT%TZ)"
    ;;
  run|crash)
    mkfifo "$work/fake.stdin"
    exec 3<>"$work/fake.stdin"
    python3 -u tools/fake_glasses.py captures/20261110-140512 --loop <&3 >"$run/fake.log" 2>&1 &
    fake=$!
    for _ in $(seq 120); do grep -q 'serving fake glasses' "$run/fake.log" && break; sleep 0.5; done
    if [[ $mode == run ]]; then
      appargs=(--host 127.0.0.1 --seconds 60 --snapshots 10,20,30,45,55)
      echo "== app start UTC $(date -u +%FT%TZ)"
      launch -n -W
      echo "== app end UTC $(date -u +%FT%TZ)"
    else
      appargs=(--host 127.0.0.1 --seconds 60)
      echo "== app start UTC $(date -u +%FT%TZ)"
      launch -n
      sleep 8
      echo "== displays while running: $(displays)"
      pid=$(pgrep -f "^$exe" | head -1)
      echo "== kill -9 $pid at UTC $(date -u +%FT%TZ)"
      kill -9 "$pid"
      sleep 3
      echo "== app end UTC $(date -u +%FT%TZ)"
    fi
    ;;
esac
echo "== displays after: $(displays)"
echo "== app log"
cat "$run/log.txt" 2>/dev/null || echo "(no log.txt)"
cat "$run/stderr.txt" 2>/dev/null || true
REMOTE
status=${PIPESTATUS[0]}
set -e

scp -q "$studio:xreal-desk/$sha/run/*" "$out/" 2>/dev/null || true
ssh "$studio" "rm -rf ~/xreal-desk/$sha"
echo "output in $out (remote exit $status)"
exit "$status"
