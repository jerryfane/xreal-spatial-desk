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
    /// Switch the glasses to side-by-side input mode at start (restored on quit).
    var sbs = false
    /// Only run the scripted side-by-side check (read, switch, read back, restore, read back) and quit.
    var sbsCheck = false
    var displayWidth = 1920
    var displayHeight = 1080
    /// Show the side-by-side frame full screen on this display (e.g. the glasses) instead of in a window.
    var outputDisplay: CGDirectDisplayID?

    static let usage = """
    XRealDesk [--host ADDR] [--seconds N] [--out DIR] [--snapshots T1,T2,...] [--display WxH] [--output ID] [--sbs]
              [--probe | --sbs-check]
      --host       glasses address (default 169.254.2.1; 127.0.0.1 for tools/fake_glasses.py)
      --seconds    quit after N seconds
      --out        write log.txt and snapshot PNGs here
      --snapshots  save the rendered side-by-side frame at these seconds after launch
      --display    virtual display size in pixels (default 1920x1080)
      --output     show the 3840×1080 side-by-side image full screen on this display ID (see the log's display
                   list) instead of in a half-size window
      --sbs        switch the glasses to side-by-side 3D at start; the original mode is restored on quit, and on the
                   next start if the app crashed
      --probe      create the virtual display, list displays, remove it and quit (no capture, no permissions)
      --sbs-check  read the glasses' mode, switch to side-by-side, read back, restore, read back, then quit;
                   exit 0 only if every step matched (no virtual display, no capture)
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
            case "--sbs": sbs = true
            case "--sbs-check": sbsCheck = true
            case "--output":
                guard let id = UInt32(try value(a)) else { throw OptionError("--output needs a display ID") }
                outputDisplay = id
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

/// Glasses events → head tracking (`TrackingSession`, thread-safe) plus log lines and menu status.
/// Fed by GlassesLink threads, read by the renderer and menu on the main thread.
final class HeadState: @unchecked Sendable {
    private let session = TrackingSession()
    private let lock = NSLock()
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
            session.add(s)
        case .sensor:
            break
        case .control(.reply(let r)) where r.command == .factoryConfig:
            do {
                session.setCalibration(try FactoryCalibration(reply: r))
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

    func recenter() { session.recenter() }

    var calibration: FactoryCalibration? { session.calibration }

    /// Head orientation (head → world, recentered); identity until tracking starts.
    var orientation: Quat { session.orientation }

    var status: String {
        guard let p = session.pose else {
            return lock.withLock { connected.isEmpty } ? "Glasses: not connected" : "Glasses: connected, waiting for tracking"
        }
        let event = lock.withLock { lastEvent }
        return String(format: "Glasses: yaw %.0f° pitch %.0f° roll %.0f°", p.yaw, p.pitch, p.roll)
            + (event.isEmpty ? "" : " · \(event)")
    }
}
#endif
