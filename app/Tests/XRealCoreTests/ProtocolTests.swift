import CaptureTools
import XCTest
@testable import XRealCore

final class FrameDecoderTests: XCTestCase {
    func testFramesSplitAcrossArbitraryChunksDecodeLikeOneWrite() throws {
        let frames = [
            Frame(magic: 0x2836, payload: Array(0..<128)),
            Frame(magic: 0x273D, payload: [0x18, 0x02]),
            Frame(magic: 0x271F, payload: []),
            Frame(magic: 0x272E, payload: Array(repeating: 7, count: 64)),
        ]
        let stream = frames.flatMap { $0.encoded() }
        for chunk in [1, 5, 6, 7, 133, stream.count] {
            var decoder = FrameDecoder()
            var out: [Frame] = []
            var i = 0
            while i < stream.count {
                out += try decoder.push(stream[i..<min(i + chunk, stream.count)])
                i += chunk
            }
            XCTAssertEqual(out, frames, "chunk size \(chunk)")
            XCTAssertEqual(decoder.pendingByteCount, 0)
        }
    }

    func testIncompleteFrameIsHeldBack() throws {
        var decoder = FrameDecoder()
        let bytes = Frame(magic: 0x2836, payload: Array(repeating: 1, count: 128)).encoded()
        XCTAssertEqual(try decoder.push(bytes.dropLast()), [])
        XCTAssertEqual(decoder.pendingByteCount, bytes.count - 1)
        XCTAssertEqual(try decoder.push(bytes.suffix(1)).count, 1)
    }

    func testDesynchronisedLengthIsRejected() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.push([0x28, 0x36, 0x7F, 0xFF, 0xFF, 0xFF])) { error in
            XCTAssertEqual(error as? FramingError, .payloadTooLarge(magic: 0x2836, length: 0x7FFF_FFFF))
        }
    }

    func testRecordedSensorStreamIsAllSensorFrames() throws {
        let capture = try Fixtures.capture()
        let samples = try capture.imuSamples()
        XCTAssertEqual(samples.count, 93086)  // summary.json: imu_frames
        let gaps = zip(samples, samples.dropFirst()).map { Double($1.timestampNs) - Double($0.timestampNs) }
        XCTAssertEqual(gaps.reduce(0, +) / Double(gaps.count), 1e6, accuracy: 1e3)  // 1000 Hz
        XCTAssertTrue(gaps.allSatisfy { $0 > 0 })
    }
}

final class ControlTests: XCTestCase {
    func testGetRequestsMatchTheRecordedBytes() {
        // frames.jsonl, first "tx" rows: the recorder's requests that the real glasses answered.
        XCTAssertEqual(GetCommand.firmwareVersion.request(transactionID: 1).encoded(), Fixtures.bytes("271d00000006800000011800"))
        XCTAssertEqual(GetCommand.factoryConfig.request(transactionID: 4).encoded(), Fixtures.bytes("271f00000006800000041800"))
    }

    /// Every request the package can build: the five read-only GETs and the two side-by-side switch frames. Any other
    /// command (another SET, firmware update, ...) has no constructor, so it cannot reach `GlassesLink.send`.
    func testOnlyTheVerifiedGetsAndTheModeSwitchCanBeSent() {
        let gets = GetCommand.allCases.map { $0.request(transactionID: 7) }
        let sets = DisplayInputMode.allCases.map { $0.request(transactionID: 7) }
        XCTAssertEqual(Set((gets + sets).map(\.magic)), [0x271D, 0x272D, 0x2729, 0x271F, 0x275E, 0x2822])
        for frame in gets { XCTAssertEqual(Array(frame.payload.dropFirst(4)), [0x18, 0x00]) }
        XCTAssertEqual(Set(sets.map { Array($0.payload.dropFirst(4)) }), [[0x1A, 0x02, 0x08, 0x00], [0x1A, 0x02, 0x08, 0x01]])
        XCTAssertNil(DisplayInputMode(rawValue: 2), "no other mode value")
    }

