# app/: XReal Desk (Swift package)

Milestones 2 and 3 of [BRIEF.md](../BRIEF.md): talk to the glasses, track the head, and show one virtual display
in 3D as a side-by-side image.

| Target | What it does |
|---|---|
| `XRealCore` | Frame codec, control messages (GET replies, buttons, wear, telemetry), sensor frames, factory calibration, `HeadTracker`, per-eye projection. Pure logic, no I/O. |
| `GlassesLink` | Both TCP connections (sensor 52998, control 52999), reconnect with backoff, the five verified GETs on every connect. Host is configurable: `169.254.2.1` for the glasses, `127.0.0.1` for the fake. |
| `CaptureTools` | Loads a `captures/` recording and measures tracking against its recorded steps. Tests and CLI only. |
| `xreal-track` | CLI: `live`, `measure` (against `tools/fake_glasses.py`), `replay` (offline). |
| `CVirtualDisplay` | Objective-C wrapper for the private `CGVirtualDisplay` API (macOS only). |
| `XRealDesk` | Menu bar app (macOS 14+): one virtual display → ScreenCaptureKit → Metal 3840×1080 side-by-side render, placed with the head pose. |

The package only builds requests from `GetCommand`, which lists the five GETs verified in BRIEF.md. There is no
code path that sends a SET or any other command.

## Run

```sh
cd app
swift build
swift test                                   # unit tests + end to end against tools/fake_glasses.py (needs python3)

python3 ../tools/fake_glasses.py ../captures/20261110-140512 --loop &
.build/debug/xreal-track live --host 127.0.0.1           # pose at 10 Hz; r = recenter, q = quit
.build/debug/xreal-track measure ../captures/20261110-140512 --host 127.0.0.1
.build/debug/xreal-track replay ../captures/20261110-140512 --compare
```

`measure` waits for the fake's next loop, tracks one full playback over TCP, checks the GET replies and events, and
prints per-step yaw/pitch/roll and drift. `replay` prints the same report from `raw_52998.bin` without a network.

The tests and the CLI also build and run on Linux (Swift 6.1); `GlassesLink` uses plain BSD sockets for that reason.
On the Mac Studio, `scripts/studio-test.sh` runs build, tests and the live measurement for a commit.

## Head tracking

`HeadTracker` integrates the gyro (1000 Hz) and pulls pitch and roll toward gravity from the accelerometer
(complementary filter, gain 0.5 /s, accel ignored when |a| is more than 1 m/s² from g). Gyro and accel go through the
factory calibration in the factory config (`imu_intrinsics`: 3×3 matrices and biases), with the gyro bias taken from
the factory temperature table at the IMU temperature carried in every frame.

Frame and angles: X right, Y down, Z forward (the sensor's own axes). `yaw > 0` turns right, `pitch > 0` looks up,
`roll > 0` tilts the right ear down. `recenter()` zeroes yaw at the current heading; pitch and roll stay absolute.
Yaw has no absolute reference, so its drift depends on the bias calibration alone.

## XRealDesk (menu bar app)

```sh
swift build --product XRealDesk
# The app needs a bundle for its Screen Recording permission; scripts/studio-app.sh shows how one is made.
XRealDesk.app/Contents/MacOS/XRealDesk --host 127.0.0.1 --seconds 60 --out run/ --snapshots 10,30
```

On launch it creates one 1920×1080 virtual display (private `CGVirtualDisplay`, as DeskPad/BetterDisplay do), puts a
test pattern window on it, captures it with ScreenCaptureKit and renders it with Metal as one flat screen 1.6 m ahead,
0.9 m wide, for both eyes (left half: left eye, right half: right eye), using the factory intrinsics and eye poses and
the head orientation from `HeadTracker`. The 3840×1080 image is shown in a half-size window, or full screen on a chosen
display with `--output ID` (for example the glasses' display). Black is see-through on the glasses.

- Menu bar item "XR": head pose, virtual display, capture/render rate, **Recenter**, **Quit**. `r` in the render
  window also recenters. Tracking recenters itself 0.5 s after it starts.
- The virtual display is removed on Quit, `--seconds`, SIGTERM/SIGINT/SIGHUP, and by WindowServer when the process
  dies (crash, `kill -9`).
- **Screen Recording permission** is needed for the capture. If it is missing, the app asks macOS to show its prompt and
  logs exactly what to grant: System Settings › Privacy & Security › Screen & System Audio Recording › XRealDesk, then
  restart the app. Until then the renderer shows a checkerboard in place of the display.
- No Accessibility permission is used yet.
- On a Mac without a monitor (such as a headless Mac Studio), the virtual display replaces the system's placeholder
  display while it exists, so the desktop and any Screen Sharing view move onto it.

## Testing on a Mac with the glasses

Needs macOS 14+ and Xcode or the Command Line Tools (`xcode-select --install`). The glasses connect over USB-C; no
driver. Everything below only sends the five read-only GETs.

1. **Check the link.** `nc -z -G 2 169.254.2.1 52998 && echo ok` must print `ok`. If not: replug, and check System
   Settings › Network shows the glasses' USB adapter with a 169.254.x.x address.
2. **Head tracking, no permissions:**
   ```sh
   cd app && swift build -c release
   .build/release/xreal-track live          # r + Enter recenters, q + Enter quits
   ```
   It prints firmware, serial and calibration, then yaw/pitch/roll at 10 Hz. Turn right: yaw goes up. Look up:
   pitch goes up. Right ear down: roll goes up. Press the glasses' buttons and take them off: the events print.
3. **The app:**
   ```sh
   scripts/build-app.sh                     # → build/XRealDesk.app
   open build/XRealDesk.app --args --out /tmp/xreal-run
   ```
   An "XR" item appears in the menu bar; a window shows the side-by-side image. The first start needs Screen
   Recording: System Settings › Privacy & Security › Screen & System Audio Recording › switch on XRealDesk, then
   quit (XR › Quit) and open it again. Rebuilding the app needs the switch turned on again.
4. **On the glasses:** find the glasses' display ID in `/tmp/xreal-run/log.txt` ("displays before: …"), then
   `open build/XRealDesk.app --args --output <ID>` to fill that display with the side-by-side image.
   Without side-by-side input mode (a SET command, milestone 1) the glasses show the 3840×1080 image squeezed into
   1920×1080, so both eyes see both halves; head tracking and capture can still be checked on the window.
