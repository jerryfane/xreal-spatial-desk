import CaptureTools
import XCTest
@testable import XRealCore

final class HeadTrackerTests: XCTestCase {
    /// Accelerometer reading at rest for a head with orientation `q` (head → world, world Y down): "up" in head frame.
    func restAccel(_ q: Quat) -> Vec3 { q.conjugate.rotate(Vec3(0, -HeadTracker.gravity, 0)) }

    /// Feeds `seconds` of 1000 Hz samples rotating at `rate` (rad/s, head frame) from orientation `start`.
    func spin(_ tracker: inout HeadTracker, from start: Quat, rate: Vec3, seconds: Double, t0: UInt64 = 1_000_000_000) -> Quat {
        var q = start
        let n = Int(seconds * 1000)
        for i in 0...n {
            tracker.update(IMUSample(timestampNs: t0 + UInt64(i) * 1_000_000, gyro: rate, accel: restAccel(q), temperature: 30))
            q = (q * Quat(rotationVector: rate * 0.001)).normalized
        }
        return q
    }

    func testTurningRightIsPositiveYaw() {
        var t = HeadTracker(calibration: .identity)
        _ = spin(&t, from: .identity, rate: Vec3(0, 90 * .pi / 180, 0), seconds: 0.5)
        XCTAssertEqual(t.pose.yaw, 45, accuracy: 0.2)
        XCTAssertEqual(t.pose.pitch, 0, accuracy: 0.2)
        XCTAssertEqual(t.pose.roll, 0, accuracy: 0.2)
    }

    func testLookingUpIsPositivePitchAndRightEarDownIsPositiveRoll() {
        var t = HeadTracker(calibration: .identity)
        // Looking up rotates forward (+Z) toward up (−Y): positive rotation about +X.
        let q = spin(&t, from: .identity, rate: Vec3(30 * .pi / 180, 0, 0), seconds: 1)
        XCTAssertEqual(t.pose.pitch, 30, accuracy: 0.3)
        // Right ear down rotates right (+X) toward down (+Y): positive rotation about +Z.
        _ = spin(&t, from: q, rate: Vec3(0, 0, 20 * .pi / 180), seconds: 1, t0: 3_000_000_000)
        XCTAssertEqual(t.pose.roll, 20, accuracy: 0.3)
        XCTAssertEqual(t.pose.pitch, 30, accuracy: 0.3)
    }

    func testInitialAttitudeComesFromGravity() {
        var t = HeadTracker(calibration: .identity)
        let tilted = HeadPose(yaw: 70, pitch: -20, roll: 10).quaternion
        t.update(IMUSample(timestampNs: 1, gyro: .zero, accel: restAccel(tilted), temperature: 30))
        XCTAssertEqual(t.pose.yaw, 0, accuracy: 1e-6)  // no heading reference at start
        XCTAssertEqual(t.pose.pitch, -20, accuracy: 1e-6)
        XCTAssertEqual(t.pose.roll, 10, accuracy: 1e-6)
    }

    func testGravityPullsTiltBackButNotYaw() {
        var t = HeadTracker(calibration: .identity)
        // A constant gyro error about every axis while the head is actually still and level.
        let bias = Vec3(0.01, 0.01, 0.01)
        for i in 0...60_000 {
            t.update(IMUSample(timestampNs: UInt64(i) * 1_000_000, gyro: bias, accel: Vec3(0, -HeadTracker.gravity, 0), temperature: 30))
        }
        // Tilt error stays bounded near bias/gain (≈1.1°); yaw integrates the full error (0.01 rad/s × 60 s = 34°).
        XCTAssertLessThan(abs(t.pose.pitch), 2)
        XCTAssertLessThan(abs(t.pose.roll), 2)
        XCTAssertEqual(t.pose.yaw, 34.4, accuracy: 1.5)
    }

    func testCalibrationRemovesFactoryBias() {
        var imu = IMUCalibration.identity
        imu.gyroBias = Vec3(0.004, -0.006, 0.003)
        var t = HeadTracker(calibration: imu)
        for i in 0...10_000 {
            t.update(IMUSample(timestampNs: UInt64(i) * 1_000_000, gyro: imu.gyroBias, accel: Vec3(0, -HeadTracker.gravity, 0), temperature: 30))
        }
        XCTAssertEqual(t.pose.yaw, 0, accuracy: 1e-9)
    }

    func testStrongLinearAccelerationDoesNotTiltTheView() {
        var t = HeadTracker(calibration: .identity)
        // Head still and level, then pushed sideways at 5 m/s² for 1 s (|a| ≈ 11 m/s²): not gravity, so not used for tilt.
        t.update(IMUSample(timestampNs: 0, gyro: .zero, accel: Vec3(0, -HeadTracker.gravity, 0), temperature: 30))
        for i in 1...1000 {
            t.update(IMUSample(timestampNs: UInt64(i) * 1_000_000, gyro: .zero, accel: Vec3(5, -HeadTracker.gravity, 0), temperature: 30))
        }
        XCTAssertLessThan(abs(t.pose.roll), 1)
    }

    func testRecenterZeroesYawAndKeepsTilt() {
        var t = HeadTracker(calibration: .identity)
        let q = spin(&t, from: .identity, rate: Vec3(0, 1, 0), seconds: 0.6)
        _ = spin(&t, from: q, rate: Vec3(-0.5, 0, 0), seconds: 0.4, t0: 2_000_000_000)
        let before = t.pose
        XCTAssertGreaterThan(before.yaw, 30)
        t.recenter()
        XCTAssertEqual(t.pose.yaw, 0, accuracy: 1e-6)
        XCTAssertEqual(t.pose.pitch, before.pitch, accuracy: 1e-6)
        XCTAssertEqual(t.pose.roll, before.roll, accuracy: 1e-6)
        // Later turns are measured from the new heading.
        var q2 = t.rawOrientation
        q2 = spin(&t, from: q2, rate: Vec3(0, -0.5, 0), seconds: 0.2, t0: 3_000_000_000)
        XCTAssertLessThan(t.pose.yaw, -3)
    }

