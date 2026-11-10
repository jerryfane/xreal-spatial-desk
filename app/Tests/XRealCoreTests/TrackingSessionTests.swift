import CaptureTools
import Foundation
import XCTest
@testable import XRealCore

final class TrackingSessionTests: XCTestCase {
    func calibration() throws -> FactoryCalibration { try Fixtures.capture().calibration }

    /// Level head turning right at 0.5 rad/s, one sample per ms from `start`.
    func samples(_ count: Int, from start: Int = 0) -> [IMUSample] {
        (start..<(start + count)).map { i in
            IMUSample(timestampNs: 1_000_000_000 + UInt64(i) * 1_000_000, gyro: Vec3(0, 0.5, 0),
                      accel: Vec3(0, -HeadTracker.gravity, 0), temperature: 30)
        }
    }

    func testAutoRecenterHappensWhicheverArrivesFirst() throws {
        let c = try calibration()
        var noCalibration = c
        noCalibration.imu = .identity  // exact rates, so the expected yaw is simple

        // Calibration first, then samples.
        let first = TrackingSession()
        first.setCalibration(noCalibration)
        samples(800).forEach(first.add)

        // Samples first (buffered), then calibration, then more samples.
        let later = TrackingSession()
        samples(300).forEach(later.add)
        later.setCalibration(noCalibration)
        samples(500, from: 300).forEach(later.add)

        // Recentered at 0.5 s, so 0.3 s of turning at 0.5 rad/s remain: ≈ 8.6°, not ≈ 22.9°.
        for session in [first, later] {
            XCTAssertEqual(try XCTUnwrap(session.pose).yaw, 0.299 * 0.5 * 180 / .pi, accuracy: 0.2)
        }
    }

    func testNoPoseBeforeTracking() throws {
        let session = TrackingSession()
        samples(10).forEach(session.add)
        XCTAssertNil(session.pose)
        XCTAssertEqual(session.orientation, .identity)
        session.setCalibration(try calibration())
        XCTAssertNotNil(session.pose)
    }
}