    func testModeSwitchBytes() {
        // The exact frames sent to the glasses (txid 5): magic, length 8, txid with the MSB set, 1a 02 08 VV.
        XCTAssertEqual(DisplayInputMode.sideBySide.request(transactionID: 5).encoded(), Fixtures.bytes("282200000008800000051a020801"))
        XCTAssertEqual(DisplayInputMode.regular.request(transactionID: 6).encoded(), Fixtures.bytes("282200000008800000061a020800"))
    }

    func testModeFromDisplayWidth() {
        XCTAssertEqual(DisplayInputMode(displayWidth: 1920), .regular)
        XCTAssertEqual(DisplayInputMode(displayWidth: 3840), .sideBySide)
        XCTAssertNil(DisplayInputMode(displayWidth: 3024))
    }

    func testModeSwitchReplies() {
        func reply(_ hex: String) -> ControlMessage {
            var decoder = FrameDecoder()
            return ControlMessage(try! decoder.push(Fixtures.bytes(hex))[0])
        }
        // 2822 | len | txid 5 | body. Shapes as the community tools parse them; not yet captured on hardware.
        guard case .setReply(let ok) = reply("282200000006000000052200") else { return XCTFail() }
        XCTAssertEqual(ok.transactionID, 5)
        XCTAssertEqual(ok.result, .accepted)
        XCTAssertEqual(SetReply(transactionID: 5, body: Fixtures.bytes("22020800")).result, .accepted)
        XCTAssertEqual(SetReply(transactionID: 5, body: Fixtures.bytes("220308914e")).result, .rejected(status: 10001))
        XCTAssertEqual(SetReply(transactionID: 5, body: Fixtures.bytes("1800")).result, .unrecognised)
        XCTAssertEqual(SetReply(transactionID: 5, body: Fixtures.bytes("2202")).result, .unrecognised)
    }

    func testRecordedRepliesDecode() throws {
        let firmware = ControlMessage(Frame(magic: 0x271D, payload: Fixtures.bytes(
            "0000000122161214312e392e312e3230323630393134313735363235")))
        guard case .reply(let reply) = firmware else { return XCTFail("\(firmware)") }
        XCTAssertEqual(reply.transactionID, 1)
        XCTAssertEqual(try reply.stringValue(), "1.9.1.20260914175625")

        let serial = GetReply(command: .serialNumber, transactionID: 3, body: Fixtures.bytes("220c120a52454441435445443030"))
        XCTAssertEqual(try serial.stringValue(), "REDACTED00")

        let display = GetReply(command: .displayConfig, transactionID: 5, body: Fixtures.bytes("22021009"))
        XCTAssertEqual(try display.integerValue(), 9)
        XCTAssertThrowsError(try display.stringValue())
    }

    func testRecordedEventsDecode() {
        func message(_ hex: String) -> ControlMessage {
            var decoder = FrameDecoder()
            return ControlMessage(try! decoder.push(Fixtures.bytes(hex))[0])
        }
        XCTAssertEqual(message("273d000000021802"), .wear(.takenOff))
        XCTAssertEqual(message("273d000000021801"), .wear(.putOn))
        XCTAssertEqual(message(
            "272e000000400300000001000000fe90566b0000000000000000000000000000000000000000100907df7e000000d06e5b887f000000101107df7e0000000000000000000000"),
                       .button(ButtonEvent(key: 3, state: .down)))
        XCTAssertEqual(message(
            "272e000000400200000002000000019156" + String(repeating: "00", count: 64 - 11)),
                       .button(ButtonEvent(key: 2, state: .up)))
        XCTAssertEqual(message("278a000000071a051500002842"), .telemetry(index: 0, value: 42))
        XCTAssertEqual(message("278a000000091a0708021500000442"), .telemetry(index: 2, value: 33))
        guard case .stateChange(let body) = message("27120000000401000000") else { return XCTFail() }
        XCTAssertEqual(body, [1, 0, 0, 0])
    }
}

