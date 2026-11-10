import Foundation
import XCTest
import GlassesLink
import XRealCore

/// End to end against tools/fake_glasses.py on 127.0.0.1 (needs python3; skipped otherwise). Uses the fixed
/// ports 52998/52999, so it cannot run next to another fake glasses instance.
final class FakeGlassesTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Runs tools/fake_glasses.py; stdin stays open for its commands.
    final class FakeGlasses {
        let process = Process()
        let stdin = Pipe()
        private let output = Pipe()
        private let lock = NSLock()
        private var log = ""

        init(arguments: [String] = []) throws {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", "tools/fake_glasses.py", "captures/20261110-140512", "--host", "127.0.0.1"] + arguments
            process.currentDirectoryURL = FakeGlassesTests.repoRoot
            process.standardInput = stdin
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { [weak self] h in
                let s = String(decoding: h.availableData, as: UTF8.self)
                self?.lock.withLock { self?.log += s }
            }
            try process.run()
        }

        var text: String { lock.withLock { log } }

        func waitFor(_ needle: String, timeout: TimeInterval = 60) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if text.contains(needle) { return true }
                if !process.isRunning { return false }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }

        func command(_ line: String) {
            stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
        }

        func stop() {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            output.fileHandleForReading.readabilityHandler = nil
        }

        deinit { stop() }
    }

    /// Collects link events.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [GlassesLink.Event] = []
        private(set) var imuCount = 0

        func record(_ e: GlassesLink.Event) {
            lock.withLock {
                if case .sensor(.imu) = e { imuCount += 1 } else if case .sensor = e {} else { events.append(e) }
            }
        }

        var snapshot: (events: [GlassesLink.Event], imu: Int) { lock.withLock { (events, imuCount) } }

        func wait(timeout: TimeInterval = 20, until done: ([GlassesLink.Event], Int) -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                let s = snapshot
                if done(s.events, s.imu) { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return false
        }
    }

    static func replies(_ events: [GlassesLink.Event]) -> [GetCommand: GetReply] {
        var out: [GetCommand: GetReply] = [:]
        for case .control(.reply(let r)) in events { out[r.command] = r }
        return out
    }

    struct FakeDidNotStart: Error {
        var log: String
    }

    func startFake(_ arguments: [String] = ["--loop"]) throws -> FakeGlasses {
        let fake: FakeGlasses
        do { fake = try FakeGlasses(arguments: arguments) } catch { throw XCTSkip("cannot run python3: \(error)") }
        guard fake.waitFor("serving fake glasses") else {
            fake.stop()
            throw FakeDidNotStart(log: fake.text)  // e.g. the ports are taken by another fake
        }
        return fake
    }

    /// Ports where nothing listens: the link keeps failing to connect and retrying.
    static var unreachable: GlassesLink.Configuration {
        var config = GlassesLink.Configuration(host: "127.0.0.1")
        config.sensorPort = 1
        config.controlPort = 2
        config.maxReconnectDelay = 0.25
        return config
    }

    func testBothHandlersCanStopTheLinkAtOnce() {
        // Both connections fail; each channel's handler calls stop() on its first disconnect, after waiting until the
        // other handler is also in the callback, so the two stop() calls overlap.
        final class Shared: @unchecked Sendable {
            let lock = NSLock()
            var link: GlassesLink?
            var arrived: Set<String> = []
            let bothArrived = DispatchSemaphore(value: 0)
            let returned = DispatchSemaphore(value: 0)
        }
        let s = Shared()
        let link = GlassesLink(configuration: Self.unreachable) { event in
            guard case .disconnected(let channel, _) = event else { return }
            let (first, both) = s.lock.withLock { () -> (Bool, Bool) in
                let first = s.arrived.insert(channel.rawValue).inserted
                return (first, s.arrived.count == 2)
            }
            guard first else { return }
            if both { s.bothArrived.signal(); s.bothArrived.signal() }
            _ = s.bothArrived.wait(timeout: .now() + 3)
            s.lock.withLock { s.link }?.stop()
            s.returned.signal()
        }
        s.lock.withLock { s.link = link }
        link.start()
        XCTAssertEqual(s.returned.wait(timeout: .now() + 5), .success, "first handler's stop() returned")
        XCTAssertEqual(s.returned.wait(timeout: .now() + 5), .success, "second handler's stop() returned")
        XCTAssertEqual(s.lock.withLock { s.arrived.count }, 2, "both handlers were in stop() together")
        let t = Date()
        link.stop()  // from outside: joins the (already finishing) workers
        XCTAssertLessThan(Date().timeIntervalSince(t), 2)
        s.lock.withLock { s.link = nil }
    }

    func testReleasingTheLinkStopsItsThreads() {
        let recorder = Recorder()
        weak var weakLink: GlassesLink?
        do {
            let link = GlassesLink(configuration: Self.unreachable) { recorder.record($0) }
            weakLink = link
            link.start()
            XCTAssertTrue(recorder.wait(timeout: 5) { events, _ in events.count >= 2 })
        }
        XCTAssertNil(weakLink, "the worker threads do not keep the link alive")
        let count = recorder.snapshot.events.count
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(recorder.snapshot.events.count, count, "no reconnect attempts after release")
    }

    func testStreamsGetRepliesAndEvents() throws {
        let fake = try startFake()
        defer { fake.stop() }
        let recorder = Recorder()
        let link = GlassesLink(configuration: .init(host: "127.0.0.1")) { recorder.record($0) }
        link.start()
        defer { link.stop() }

        XCTAssertTrue(recorder.wait { events, imu in Self.replies(events).count == 5 && imu >= 2000 },
                      "events: \(recorder.snapshot.events.count), imu: \(recorder.snapshot.imu)")
        let replies = Self.replies(recorder.snapshot.events)
        XCTAssertEqual(try replies[.firmwareVersion]?.stringValue(), "1.9.1.20260914175625")
        XCTAssertEqual(try replies[.dspVersion]?.stringValue(), "15.A.00.069_20241211")
        XCTAssertEqual(try replies[.serialNumber]?.stringValue(), "REDACTED00")
        XCTAssertEqual(try replies[.displayConfig]?.integerValue(), 9)
        let calibration = try FactoryCalibration(reply: try XCTUnwrap(replies[.factoryConfig]))
        XCTAssertEqual(calibration.displays.width, 1920)
        XCTAssertFalse(fake.text.contains("unrecorded command"), "only recorded GETs were sent")

        // Wear and button events from the fake's stdin commands.
        fake.command("off")
        fake.command("press 3")
        XCTAssertTrue(recorder.wait { events, _ in
            events.contains { if case .control(.wear(.takenOff)) = $0 { return true }; return false }
                && events.contains { if case .control(.button(ButtonEvent(key: 3, state: .up))) = $0 { return true }; return false }
        })
    }

    func testReconnectsAfterTheGlassesGoAway() throws {
        var fake = try startFake()
        let recorder = Recorder()
        var config = GlassesLink.Configuration(host: "127.0.0.1")
        config.maxReconnectDelay = 0.5
        let link = GlassesLink(configuration: config) { recorder.record($0) }
        link.start()
        defer { link.stop() }
        XCTAssertTrue(recorder.wait { _, imu in imu >= 500 })
        fake.stop()

        XCTAssertTrue(recorder.wait { events, _ in
            events.filter { if case .disconnected = $0 { return true }; return false }.count >= 2
        })
        let before = recorder.snapshot.imu
        fake = try startFake()
        defer { fake.stop() }
        XCTAssertTrue(recorder.wait { events, imu in imu >= before + 500 && Self.replies(events).count == 5 })
        let connects = recorder.snapshot.events.filter { if case .connected = $0 { return true }; return false }.count
        XCTAssertGreaterThanOrEqual(connects, 4)  // both channels, twice
    }

    func testStopReturnsWhileTheGlassesAreUnreachable() {
        // Nothing listens on these ports; the link keeps retrying until stopped.
        var config = GlassesLink.Configuration(host: "127.0.0.1")
        config.sensorPort = 1
        config.controlPort = 2
        let recorder = Recorder()
        let link = GlassesLink(configuration: config) { recorder.record($0) }
        link.start()
        XCTAssertTrue(recorder.wait(timeout: 5) { events, _ in events.count >= 2 })
        let t = Date()
        link.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
        XCTAssertThrowsError(try link.send(.firmwareVersion))
    }
}
