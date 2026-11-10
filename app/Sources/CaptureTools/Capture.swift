import Foundation
import XRealCore

/// A session recorded by tools/record_session.py (`captures/<timestamp>/`).
public struct Capture {
    public struct Marker: Equatable, Sendable {
        public var name: String
        /// Recorder clock, ns.
        public var hostNs: Int64
    }

    public struct LoadError: Error, CustomStringConvertible {
        public var description: String
    }

    public let directory: URL
    /// Recorded steps in order; the last one is "end".
    public let markers: [Marker]
    /// device timestamp − recorder timestamp, ns (median over the first sensor frames).
    public let deviceClockOffsetNs: Int64
    public let calibration: FactoryCalibration

    public init(directory: URL) throws {
        self.directory = directory
        markers = try Capture.text(directory, "markers.jsonl").split(separator: "\n").map { line in
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            guard let name = o?["marker"] as? String, let t = (o?["t_ns"] as? NSNumber)?.int64Value else {
                throw LoadError(description: "bad marker line: \(line)")
            }
            return Marker(name: name, hostNs: t)
        }
        guard markers.count >= 2 else { throw LoadError(description: "markers.jsonl has fewer than 2 markers") }
        deviceClockOffsetNs = try Capture.clockOffset(directory)
        let gets = try JSONSerialization.jsonObject(with: Capture.data(directory, "control_gets.json")) as? [String: Any]
        guard let factory = gets?["factory_config"] as? [String: Any], let hex = factory["reply_hex"] as? String,
              let body = [UInt8](hex: hex) else {
            throw LoadError(description: "control_gets.json has no factory_config reply")
        }
        calibration = try FactoryCalibration(reply: GetReply(command: .factoryConfig, transactionID: 0, body: body))
    }

    /// Device timestamp of a marker, ns.
    public func deviceTime(of marker: Marker) -> Int64 { marker.hostNs + deviceClockOffsetNs }

    /// Seconds from the first marker (where tools/fake_glasses.py starts playback) for a device timestamp.
    public func seconds(deviceNs: UInt64) -> Double {
        Double(Int64(bitPattern: deviceNs) - deviceTime(of: markers[0])) / 1e9
    }

    /// Marker start times in seconds from the first marker.
    public var markerSeconds: [(name: String, start: Double)] {
        markers.map { ($0.name, Double($0.hostNs - markers[0].hostNs) / 1e9) }
    }

    /// Every IMU sample of the raw sensor stream (raw_52998.bin), byte-exact as the glasses sent it.
    public func imuSamples() throws -> [IMUSample] {
        var decoder = FrameDecoder()
        return try decoder.push(Capture.data(directory, "raw_52998.bin")).compactMap { frame in
            if case .imu(let s)? = SensorMessage(frame) { return s }
            return nil
        }
    }

    /// Reads `name` or, if absent, `name.gz` (committed captures are gzipped).
    static func data(_ dir: URL, _ name: String) throws -> Data {
        let plain = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: plain.path) { return try Data(contentsOf: plain) }
        let gz = dir.appendingPathComponent(name + ".gz")
        guard FileManager.default.fileExists(atPath: gz.path) else {
            throw LoadError(description: "missing \(plain.path)[.gz]")
        }
        return try gunzip(gz)
    }

    static func text(_ dir: URL, _ name: String) throws -> String {
        String(decoding: try data(dir, name), as: UTF8.self)
    }

    /// Foundation has no gzip API on Linux; use the system tool on both platforms.
    static func gunzip(_ url: URL) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gzip", "-dc", url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw LoadError(description: "gzip -dc \(url.path) failed") }
        return data
    }

    /// frames.jsonl stores each frame with the recorder's receive time; IMU frames also carry the device time.
    private static func clockOffset(_ dir: URL) throws -> Int64 {
        let text = try Capture.text(dir, "frames.jsonl")
        var offsets: [Int64] = []
        for line in text.split(separator: "\n") {
            guard line.contains("\"port\": 52998"), line.contains("\"dir\": \"rx\"") else { continue }
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            guard let t = (o?["t_ns"] as? NSNumber)?.int64Value, let hex = o?["hex"] as? String,
                  let bytes = [UInt8](hex: hex) else { continue }
            var decoder = FrameDecoder()
            guard let frame = try decoder.push(bytes).first, case .imu(let s)? = SensorMessage(frame) else { continue }
            offsets.append(Int64(bitPattern: s.timestampNs) - t)
            if offsets.count == 2000 { break }
        }
        guard !offsets.isEmpty else { throw LoadError(description: "frames.jsonl has no IMU frames") }
        return offsets.sorted()[offsets.count / 2]
    }
}

extension Array where Element == UInt8 {
    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }
}
