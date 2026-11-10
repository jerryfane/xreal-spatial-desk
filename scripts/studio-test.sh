#!/usr/bin/env bash
# Build and test app/ on the Mac Studio from a Linux seat, then measure head tracking against the fake glasses.
#
#   scripts/studio-test.sh [commit]        # default: HEAD; the commit must be committed, not pushed
#
# Runs in the owner's account (STUDIO, default jerry@100.111.92.43) inside ~/xreal-desk/<commit> only, at background
# priority, with SwiftPM caches inside that folder, and deletes the folder afterwards. Agreed with the macserve owner
# (gitmoot messages 446079/446086/446087): skip while a macserve admin step runs, and no listener may outlive the run.
# The output is printed and saved to OUT (default ./studio-output/<commit>.txt).
set -euo pipefail

sha=$(git rev-parse --verify "${1:-HEAD}^{commit}")
studio=${STUDIO:-jerry@100.111.92.43}
out=${OUT:-studio-output/$sha.txt}
mkdir -p "$(dirname "$out")"

if ssh "$studio" 'pgrep -fl macserve-admin'; then
  echo "a macserve admin step is in progress on the Studio; not running" >&2
  exit 3
fi

git archive --format=tar "$sha" | ssh "$studio" "mkdir -p ~/xreal-desk/$sha && tar -x -C ~/xreal-desk/$sha"

ssh "$studio" bash -s -- "$sha" <<'REMOTE' 2>&1 | tee "$out"
set -euo pipefail
work=~/xreal-desk/$1
cd "$work"
fake=
cleanup() {
  [[ -n $fake ]] && kill "$fake" 2>/dev/null && wait "$fake" 2>/dev/null || true
  cd ~
  rm -rf "$work"
  rmdir ~/xreal-desk 2>/dev/null || true
  if lsof -nP -iTCP:52998 -iTCP:52999 -sTCP:LISTEN; then echo "LISTENER LEFT ON 52998/52999" >&2; exit 1; fi
}
trap cleanup EXIT

echo "== host: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(xcrun swift --version 2>&1 | head -1)"
swiftpm=(--package-path app --scratch-path "$work/.build" --cache-path "$work/.swiftpm/cache"
         --config-path "$work/.swiftpm/config" --security-path "$work/.swiftpm/security")
echo "== swift build"
taskpolicy -b nice -n 10 xcrun swift build "${swiftpm[@]}" --build-tests
echo "== swift test"
taskpolicy -b nice -n 10 xcrun swift test "${swiftpm[@]}" --skip-build

echo "== live measurement against tools/fake_glasses.py on 127.0.0.1"
# The fake exits when its stdin closes; keep it open with a FIFO held by this shell.
mkfifo "$work/fake.stdin"
exec 3<>"$work/fake.stdin"
python3 -u tools/fake_glasses.py captures/20261110-140512 --loop <&3 >"$work/fake.log" 2>&1 &
fake=$!
for _ in $(seq 120); do grep -q 'serving fake glasses' "$work/fake.log" && break; sleep 0.5; done
taskpolicy -b "$work/.build/debug/xreal-track" measure captures/20261110-140512 --host 127.0.0.1 --timeout 240
echo "== offline replay"
taskpolicy -b "$work/.build/debug/xreal-track" replay captures/20261110-140512 --compare | tail -16
REMOTE
