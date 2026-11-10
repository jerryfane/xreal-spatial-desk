/// One frame from the sensor port (52998): magic `0x2836`, 128-byte payload.
/// Offsets below are into the payload; BRIEF.md gives them into the whole frame (6 bytes more).
public enum SensorMessage: Equatable, Sendable {
    case imu(IMUSample)
    case magnetometer(MagnetometerSample)
    case other(kind: UInt32, timestampNs: UInt64)

    public static let magic: UInt16 = 0x2836
    public static let payloadSize = 128

    static let timestampOffset = 8   // u64 LE, device clock, ns
    static let kindOffset = 24       // u32 LE
    static let valuesOffset = 28     // f32 LE: gyro xyz, accel xyz, mag xyz, temperature

    public init?(_ frame: Frame) {
        let p = frame.payload
        guard frame.magic == SensorMessage.magic, p.count >= SensorMessage.payloadSize else { return nil }
        let ts = p.u64LE(at: SensorMessage.timestampOffset)
        let kind = p.u32LE(at: SensorMessage.kindOffset)
        func vec(_ i: Int) -> Vec3 {
            let o = SensorMessage.valuesOffset + 4 * i
            return Vec3(Double(p.f32LE(at: o)), Double(p.f32LE(at: o + 4)), Double(p.f32LE(at: o + 8)))
        }
        let temperature = Double(p.f32LE(at: SensorMessage.valuesOffset + 36))
        switch kind {
        case 0x0B:
            self = .imu(IMUSample(timestampNs: ts, gyro: vec(0), accel: vec(3), temperature: temperature))
        case 0x04:
            self = .magnetometer(MagnetometerSample(timestampNs: ts, field: vec(6), temperature: temperature))
        default:
            self = .other(kind: kind, timestampNs: ts)
        }
    }
}

/// Kind `0x0B`, 1000 Hz. Sensor axes: X right, Y down, Z forward (derived from the capture: gravity reads −Y,
/// looking up puts it on +Z, turning left is negative rotation about Y, tilting left negative about Z).
public struct IMUSample: Equatable, Sendable {
    public var timestampNs: UInt64
    /// rad/s, raw (uncalibrated)
    public var gyro: Vec3
    /// m/s², raw; at rest this is the specific force, i.e. it points up
    public var accel: Vec3
    /// °C
    public var temperature: Double

    public init(timestampNs: UInt64, gyro: Vec3, accel: Vec3, temperature: Double) {
        self.timestampNs = timestampNs
        self.gyro = gyro
        self.accel = accel
        self.temperature = temperature
    }
}

/// Kind `0x04`, 400 Hz. Gyro/accel slots are NaN; three floats at the magnetometer slot (|v| ≈ 62, unit unknown,
/// probably µT) and a temperature that stays 25.0. Parsed for completeness; head tracking does not use it.
public struct MagnetometerSample: Equatable, Sendable {
    public var timestampNs: UInt64
    public var field: Vec3
    public var temperature: Double
}
