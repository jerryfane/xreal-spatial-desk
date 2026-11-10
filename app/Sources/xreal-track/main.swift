import CaptureTools
import Foundation
import GlassesLink
import XRealCore

let usage = """
usage:
  xreal-track live [--host ADDR]
      Connect to the glasses (default 169.254.2.1; 127.0.0.1 for tools/fake_glasses.py) and print the head pose
      at 10 Hz plus button, wear and GET events. Type r + Enter to recenter, q + Enter to quit.
  xreal-track measure CAPTURE_DIR [--host ADDR] [--timeout SECONDS]
      Connect to tools/fake_glasses.py serving CAPTURE_DIR, track one full playback (waits for it to start from
      the first marker), and report per-step motion and drift. Also checks the GET replies and events received.
  xreal-track replay CAPTURE_DIR [--compare]
      Same report, offline from the capture's raw sensor stream. --compare also runs the tracker without the
      factory calibration and without bias learning.
"""

struct UsageError: Error {}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ args: inout [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func flag(_ args: inout [String], _ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func stamp() -> String {
    String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
}

func describe(_ m: ControlMessage) -> String {
    switch m {
    case .reply(let r):
        switch r.command {
        case .factoryConfig:
            if let c = try? FactoryCalibration(reply: r) {
                let l = c.displays.left
                return String(format: "GET factory config: %d bytes, panel %dx%d, left fx %.0f fy %.0f, %d bias/temperature points",
                              r.body.count, c.displays.width, c.displays.height, l.fx, l.fy, c.imu.gyroBiasByTemperature.count)
            }
            return "GET factory config: \(r.body.count) bytes, NOT decodable"
        case .displayConfig:
            return "GET display config: \((try? r.integerValue()).map(String.init) ?? "?")"
        default:
            return "GET \(r.command): \((try? r.stringValue()) ?? "?")"
        }
    case .setReply(let r):
        return "display mode reply tx \(r.transactionID): \(r.body.map { String(format: "%02x", $0) }.joined(separator: " ")) → \(r.result)"
    case .button(let b): return "button key \(b.key) \(b.state)"
    case .wear(let w): return "wear \(w)"
    case .telemetry(let i, let v): return "telemetry #\(i) = \(v)"
    case .stateChange(let p): return "state change (\(p.count) bytes)"
    case .unknown(let f): return String(format: "unknown frame 0x%04x (%d bytes)", f.magic, f.payload.count)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}

// MARK: live

func live(host: String) {
    let tracker = Locked<HeadTracker?>(nil)
    let pending = Locked<[IMUSample]>([])
    var config = GlassesLink.Configuration(host: host)
    config.initialRequests = GetCommand.allCases
    let link = GlassesLink(configuration: config) { event in
        switch event {
        case .connected(let c): print("[\(stamp())] connected \(c)")
        case .disconnected(let c, let reason): print("[\(stamp())] \(c) disconnected: \(reason)")
        case .sensor(.imu(let s)):
            let started = tracker.with { t -> Bool in
                t?.update(s)
                return t != nil
            }
            if !started { pending.with { $0.append(s); if $0.count > 2000 { $0.removeFirst($0.count - 2000) } } }
        case .sensor: break
        case .control(let m):
            if case .reply(let r) = m, r.command == .factoryConfig, let c = try? FactoryCalibration(reply: r) {
                let buffered = pending.with { p -> [IMUSample] in defer { p = [] }; return p }
                tracker.with { t in
                    if t == nil {
                        var fresh = HeadTracker(calibration: c.imu)
                        buffered.forEach { fresh.update($0) }
                        t = fresh
                    }
                }
            }
            if case .telemetry = m { return }
            print("[\(stamp())] \(describe(m))")
        }
    }
    print("connecting to \(host) (sensor \(config.sensorPort), control \(config.controlPort)); waiting for factory calibration")
    link.start()
    let reader = Thread {
        while let line = readLine() {
            switch line.trimmingCharacters(in: .whitespaces) {
            case "r":
                tracker.with { $0?.recenter() }
                print("[\(stamp())] recentered")
            case "q":
                link.stop()
                exit(0)
            default: break
            }
        }
        link.stop()
        exit(0)
    }
    reader.start()
    while true {
        Thread.sleep(forTimeInterval: 0.1)
        if let pose = tracker.with({ $0?.pose }) {
            print(String(format: "yaw %7.1f  pitch %6.1f  roll %6.1f", pose.yaw, pose.pitch, pose.roll))
        }
    }
}

// MARK: measure

struct LiveRun {
    var track = PoseTrack()
    var imuSamples = 0
    var started = false
    var finished = false
    var lastTimestamp: UInt64 = 0
    var messages: [String] = []
    var buttons: [ButtonEvent] = []
    var wear: [WearState] = []
    var replies: [GetCommand: GetReply] = [:]
    var connects = 0
}

func measure(capture: Capture, host: String, timeout: TimeInterval) {
    let start = 0.0
    guard let end = capture.markerSeconds.last?.start else { fail("no markers") }
    let tracker = Locked(HeadTracker(calibration: capture.calibration.imu))
    let run = Locked(LiveRun())
    let done = DispatchSemaphore(value: 0)
    let link = GlassesLink(configuration: GlassesLink.Configuration(host: host)) { event in
        switch event {
        case .connected:
            run.with { $0.connects += 1 }
        case .disconnected(let c, let reason):
            // Without --loop the fake stops streaming at the end marker; the link then reports the idle sensor port.
            let finishedNow = run.with { r -> Bool in
                r.messages.append("\(c) disconnected: \(reason)")
                guard c == .sensor, r.started, !r.finished else { return false }
                r.finished = true
                return true
            }
            if finishedNow { done.signal() }
        case .sensor(.imu(let s)):
            let t = capture.seconds(deviceNs: s.timestampNs)
            let finishedNow = run.with { r -> Bool in
                if r.finished { return false }
                if !r.started {
                    // Wait for playback to (re)start at the first marker.
                    guard t >= start - 0.01 && t < start + 0.05 else { return false }
                    r.started = true
                } else if s.timestampNs <= r.lastTimestamp || t >= end {
                    r.finished = true
                    return true
                }
                r.lastTimestamp = s.timestampNs
                r.imuSamples += 1
                let (pose, rate) = tracker.with { tr -> (HeadPose, Double) in
                    tr.update(s)
                    return (tr.pose, tr.angularRate.length * 180 / .pi)
                }
                r.track.append(time: t, pose: pose, rate: rate)
                return false
            }
            if finishedNow { done.signal() }
        case .sensor:
            break
        case .control(let m):
            run.with { r in
                switch m {
                case .reply(let reply): r.replies[reply.command] = reply
                case .button(let b) where r.started && !r.finished: r.buttons.append(b)
                case .wear(let w) where r.started && !r.finished: r.wear.append(w)
                default: break
                }
            }
        }
    }
    print("measuring against \(host): waiting for playback to start at the first marker (run fake_glasses with --loop; this waits for the next loop, up to 93 s)")
    link.start()
    let ok = done.wait(timeout: .now() + timeout) == .success
    link.stop()
    let r = run.with { $0 }
    guard ok else {
        fail("timed out after \(Int(timeout)) s: started=\(r.started), IMU samples=\(r.imuSamples); \(r.messages.joined(separator: "; "))")
    }

    print("\nReceived \(r.imuSamples) IMU samples over \(String(format: "%.1f", r.track.times.last! - r.track.times.first!)) s. GET replies:")
    for c in GetCommand.allCases {
        print("  \(r.replies[c].map { describe(.reply($0)) } ?? "GET \(c): NO REPLY")")
    }
    if let reply = r.replies[.factoryConfig] {
        let same = (try? FactoryCalibration(reply: reply)) == capture.calibration
        print("  factory calibration over TCP \(same ? "matches" : "DIFFERS FROM") control_gets.json")
    }
    print("Buttons during playback: \(r.buttons.map { "key \($0.key) \($0.state)" }.joined(separator: ", "))")
    print("Wear events during playback: \(r.wear.map { "\($0)" }.joined(separator: ", "))")
    print("Connections: \(r.connects); notes: \(r.messages.isEmpty ? "none" : r.messages.joined(separator: "; "))")

    // Compare with the offline replay of the same byte stream: proves nothing was lost or reordered on the wire.
    if let offline = try? capture.imuSamples() {
        let first = r.track.times[0], last = r.track.times.last!
        let same = offline.filter { let t = capture.seconds(deviceNs: $0.timestampNs); return t >= first - 1e-6 && t <= last + 1e-6 }
        let reference = PoseTrack(samples: same, tracker: HeadTracker(calibration: capture.calibration.imu),
                                  time: { capture.seconds(deviceNs: $0.timestampNs) })
        var maxDiff = 0.0
        for (a, b) in zip(r.track.poses, reference.poses) {
            maxDiff = max(maxDiff, abs(a.yaw - b.yaw), abs(a.pitch - b.pitch), abs(a.roll - b.roll))
        }
        print("Offline replay of raw_52998.bin over the same interval: \(reference.times.count) samples (live: \(r.track.times.count)); max pose difference \(String(format: "%.6f", maxDiff))°")
    }
    print("")
    print(TrackingReport(track: r.track, markers: capture.markerSeconds).formatted())
}

// MARK: replay

func replay(capture: Capture, compare: Bool) throws {
    let samples = try capture.imuSamples()
    let time = { (s: IMUSample) in capture.seconds(deviceNs: s.timestampNs) }
    func report(_ tracker: HeadTracker) -> TrackingReport {
        TrackingReport(track: PoseTrack(samples: samples, tracker: tracker, time: time), markers: capture.markerSeconds)
    }
    print("Offline replay: \(samples.count) IMU samples from raw_52998.bin\n")
    print(report(HeadTracker(calibration: capture.calibration.imu)).formatted())
    guard compare else { return }
    var constantBias = capture.calibration.imu
    constantBias.gyroBiasByTemperature = []
    var noTilt = HeadTracker.Options()
    noTilt.tiltGain = 0
    let variants: [(String, HeadTracker)] = [
        ("factory calibration, temperature bias table (default)", HeadTracker(calibration: capture.calibration.imu)),
        ("factory calibration, constant gyro bias", HeadTracker(calibration: constantBias)),
        ("no calibration", HeadTracker(calibration: .identity)),
        ("factory calibration, gyro only (no tilt correction)", HeadTracker(calibration: capture.calibration.imu, options: noTilt)),
    ]
    print("Drift by tracker configuration")
    for (name, tracker) in variants {
        let r = report(tracker)
        let d = r.startToEnd.map { String(format: "yaw %6.1f pitch %5.1f roll %5.1f", $0.yaw, $0.pitch, $0.roll) } ?? "n/a"
        let rest = r.rest.map { String(format: "yaw %6.1f pitch %5.1f roll %5.1f °/min", $0.yawPerMinute, $0.pitchPerMinute, $0.rollPerMinute) } ?? "n/a"
        print("  \(name):\n    still_end − still_center: \(d)\n    rest window: \(rest)")
    }
}

// MARK: main

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()
let host = option(&args, "--host") ?? GlassesLink.defaultHost
switch command {
case "live":
    live(host: host)
case "measure", "replay":
    let timeout = option(&args, "--timeout").flatMap(Double.init) ?? 240
    let compare = flag(&args, "--compare")
    guard args.count == 1 else { print(usage); exit(2) }
    let capture: Capture
    do { capture = try Capture(directory: URL(fileURLWithPath: args[0])) } catch { fail("\(error)") }
    if command == "measure" {
        measure(capture: capture, host: host, timeout: timeout)
    } else {
        do { try replay(capture: capture, compare: compare) } catch { fail("\(error)") }
    }
default:
    print(usage)
    exit(2)
}
