import CaptureTools
import Foundation
import XCTest
@testable import XRealCore

final class CaptureToolsTests: XCTestCase {
    func testReportOnARecordingThatEndsEarly() {
        // Two seconds of samples; the steps after them have no data (playback stopped early).
        var track = PoseTrack()
        for i in 0..<2000 {
            track.append(time: Double(i) / 1000, pose: HeadPose(yaw: 0, pitch: 0, roll: 0), rate: 0)
        }
        let markers = [(name: "still_center", start: 0.0), (name: "yaw_left", start: 6.0),
                       (name: "still_end", start: 88.0), (name: "end", start: 93.0)]
        let report = TrackingReport(track: track, markers: markers)
        XCTAssertEqual(report.steps.map(\.name), ["still_center"])
        XCTAssertEqual(report.still.map(\.step), ["still_center"])
        XCTAssertNil(report.startToEnd)
        XCTAssertFalse(report.formatted().isEmpty)
    }

    func testCaptureWithCompactJSONLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xreal-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: Fixtures.captureDirectory.appendingPathComponent("control_gets.json.gz"),
                                         to: dir.appendingPathComponent("control_gets.json.gz"))
        try #"{"t_ns":0,"marker":"still_center"}"#.appending("\n").appending(#"{"t_ns":1000000000,"marker":"end"}"#)
            .write(to: dir.appendingPathComponent("markers.jsonl"), atomically: true, encoding: .utf8)
        // An IMU frame (device time 0x0C34BA2D18 ns) received at recorder time 5 ms, written without spaces.
        let imu = "28360000008088bcff0000000000182dba340c000000911f0000000000000b00000002090fbeafd86f3e63149d3dcd6cecbee6191ac1cdbcfbbf000048c5000048c5000048c50000ec4102fbc30000401f0000400000000000000000000000f07e0e00000000888520887f000000d01464887f00000000000000000000000000000000000000"
        try #"{"t_ns":5000000,"port":52998,"dir":"rx","magic":"0x2836","len":134,"hex":"\#(imu)"}"#
            .write(to: dir.appendingPathComponent("frames.jsonl"), atomically: true, encoding: .utf8)

        let capture = try Capture(directory: dir)
        XCTAssertEqual(capture.deviceClockOffsetNs, 0x0C_34BA_2D18 - 5_000_000)
    }
}
