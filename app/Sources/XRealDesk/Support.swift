#if os(macOS)
import AppKit
import Foundation
import GlassesLink
import XRealCore

struct Options {
    var host = GlassesLink.defaultHost
    /// Quit by itself after this many seconds (0 = run until Quit).
    var seconds: Double = 0
    /// Folder for log.txt and snapshots.
    var out: URL?
    /// Seconds after launch at which to save a PNG of the rendered 3840×1080 frame.
    var snapshots: [Double] = []
    /// Only create the virtual display, list displays, remove it, quit.
    var probe = false
    var displayWidth = 1920
    var displayHeight = 1080

    static let usage = """
    XRealDesk [--host ADDR] [--seconds N] [--out DIR] [--snapshots T1,T2,...] [--display WxH] [--probe]
      --host       glasses address (default 169.254.2.1; 127.0.0.1 for tools/fake_glasses.py)
      --seconds    quit after N seconds
      --out        write log.txt and snapshot PNGs here
      --snapshots  save the rendered side-by-side frame at these seconds after launch
      --display    virtual display size in pixels (default 1920x1080)
      --probe      create the virtual display, list displays, remove it and quit (no capture, no permissions)
    """

    init(arguments: [String]) throws {
        var args = arguments[...]
        func value(_ name: String) throws -> String {
            guard let v = args.popFirst() else { throw OptionError("\(name) needs a value") }
            return v
        }
        while let a = args.popFirst() {
            switch a {
            case "--host": host = try value(a)
            case "--seconds":
                guard let s = Double(try value(a)), s >= 0 else { throw OptionError("--seconds needs a number") }
                seconds = s
            case "--out": out = URL(fileURLWithPath: try value(a), isDirectory: true)
            case "--snapshots":
                snapshots = try value(a).split(separator: ",").map {
                    guard let t = Double($0) else { throw OptionError("--snapshots needs numbers") }
                    return t
                }
            case "--display":
                let parts = try value(a).split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 >= 640 && $0 <= 7680 }) else {
                    throw OptionError("--display needs WxH, e.g. 1920x1080")
                }
                displayWidth = parts[0]
                displayHeight = parts[1]
            case "--probe": probe = true
            // LaunchServices adds this when the app is started from Finder or `open`.
            case let s where s.hasPrefix("-psn_"): break
            default: throw OptionError("unknown argument \(a)")
            }
        }
    }
}

struct OptionError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// Timestamped log to stdout and, with --out, to log.txt.
enum Log {
    private static let lock = NSLock()
    private static var file: FileHandle?
    private static let start = Date()

    static func open(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("log.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
    }

    static var elapsed: Double { Date().timeIntervalSince(start) }

    static func line(_ s: String) {
        let text = String(format: "[%7.2f] ", elapsed) + s + "\n"
        lock.withLock {
            FileHandle.standardOutput.write(Data(text.utf8))
            file?.write(Data(text.utf8))
        }
    }
}

/// Active displays as "id WxH (main|virtual)" for the log.
func describeDisplays(virtual: CGDirectDisplayID? = nil) -> String {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return "\(count) active: " + ids.map { id in
        var s = "\(id) \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
        if CGDisplayIsMain(id) != 0 { s += " main" }
        if id == virtual { s += " virtual" }
        return s
    }.joined(separator: ", ")
}

/// Head tracking fed by GlassesLink threads and read by the renderer on the main thread.
final class HeadState: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker: HeadTracker?
    private var pending: [IMUSample] = []
    private var recenterAfterNs: UInt64?
    private(set) var calibration: FactoryCalibration?
    private var connected: Set<GlassesLink.Channel> = []
    private var lastEvent = ""

    func handle(_ event: GlassesLink.Event) {
        switch event {
        case .connected(let c):
            lock.withLock { _ = connected.insert(c) }
            Log.line("glasses: \(c) connected")
        case .disconnected(let c, let reason):
            let was = lock.withLock { connected.remove(c) != nil }
            if was { Log.line("glasses: \(c) disconnected: \(reason)") }
        case .sensor(.imu(let s)):
            lock.withLock {
                guard tracker != nil else {
                    pending.append(s)
                    if pending.count > 2000 { pending.removeFirst(pending.count - 2000) }
                    return
                }
                tracker!.update(s)
                // Recenter once, half a second after tracking starts, so the screen begins straight ahead.
                if let after = recenterAfterNs, s.timestampNs >= after {
                    tracker!.recenter()
                    recenterAfterNs = nil
                }
            }
        case .sensor:
            break
        case .control(.reply(let r)) where r.command == .factoryConfig:
            do {
                let c = try FactoryCalibration(reply: r)
                lock.withLock {
                    calibration = c
                    if tracker == nil {
                        var t = HeadTracker(calibration: c.imu)
                        pending.forEach { t.update($0) }
                        pending = []
                        tracker = t
                        recenterAfterNs = t.lastTimestampNs.map { $0 + 500_000_000 }
                    }
                }
                Log.line("glasses: factory calibration loaded (\(r.body.count) bytes)")
            } catch {
                Log.line("glasses: factory calibration NOT decodable: \(error)")
            }
        case .control(.reply(let r)):
            let value = (try? r.stringValue()) ?? (try? r.integerValue()).map(String.init) ?? "?"
            Log.line("glasses: \(r.command) = \(value)")
        case .control(.button(let b)):
            lock.withLock { lastEvent = "button \(b.key) \(b.state)" }
            Log.line("glasses: button \(b.key) \(b.state)")
        case .control(.wear(let w)):
            lock.withLock { lastEvent = "wear \(w)" }
            Log.line("glasses: wear \(w)")
        case .control:
            break
        }
    }

    func recenter() {
        lock.withLock { tracker?.recenter() }
    }

    /// Head orientation (head → world, recentered); identity until tracking starts.
    var orientation: Quat { lock.withLock { tracker?.orientation ?? .identity } }

    var status: String {
        lock.withLock {
            guard let t = tracker else {
                return connected.isEmpty ? "Glasses: not connected" : "Glasses: connected, waiting for calibration"
            }
            let p = t.pose
            return String(format: "Glasses: yaw %.0f° pitch %.0f° roll %.0f°", p.yaw, p.pitch, p.roll)
                + (lastEvent.isEmpty ? "" : " · \(lastEvent)")
        }
    }
}
#endif
