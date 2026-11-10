import Foundation

/// The parts of the factory config (GET `0x271F`, JSON) the app uses.
public struct FactoryCalibration: Equatable, Sendable {
    public var imu: IMUCalibration
    public var displays: DisplayCalibration

    public struct InvalidConfig: Error, Equatable {
        public var field: String
    }

    /// Decodes the JSON carried in the factory config reply.
    public init(json: [UInt8]) throws {
        let raw = try JSONDecoder().decode(RawConfig.self, from: Data(json))
        try raw.validate()
        let d = raw.IMU.device_1
        let table = (d.gyro_bias_temp_data ?? []).map { TemperatureBias(temperature: $0.temp, bias: Vec3($0.bias)) }
        imu = IMUCalibration(
            gyroBias: Vec3(d.imu_intrinsics.gyro_bias),
            gyroBiasByTemperature: table.sorted { $0.temperature < $1.temperature },
            gyroMatrix: Mat3(rowMajor: d.imu_intrinsics.gyro_calib_mat),
            accelBias: Vec3(d.imu_intrinsics.accl_bias),
            accelMatrix: Mat3(rowMajor: d.imu_intrinsics.accl_calib_mat))
        let s = raw.display
        displays = DisplayCalibration(
            width: s.resolution[0], height: s.resolution[1],
            left: EyeCalibration(intrinsics: s.k_left_display, position: Vec3(s.target_p_left_display),
                                 rotation: Quat(hamiltonXYZW: s.target_q_left_display)),
            right: EyeCalibration(intrinsics: s.k_right_display, position: Vec3(s.target_p_right_display),
                                  rotation: Quat(hamiltonXYZW: s.target_q_right_display)))
    }

    public init(reply: GetReply) throws {
        try self.init(json: try reply.bytesValue())
    }

    public init(imu: IMUCalibration, displays: DisplayCalibration) {
        self.imu = imu
        self.displays = displays
    }
}

public struct TemperatureBias: Equatable, Sendable {
    public var temperature: Double
    public var bias: Vec3
}

/// Calibrated rate = gyroMatrix · (raw − bias(T)); calibrated accel = accelMatrix · (raw − accelBias).
///
/// The config has two bias sets: `IMU.device_1.{gyro,accel}_bias` and `imu_intrinsics.{gyro,accl}_bias`. The
/// intrinsics set is used because it comes with the calibration matrices. `accel_q_gyro` is identity and
/// `gyro_q_mag` only matters for the magnetometer, so neither is applied.
public struct IMUCalibration: Equatable, Sendable {
    public var gyroBias: Vec3
    /// Measured gyro bias per temperature (27–43 °C on the test unit). Interpolated, clamped at the ends.
    public var gyroBiasByTemperature: [TemperatureBias]
    public var gyroMatrix: Mat3
    public var accelBias: Vec3
    public var accelMatrix: Mat3

    public init(gyroBias: Vec3, gyroBiasByTemperature: [TemperatureBias], gyroMatrix: Mat3,
                accelBias: Vec3, accelMatrix: Mat3) {
        self.gyroBias = gyroBias
        self.gyroBiasByTemperature = gyroBiasByTemperature
        self.gyroMatrix = gyroMatrix
        self.accelBias = accelBias
        self.accelMatrix = accelMatrix
    }

    /// No correction at all.
    public static let identity = IMUCalibration(gyroBias: .zero, gyroBiasByTemperature: [], gyroMatrix: .identity,
                                                accelBias: .zero, accelMatrix: .identity)

    public func gyroBias(at temperature: Double) -> Vec3 {
        let t = gyroBiasByTemperature
        guard let first = t.first, let last = t.last, temperature.isFinite else { return gyroBias }
        if temperature <= first.temperature { return first.bias }
        if temperature >= last.temperature { return last.bias }
        let i = t.firstIndex { $0.temperature >= temperature }!
        let a = t[i - 1], b = t[i]
        let f = (temperature - a.temperature) / (b.temperature - a.temperature)
        return a.bias + (b.bias - a.bias) * f
    }

    public func gyro(_ s: IMUSample) -> Vec3 { gyroMatrix * (s.gyro - gyroBias(at: s.temperature)) }
    public func accel(_ s: IMUSample) -> Vec3 { accelMatrix * (s.accel - accelBias) }
}

public struct DisplayCalibration: Equatable, Sendable {
    /// Per-eye panel size in pixels (1920×1080).
    public var width: Int
    public var height: Int
    public var left: EyeCalibration
    public var right: EyeCalibration
}

public struct EyeCalibration: Equatable, Sendable {
    /// Row-major 3×3 pinhole matrix: fx, 0, cx / 0, fy, cy / 0, 0, 1 (pixels).
    public var intrinsics: [Double]
    /// Eye position relative to the IMU, metres (`target_p_*`).
    public var position: Vec3
    /// Eye rotation relative to the IMU (`target_q_*`).
    public var rotation: Quat

    public var fx: Double { intrinsics[0] }
    public var fy: Double { intrinsics[4] }
    public var cx: Double { intrinsics[2] }
    public var cy: Double { intrinsics[5] }
}

extension Vec3 {
    init(_ a: [Double]) {
        self.init(a[0], a[1], a[2])
    }
}

extension Quat {
    /// The config stores display quaternions as Hamilton (qx, qy, qz, qw).
    init(hamiltonXYZW q: [Double]) {
        self.init(w: q[3], x: q[0], y: q[1], z: q[2])
    }
}

// JSON layout of the factory config; only the fields read above.
private struct RawConfig: Decodable {
    struct IMUSection: Decodable {
        struct Device: Decodable {
            struct TempBias: Decodable {
                var bias: [Double]
                var temp: Double
            }

            struct Intrinsics: Decodable {
                var gyro_bias: [Double]
                var gyro_calib_mat: [Double]
                var accl_bias: [Double]
                var accl_calib_mat: [Double]
            }

            var gyro_bias_temp_data: [TempBias]?
            var imu_intrinsics: Intrinsics
        }

        var device_1: Device
    }

    struct Display: Decodable {
        var resolution: [Int]
        var k_left_display: [Double]
        var k_right_display: [Double]
        var target_p_left_display: [Double]
        var target_p_right_display: [Double]
        var target_q_left_display: [Double]
        var target_q_right_display: [Double]
    }

    var IMU: IMUSection
    var display: Display

    func validate() throws {
        let d = IMU.device_1
        let i = d.imu_intrinsics
        var counts: [(String, Int, Int)] = [
            ("gyro_bias", i.gyro_bias.count, 3), ("gyro_calib_mat", i.gyro_calib_mat.count, 9),
            ("accl_bias", i.accl_bias.count, 3), ("accl_calib_mat", i.accl_calib_mat.count, 9),
            ("resolution", display.resolution.count, 2),
            ("k_left_display", display.k_left_display.count, 9), ("k_right_display", display.k_right_display.count, 9),
            ("target_p_left_display", display.target_p_left_display.count, 3),
            ("target_p_right_display", display.target_p_right_display.count, 3),
            ("target_q_left_display", display.target_q_left_display.count, 4),
            ("target_q_right_display", display.target_q_right_display.count, 4),
        ]
        counts += (d.gyro_bias_temp_data ?? []).map { ("gyro_bias_temp_data.bias", $0.bias.count, 3) }
        for (field, count, expected) in counts where count != expected {
            throw FactoryCalibration.InvalidConfig(field: field)
        }
    }
}