final class SensorTests: XCTestCase {
    func testRecordedIMUFrame() throws {
        var decoder = FrameDecoder()
        let frame = try decoder.push(Fixtures.bytes(
            "28360000008088bcff0000000000182dba340c000000911f0000000000000b00000002090fbeafd86f3e63149d3dcd6cecbee6191ac1cdbcfbbf000048c5000048c5000048c50000ec4102fbc30000401f0000400000000000000000000000f07e0e00000000888520887f000000d01464887f00000000000000000000000000000000000000"))[0]
        guard case .imu(let s)? = SensorMessage(frame) else { return XCTFail() }
        XCTAssertEqual(s.timestampNs, 0x0C_34BA_2D18)
        XCTAssertEqual(s.gyro.x, Double(Float(bitPattern: 0xBE0F_0902)))
        XCTAssertEqual(s.accel.y, Double(Float(bitPattern: 0xC11A_19E6)))
        XCTAssertEqual(s.accel.y, -9.63, accuracy: 0.01)
        XCTAssertEqual(s.temperature, 29.5)
    }

    func testMagnetometerFrameHasNoInertialData() throws {
        var decoder = FrameDecoder()
        let frame = try decoder.push(Fixtures.bytes(
            "28360000008088bcff0000000000e4f8d1340c0000000000000000000000040000000000c07f0000c07f0000c07f0000c07f0000c07f0000c07f00f449c200803b40005c0f420000c84102534e00000000000000000000000000000000000000000000000000888520887f000000d01464887f00000000000000000000000000000000000000"))[0]
        guard case .magnetometer(let m)? = SensorMessage(frame) else { return XCTFail() }
        XCTAssertEqual(m.field.x, -50.49, accuracy: 0.01)
        XCTAssertEqual(m.temperature, 25)
    }

    func testOtherFramesAreNotSensorMessages() {
        XCTAssertNil(SensorMessage(Frame(magic: 0x2836, payload: Array(repeating: 0, count: 10))))
        XCTAssertNil(SensorMessage(Frame(magic: 0x273D, payload: Array(repeating: 0, count: 128))))
    }
}

final class CalibrationTests: XCTestCase {
    func testFactoryConfigFromTheCapture() throws {
        let c = try Fixtures.capture().calibration
        XCTAssertEqual(c.displays.width, 1920)
        XCTAssertEqual(c.displays.height, 1080)
        XCTAssertEqual(c.displays.left.fx, 2489.98, accuracy: 0.01)
        XCTAssertEqual((c.displays.left.position - c.displays.right.position).length * 1000, 64.4, accuracy: 0.1)
        XCTAssertEqual(c.imu.gyroBiasByTemperature.count, 18)
        XCTAssertEqual(c.imu.gyroMatrix.m[0], 1.00339, accuracy: 1e-5)
    }

    func testGyroBiasFollowsTemperatureTable() throws {
        let imu = try Fixtures.capture().calibration.imu
        let t = imu.gyroBiasByTemperature
        XCTAssertEqual(imu.gyroBias(at: 20), t.first!.bias)          // clamped below
        XCTAssertEqual(imu.gyroBias(at: 50), t.last!.bias)           // clamped above
        XCTAssertEqual(imu.gyroBias(at: t[3].temperature), t[3].bias)
        let mid = imu.gyroBias(at: (t[3].temperature + t[4].temperature) / 2)
        XCTAssertEqual(mid.x, (t[3].bias.x + t[4].bias.x) / 2, accuracy: 1e-12)
        XCTAssertEqual(imu.gyroBias(at: .nan), imu.gyroBias)
    }

    func testMalformedConfigIsRejected() {
        let json = """
        {"IMU":{"device_1":{"imu_intrinsics":{"gyro_bias":[0,0],"gyro_calib_mat":[1,0,0,0,1,0,0,0,1],
        "accl_bias":[0,0,0],"accl_calib_mat":[1,0,0,0,1,0,0,0,1]}}},
        "display":{"resolution":[1920,1080],"k_left_display":[1,0,0,0,1,0,0,0,1],"k_right_display":[1,0,0,0,1,0,0,0,1],
        "target_p_left_display":[0,0,0],"target_p_right_display":[0,0,0],
        "target_q_left_display":[0,0,0,1],"target_q_right_display":[0,0,0,1]}}
        """
        XCTAssertThrowsError(try FactoryCalibration(json: Array(json.utf8))) { error in
            XCTAssertEqual(error as? FactoryCalibration.InvalidConfig, .init(field: "gyro_bias"))
        }
    }
}
