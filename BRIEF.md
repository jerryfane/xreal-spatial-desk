# Brief: spatial multi-screen macOS app for XREAL One

Build a macOS menu bar app that turns XREAL One glasses into several virtual monitors floating around the wearer. The user creates screens and moves them with head direction plus keyboard/trackpad. Each screen is a real macOS display.

Interactive UX reference (open in a browser): `index.html` in this folder. "Mac · multi-screen" mode is this app.

## Hardware facts (verified on this unit, firmware 1.9.1.20260914175625)

- USB `3318:0438`. The glasses expose a USB network adapter; they answer at `169.254.2.1` (Mac side gets `169.254.2.10`). No driver needed.
- Display: 1920×1080 per eye; side-by-side input is 3840×1080.
- **Factory calibration** (`captures/*/control_gets.json.gz` → `factory_config`, JSON after the protobuf wrapper):
  - per-eye intrinsics `k_left_display` / `k_right_display`: fx ≈ 2490, fy ≈ 2464, giving **42.2° × 24.7°** FOV
  - per-eye pose relative to the IMU: `target_p_*` / `target_q_*` (Hamilton quaternions); eye spacing **64.4 mm**
  - per-eye distortion mesh `display_distortion` (61×35)
  - IMU biases, scale and misalignment (`IMU.device_1`; quaternions there are JPL order)
- **Framing on both ports:** `magic u16 BE | length u32 BE | payload`.
- **Control, TCP 52999:**
  - Request payload is `txid u32 BE (MSB set) | body`. The reply echoes the cmd as magic, with the MSB of txid cleared.
  - GET body is `18 00`. Verified GETs: `0x271D` firmware, `0x272D` DSP, `0x2729` serial, `0x271F` factory config (193 KB), `0x275E` display config.
- **Unsolicited control frames** (observed during the capture):
  - `0x272E` button, 64-byte body: `u32 key, u32 state` (1 = down, 2 = up). Keys seen: 2 and 3.
  - `0x273D` wear, 2-byte body: `18 02` = taken off, `18 01` = put on. Meaning inferred from timing; it matched the prompts.
  - `0x2712` state change after buttons and wear events (not decoded).
  - `0x278A` periodic telemetry (not decoded).
- **Sensor, TCP 52998:** 134-byte frames, magic `0x2836`, length 128.
  - `u64 LE @14` = device timestamp in **ns**.
  - `u32 LE @30` = kind. `0x0B` = IMU at **1000 Hz**; `0x04` ≈ 400 Hz, not decoded (magnetometer?).
  - IMU: `6×f32 LE @34` = gyro rad/s (x, y, z), then accel m/s² (x, y, z).
- **Axes:**
  - At rest, gravity is on **−Y**, so Y is vertical and rotation about Y is yaw.
  - Looking up tilts gravity onto +Z, so X is the pitch axis and Z the roll axis.
  - Gyro bias at rest is about (0.007, 0.014, 0.000) rad/s. Use the calibrated biases rather than these.
  - Caveat: the "nod" step of the capture registered mostly as Z rotation; confirm the sign conventions on hardware.

