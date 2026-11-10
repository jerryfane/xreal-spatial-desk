# app/: XReal Desk (Swift package)

Milestone 2 of [BRIEF.md](../BRIEF.md): talk to the glasses and track the head. No UI yet.

| Target | What it does |
|---|---|
| `XRealCore` | Frame codec, control messages (GET replies, buttons, wear, telemetry), sensor frames, factory calibration, `HeadTracker`. Pure logic, no I/O. |
| `GlassesLink` | Both TCP connections (sensor 52998, control 52999), reconnect with backoff, the five verified GETs on every connect. Host is configurable: `169.254.2.1` for the glasses, `127.0.0.1` for the fake. |
| `CaptureTools` | Loads a `captures/` recording and measures tracking against its recorded steps. Tests and CLI only. |
| `xreal-track` | CLI: `live`, `measure` (against `tools/fake_glasses.py`), `replay` (offline). |

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