    func testGapsAreNotIntegrated() {
        var t = HeadTracker(calibration: .identity)
        let level = Vec3(0, -HeadTracker.gravity, 0)
        t.update(IMUSample(timestampNs: 0, gyro: .zero, accel: level, temperature: 30))
        // A 2 s gap (reconnect) with a large rate must not turn the head by 2 rad.
        t.update(IMUSample(timestampNs: 2_000_000_000, gyro: Vec3(0, 1, 0), accel: level, temperature: 30))
        XCTAssertEqual(t.pose.yaw, 0, accuracy: 1e-9)
        t.update(IMUSample(timestampNs: 2_001_000_000, gyro: Vec3(0, 1, 0), accel: level, temperature: 30))
        XCTAssertEqual(t.pose.yaw, 0.001 * 180 / .pi, accuracy: 1e-6)
    }

    func testNonFiniteSamplesAreIgnored() {
        var t = HeadTracker(calibration: .identity)
        t.update(IMUSample(timestampNs: 0, gyro: .zero, accel: Vec3(0, -HeadTracker.gravity, 0), temperature: 30))
        t.update(IMUSample(timestampNs: 1_000_000, gyro: Vec3(.nan, 0, 0), accel: Vec3(0, -HeadTracker.gravity, 0), temperature: 30))
        XCTAssertFalse(t.pose.yaw.isNaN)
        XCTAssertEqual(t.lastTimestampNs, 0)
    }

    func testPoseQuaternionRoundTrip() {
        for p in [HeadPose(yaw: 35, pitch: -12, roll: 50), HeadPose(yaw: -170, pitch: 80, roll: -5)] {
            let back = HeadPose(p.quaternion)
            XCTAssertEqual(back.yaw, p.yaw, accuracy: 1e-9)
            XCTAssertEqual(back.pitch, p.pitch, accuracy: 1e-9)
            XCTAssertEqual(back.roll, p.roll, accuracy: 1e-9)
        }
    }
}

/// The tracker on the real 93 s recording: every recorded movement must come out on the right axis, with the right
/// sign and a plausible size, and the head must come back near where it started.
final class RecordingTrackingTests: XCTestCase {
    static let report: Result<TrackingReport, Error> = Result {
        let capture = try Fixtures.capture()
        let track = PoseTrack(samples: try capture.imuSamples(), tracker: HeadTracker(calibration: capture.calibration.imu),
                              time: { capture.seconds(deviceNs: $0.timestampNs) })
        return TrackingReport(track: track, markers: capture.markerSeconds)
    }

    func step(_ name: String) throws -> Excursion {
        try XCTUnwrap(Self.report.get().steps.first { $0.name == name }).excursion
    }

    func testYawSteps() throws {
        let left = try step("yaw_left"), right = try step("yaw_right")
        XCTAssertLessThan(left.yaw.lowerBound, -40)
        XCTAssertLessThan(left.yaw.upperBound, 10)
        XCTAssertGreaterThan(right.yaw.upperBound, 40)
        XCTAssertGreaterThan(right.yaw.lowerBound, -10)
        for e in [left, right] {
            XCTAssertLessThan(max(-e.pitch.lowerBound, e.pitch.upperBound), 10)
            XCTAssertLessThan(max(-e.roll.lowerBound, e.roll.upperBound), 10)
            XCTAssertLessThan(abs(e.net.yaw), 5, "returned to centre")
        }
    }

    func testPitchSteps() throws {
        let up = try step("pitch_up"), down = try step("pitch_down")
        XCTAssertGreaterThan(up.pitch.upperBound, 40)
        XCTAssertLessThan(down.pitch.lowerBound, -40)
        for e in [up, down] {
            XCTAssertLessThan(max(-e.yaw.lowerBound, e.yaw.upperBound), 10)
            XCTAssertLessThan(max(-e.roll.lowerBound, e.roll.upperBound), 10)
        }
    }

    func testRollStepTiltsLeftThenRight() throws {
        // The wearer lagged the prompts: the left tilt falls in the "roll" window, the right tilt in "nod".
        let roll = try step("roll"), late = try step("nod")
        XCTAssertLessThan(roll.roll.lowerBound, -40)
        XCTAssertGreaterThan(late.roll.upperBound, 40)
        XCTAssertLessThan(max(-roll.yaw.lowerBound, roll.yaw.upperBound), 10)
    }

    func testShakeIsYawOnly() throws {
        let shake = try Self.report.get().motions.first { $0.step == "shake" }
        let e = try XCTUnwrap(shake).excursion
        XCTAssertEqual(e.dominantAxis, "yaw")
        XCTAssertGreaterThan(e.yaw.upperBound - e.yaw.lowerBound, 30)
    }

    func testHeadReturnsNearTheStartAfter89Seconds() throws {
        let d = try XCTUnwrap(Self.report.get().startToEnd)
        // Bound, not a precise drift figure: it also contains how differently the wearer held their head.
        XCTAssertLessThan(abs(d.yaw), 12)
        XCTAssertLessThan(abs(d.pitch), 12)
        XCTAssertLessThan(abs(d.roll), 5)
    }
}
