import Foundation

/// Head orientation in degrees.
///
/// World frame: Y down (gravity), Z forward at the recentered heading, X right; the same axes as the sensor.
/// `orientation = Ry(yaw) · Rx(pitch) · Rz(roll)`, so:
/// yaw > 0 turns right, pitch > 0 looks up, roll > 0 tilts toward the right shoulder.
public struct HeadPose: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public init(_ q: Quat) {
        let w = q.w, x = q.x, y = q.y, z = q.z
        let r02 = 2 * (x * z + w * y)
        let r10 = 2 * (x * y + w * z)
        let r11 = 1 - 2 * (x * x + z * z)
        let r12 = 2 * (y * z - w * x)
        let r22 = 1 - 2 * (x * x + y * y)
        let deg = 180 / Double.pi
        yaw = atan2(r02, r22) * deg
        pitch = asin(max(-1, min(1, -r12))) * deg
        roll = atan2(r10, r11) * deg
    }

    public var quaternion: Quat {
        let rad = Double.pi / 180
        return Quat(axis: Vec3(0, 1, 0), angle: yaw * rad)
            * Quat(axis: Vec3(1, 0, 0), angle: pitch * rad)
            * Quat(axis: Vec3(0, 0, 1), angle: roll * rad)
    }
}

/// Gyro integration with accelerometer tilt correction (Mahony-style complementary filter) and the factory
/// gyro/accel calibration, including the temperature-dependent gyro bias.
///
/// Gravity holds pitch and roll; yaw has no absolute reference, so its drift is set by how well the factory bias
/// matches the real one. `recenter()` resets the heading.
public struct HeadTracker: Sendable {
    public struct Options: Equatable, Sendable {
        /// Gain pulling the estimated gravity toward the measured one, rad/s per unit of error (time constant ≈ 1/gain).
        public var tiltGain = 0.5
        /// Accel samples whose magnitude differs from g by more than this (m/s²) are not trusted for tilt (head
        /// accelerating).
        public var accelGate = 1.0
        /// Larger gaps between samples (reconnect, replay loop) restart integration instead of integrating them.
        public var maxGap = 0.05

        public init() {}
    }

    public static let gravity = 9.80665

    public var options: Options
    public private(set) var calibration: IMUCalibration
    /// Head → world, before recentering.
    public private(set) var rawOrientation = Quat.identity
    /// Heading removed by the last recenter.
    public private(set) var reference = Quat.identity
    public private(set) var isInitialized = false
    public private(set) var lastTimestampNs: UInt64?
    /// Calibrated angular rate of the last sample, rad/s, head frame.
    public private(set) var angularRate = Vec3.zero

    public init(calibration: IMUCalibration, options: Options = Options()) {
        self.calibration = calibration
        self.options = options
    }

    /// Orientation relative to the recentered heading (head → world).
    public var orientation: Quat { (reference.conjugate * rawOrientation).normalized }

    public var pose: HeadPose { HeadPose(orientation) }

    public mutating func update(_ sample: IMUSample) {
        let accel = calibration.accel(sample)
        var rate = calibration.gyro(sample)
        guard rate.x.isFinite, rate.y.isFinite, rate.z.isFinite,
              accel.x.isFinite, accel.y.isFinite, accel.z.isFinite else { return }
        angularRate = rate

        guard isInitialized, let last = lastTimestampNs, sample.timestampNs > last,
              Double(sample.timestampNs - last) / 1e9 <= options.maxGap else {
            if !isInitialized { initialize(accel: accel) }
            lastTimestampNs = sample.timestampNs
            return
        }
        let dt = Double(sample.timestampNs - last) / 1e9
        lastTimestampNs = sample.timestampNs

        // Tilt correction: turn so that predicted gravity (down) in the head frame moves toward measured down.
        let norm = accel.length
        if abs(norm - HeadTracker.gravity) < options.accelGate {
            let measuredDown = -accel * (1 / norm)
            let predictedDown = rawOrientation.conjugate.rotate(Vec3(0, 1, 0))
            rate = rate + measuredDown.cross(predictedDown) * options.tiltGain
        }
        rawOrientation = (rawOrientation * Quat(rotationVector: rate * dt)).normalized
    }

    /// Makes the current heading the new forward direction (yaw 0). Pitch and roll stay gravity-referenced.
    public mutating func recenter() {
        reference = HeadTracker.heading(of: rawOrientation)
    }

    /// The yaw-only part of `q` (rotation about world Y).
    static func heading(of q: Quat) -> Quat {
        Quat(axis: Vec3(0, 1, 0), angle: HeadPose(q).yaw * .pi / 180)
    }

    private mutating func initialize(accel: Vec3) {
        guard accel.length > 1 else { return }
        // At rest the accelerometer reads "up"; rotate head-frame down (−accel) onto world +Y, then drop any heading
        // so yaw starts at 0.
        let q = Quat(from: (-accel).normalized, to: Vec3(0, 1, 0))
        rawOrientation = (HeadTracker.heading(of: q).conjugate * q).normalized
        reference = .identity
        isInitialized = true
    }
}
