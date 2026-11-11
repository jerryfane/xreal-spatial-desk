# app/: XReal Desk (Swift package)

Milestones 1–4 of [BRIEF.md](../BRIEF.md): talk to the glasses, track the head, switch them to side-by-side, and
show several virtual displays around you in 3D, flat or curved, in saved layouts.

| Target | What it does |
|---|---|
| `XRealCore` | Frame codec, control messages (GET replies, buttons, wear, telemetry), sensor frames, factory calibration, `HeadTracker`, per-eye projection. Pure logic, no I/O. |
| `GlassesLink` | Both TCP connections (sensor 52998, control 52999), reconnect with backoff, the five verified GETs on every connect. Host is configurable: `169.254.2.1` for the glasses, `127.0.0.1` for the fake. |
| `CaptureTools` | Loads a `captures/` recording and measures tracking against its recorded steps. Tests and CLI only. |
| `xreal-track` | CLI: `live`, `measure` (against `tools/fake_glasses.py`), `replay` (offline). |
| `CVirtualDisplay` | Objective-C wrapper for the private `CGVirtualDisplay` API (macOS only). |
| `XRealDesk` | Menu bar app (macOS 14+): one virtual display per screen of the layout → ScreenCaptureKit → Metal 3840×1080 side-by-side render of every screen, placed with the head pose. |

The package builds GET requests only from `GetCommand`, which lists the five GETs verified in BRIEF.md. The only SET
is `DisplayInputMode` (`0x2822`, side-by-side on/off), sent only when asked and always switched back.

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