Protocol sources (community reverse engineering, not official):
- [georgehorrell/xreal-one-cli](https://github.com/georgehorrell/xreal-one-cli)
- [GarfDev/xreal-one-control-panel](https://github.com/GarfDev/xreal-one-control-panel/blob/main/docs/REVERSE_ENGINEERING.md) — 1.9.0 RPC table: spatial mode `0x282C`/`0x28B5`, recenter, etc.
- [kevindurb/xreal-linux](https://github.com/kevindurb/xreal-linux)

## Open questions to settle on hardware first (milestone 1)

1. **Double tracking:**
   - The app needs side-by-side input with the glasses' own anchoring OFF; otherwise the glasses re-move the Mac-rendered image.
   - Observed 2026-11-10 on the owner's MacBook Pro (regular input mode, app rendering to the glasses' display): the virtual screen stayed fixed in the room while turning the head, so the glasses did not add their own movement in that mode.
   - Display input mode `0x2822`: request body `1a 02 08 VV` (field 3 { field 1 mode }), `VV` = 1 side-by-side, 0 regular; e.g. `28 22 00 00 00 08 80 00 00 05 1a 02 08 01`. Sources: georgehorrell/xreal-one-cli @ `6e871ed` (firmware 1.8.1), GarfDev/xreal-one-control-panel @ `d11d9d0` (1.9.0). No GET for this mode is known; the app infers it from the glasses' macOS display size (1920×1080 regular, 3840×1080 side-by-side). Implemented in milestone 1 (`DisplayInputMode`), restored on quit and after a crash.
   - SET reply format: **not yet captured on this unit.** The community tools expect `22 LL { 08 status }`, status 0 or an empty field = accepted, nonzero = rejected (10001 reported for other setters). Record the first real reply here.
   - Spatial mode `0x282C` (anchoring) is not set by the app.
2. **Distortion:** the glasses likely already correct lens distortion for normal DP input. Start without applying the factory mesh and compare straight lines on hardware.
3. **Latency:** measure motion-to-photon. Use gyro-based pose prediction (render for the pose expected when the frame is shown).

## App architecture

| Part | Responsibility | macOS API |
|---|---|---|
| GlassesLink | Both TCP connections; reconnect; GETs; button and wear events; restore glasses state on exit | Network.framework |
| HeadTracker | Gyro integration + accel tilt correction (complementary or Madgwick filter) using factory bias/scale; recenter; yaw drift handling | — |
| VirtualDisplays | Create and destroy macOS displays with chosen resolution/HiDPI | `CGVirtualDisplay` (**private** API, as used by DeskPad/BetterDisplay) |
| Capture | Live frames of each virtual display | ScreenCaptureKit |
| Renderer | Full-screen on the glasses' display: 3840×1080 SBS, per-eye projection from the factory intrinsics and eye offsets, textured flat or curved quads, pose prediction | Metal |
| Interaction | Global hotkeys; gaze grab; focus follows head (cursor/key window to the looked-at display); saved layouts | Carbon hotkeys / CGEvent, Accessibility |

## UX to implement

- **Create:** a hotkey or long button press spawns a screen where the user is looking.
- **Move:** look at a screen and hold the grab key. The screen follows the head. Scroll changes distance, pinch changes size, releasing drops it. Screens snap to a curved row at equal distance.
- **Remove:** look at the screen and press a hotkey.
- **Recenter:** double-press a button to rotate the whole layout to the current heading.
- **Focus follows head:** the looked-at screen gets keyboard focus.
- **Layouts:** save and recall from the menu bar. The menu bar also has a top-down map for precise placement, like the preview.
- **Taking the glasses off** (wear event): pause rendering. Optionally lock the Mac.

## Constraints

- Never flash firmware. Send only verified GETs, plus the minimum SETs needed (SBS mode, spatial mode). Restore the previous values on quit. The app currently sends one SET: display input mode `0x2822` (owner-approved 2026-11-10).
- Make the glasses' address configurable (default `169.254.2.1`) so the app can run against the fake glasses.
- Personal distribution: the private API rules out the App Store.

## Developing without the glasses

```
python3 tools/fake_glasses.py captures/20261110-140512 --loop      # serves on 127.0.0.1
# or on the real address:
sudo ifconfig lo0 alias 169.254.2.1
python3 tools/fake_glasses.py captures/20261110-140512 --loop --host 169.254.2.1
```

- It replays the real head movement (1000 Hz), button and wear events with the original timing, and answers the 5 recorded GETs.
- Unrecorded commands are logged and not answered (their real reply format is unknown).
- stdin commands: `off`, `on`, `press 2`, `press 3`, `jump <step>`, `markers`.
- Steps in the capture: still_center, yaw_left, yaw_right, pitch_up, pitch_down, roll, nod, shake, fast_yaw, free_look, buttons, wear_off_on, still_end.
- `tools/record_session.py` records a new capture; re-record after firmware updates. Fresh captures are uncompressed; the fake glasses read either form.

The published capture is gzipped and its serial number is replaced by `REDACTED00` (same length, so every frame stays valid). The factory calibration is kept.

## Milestones

1. Settle the hardware open questions above (needs the glasses): SBS on, native anchoring off, SET reply format, restore on exit.
2. GlassesLink + HeadTracker against the fake glasses: stable yaw/pitch/roll, recenter, events.
3. One virtual display captured and rendered in SBS on any external monitor, with head pose from the replay.
4. Multiple screens, placement math, curved screens, layouts.
5. Interaction: grab/move/create/remove, focus follows head, button mapping.
6. Tuning on the glasses: latency and prediction, text sharpness, comfort.