On launch it creates one virtual display per screen of the current layout (private `CGVirtualDisplay`, as
DeskPad/BetterDisplay do), captures each with ScreenCaptureKit and renders them with Metal at their places around you
(flat or curved), for both eyes (left half: left eye, right half: right eye), using the factory intrinsics and eye
poses and the head orientation from `HeadTracker`. Each display is a real macOS desktop: drag windows onto it. The
3840×1080 image is shown in a half-size window, or full screen on a chosen display with `--output ID` (for example
the glasses' display). Black is see-through on the glasses.

- Menu bar item "XR": head pose, layout, capture/render rate, **Recenter**, **Side-by-side 3D**, **Screens**,
  **Layouts**, **Quit**. `r` in the render window also recenters. Tracking recenters itself 0.5 s after it starts.
- **Screens:** each screen's size (diagonal, like a monitor), distance, shape (flat or 4000R…1000R curved),
  resolution and position (in the row, above, below); **Add screen** (up to six), **Remove**. Screens in the row sit
  side by side, 8° apart; the one straight ahead stays put and the others move aside when it grows or curves (a
  curved screen keeps its width along the curve, so it wraps more of your view).
- **Layouts:** presets *One screen*, *Three in a row*, *Desk (four screens)*; **Save current layout as…** and the saved
  layouts. The current and saved layouts are kept in `~/Library/Application Support/XRealDesk/layouts.json`; an
  unreadable file is renamed `layouts.json.bad` and the app starts with one screen. `--layout NAME` starts with a
  given layout.
- If macOS mirrors the glasses (or any other display) with one of the app's screens, the app undoes that mirror once
  per display pair (for the session): a mirrored glasses display shows that screen instead of the 3D image and cannot
  be switched to side-by-side. Every display change is logged with each display's state.
- macOS's display arrangement follows the layout (for the session): the row left to right in yaw order, right of
  your other displays; screens above or below the row above or below it. So the pointer leaves one screen for the
  next the way they sit around you.
- The virtual displays are removed on Quit, `--seconds`, SIGTERM/SIGINT/SIGHUP, and by WindowServer when the process
  dies (crash, `kill -9`). `--test-pattern` covers each with a grid and clock for unattended runs.
- **Screen Recording permission** is needed for the capture. If it is missing, the app asks macOS to show its prompt and
  logs exactly what to grant: System Settings › Privacy & Security › Screen & System Audio Recording › XRealDesk, then
  restart the app. Until then the renderer shows a checkerboard in place of each display.
- No Accessibility permission is used yet.
- On a Mac without a monitor (such as a headless Mac Studio), the virtual display replaces the system's placeholder
  display while it exists, so the desktop and any Screen Sharing view move onto it.

## Testing on a Mac with the glasses

Needs macOS 14+. The glasses connect over USB-C; no driver. The app sends the five read-only GETs and, only when
asked, one setting: side-by-side input mode (below).

1. **Download** `XRealDesk.zip` from the repository's
   [Releases](https://github.com/jerryfane/xreal-spatial-desk/releases) (universal: Apple Silicon and Intel) and
   double-click it. Move `XRealDesk.app` anywhere, e.g. Applications.
2. **First open.** The app is not notarized, so macOS blocks it the first time. Double-click it, close the warning,
   then System Settings › Privacy & Security › scroll to "XRealDesk was blocked…" › **Open Anyway**. (Or in
   Terminal: `xattr -dr com.apple.quarantine /Applications/XRealDesk.app`.)
3. **Screen Recording.** On first start the app asks for it: System Settings › Privacy & Security › Screen & System
   Audio Recording › switch on **XRealDesk**, then quit (menu bar **XR** › Quit) and open it again. The permission
   stays until you install a different build.
4. **Check.** The **XR** menu shows the head pose. Turn right: yaw goes up. Look up: pitch goes up. Right ear
   down: roll goes up. **Recenter** resets yaw. A window shows the side-by-side image of the virtual display.
   If the menu says "not connected", replug the glasses.
5. **On the glasses.** Quit the app (**XR** › Quit): settings are read only at start, and `open` would otherwise
   reuse the running copy. In Terminal, `open /Applications/XRealDesk.app --args --out /tmp/xreal-run`; the
   glasses' display ID is in `/tmp/xreal-run/log.txt` ("displays before: …"). Quit again, then
   `open /Applications/XRealDesk.app --args --output <ID>` fills that display with the side-by-side image.
   Until side-by-side mode is on, the glasses show the 3840×1080 image squeezed into 1920×1080, so both eyes see both
   halves.
6. **Side-by-side 3D.** **XR** › **Side-by-side 3D on the glasses** (or start with `--args --sbs`) finds the glasses,
   fills them with the app's image, then switches them to side-by-side input: they briefly blank and come back as a
   3840×1080 display, and each eye sees only its own half. While the glasses are side-by-side the image always covers
   all of them, so neither eye sees the desktop. **Esc** quits at any time (the image may cover your only screen).
   Choosing the menu item again, or quitting, switches the glasses back; so does unplugging them, and the next start
   if the app crashed.
7. **Several screens.** **XR** › **Layouts** › *Three in a row* (or *Desk*) adds displays; each is a real macOS
   desktop, so drag windows onto them. **XR** › **Screens** changes one screen's size, distance, shape and
   resolution, adds or removes screens; **Save current layout as…** keeps the arrangement for next time. Each new
   display briefly blanks the others while macOS rearranges.

The log (`~/Library/Logs/XRealDesk/log.txt`, replaced each run; or `log.txt` in the `--out` folder) records connection, GET replies, the exact mode-switch frames and replies,
buttons, wear events and frame rates.

### First side-by-side run (checks the mode switch step by step)

```sh
open -W /Applications/XRealDesk.app --args --sbs-check --out /tmp/xreal-sbs
cat /tmp/xreal-sbs/log.txt
```

It reads the glasses' mode (from their display size), switches to side-by-side, checks that they come back as
3840×1080, waits 5 s, switches back, checks 1920×1080, and quits. Each step and each reply is logged byte for byte;
the last line is `sbs-check: RESULT PASS` or `FAIL`. On any error or mismatch it switches back and stops.

### Building it yourself

With Xcode or the Command Line Tools (`xcode-select --install`): `scripts/build-app.sh` builds `build/XRealDesk.app`.
For a live 10 Hz pose readout in Terminal, from the repository root:
`swift build --package-path app -c release && app/.build/release/xreal-track live` (`r` + Enter recenters, `q` +
Enter quits).

Releases are built by CI: pushing a tag `v*` publishes `XRealDesk.zip`. Every pull request's CI run also has the
zip as a downloadable artifact.
