/// The read-only requests this package can send, each a GET verified on firmware 1.9.1 (BRIEF.md). The only other
/// request is `DisplayInputMode.request`, the owner-approved side-by-side switch (milestone 1). There is
/// deliberately no way to build a request with any other command or body.
public enum GetCommand: UInt16, CaseIterable, Sendable {
    case firmwareVersion = 0x271D
    case dspVersion = 0x272D
    case serialNumber = 0x2729
    case factoryConfig = 0x271F
    case displayConfig = 0x275E

    public static let body: [UInt8] = [0x18, 0x00]

    /// Request frame: payload is `txid u32 BE with the MSB set | 18 00`.
    public func request(transactionID: UInt32) -> Frame {
        let tx = (transactionID & 0x7FFF_FFFF) | 0x8000_0000
        let payload: [UInt8] = [UInt8(tx >> 24), UInt8((tx >> 16) & 0xFF), UInt8((tx >> 8) & 0xFF), UInt8(tx & 0xFF)]
            + GetCommand.body
        return Frame(magic: rawValue, payload: payload)
    }
}

/// Display input mode of the glasses, set with command `0x2822` (owner-approved, 2026-11-10).
///
/// In side-by-side mode the glasses present a 3840×1080 display and show its left half to the left eye and its right
/// half to the right eye. There is no known GET for this mode; the current mode is read from the glasses' display
/// size instead (1920×1080 regular, 3840×1080 side-by-side). Encoding from georgehorrell/xreal-one-cli (verified on
/// firmware 1.8.1) and GarfDev/xreal-one-control-panel (1.9.0).
public enum DisplayInputMode: UInt8, CaseIterable, Sendable {
    case regular = 0
    case sideBySide = 1

    public static let command: UInt16 = 0x2822

    /// Request frame: payload is `txid u32 BE with the MSB set | 1a 02 08 VV` (field 3 { field 1: mode }).
    public func request(transactionID: UInt32) -> Frame {
        let tx = (transactionID & 0x7FFF_FFFF) | 0x8000_0000
        let payload: [UInt8] = [UInt8(tx >> 24), UInt8((tx >> 16) & 0xFF), UInt8((tx >> 8) & 0xFF), UInt8(tx & 0xFF),
                                0x1A, 0x02, 0x08, rawValue]
        return Frame(magic: DisplayInputMode.command, payload: payload)
    }

    /// The mode a display of this pixel width implies, or nil if it matches neither.
    public init?(displayWidth: Int) {
        switch displayWidth {
        case 1920: self = .regular
        case 3840: self = .sideBySide
        default: return nil
        }
    }
}

/// Reply to a `DisplayInputMode` request. Not yet captured on hardware; per the community tools the body is
/// `22 LL { 08 status }`, where an empty field 4 or status 0 means accepted.
public struct SetReply: Equatable, Sendable {
    public var transactionID: UInt32
    /// Raw body after the transaction ID, kept so the first real replies can be logged.
    public var body: [UInt8]

    public init(transactionID: UInt32, body: [UInt8]) {
        self.transactionID = transactionID
        self.body = body
    }

    public enum Result: Equatable, Sendable {
        case accepted
        case rejected(status: UInt64)
        /// The body does not have the expected shape.
        case unrecognised
    }

    public var result: Result {
        guard let outer = try? parseProto(body[...]), case .bytes(let inner)? = outer.first(4),
              let fields = try? parseProto(inner) else { return .unrecognised }
        guard case .varint(let status)? = fields.first(1) else { return fields.isEmpty ? .accepted : .unrecognised }
        return status == 0 ? .accepted : .rejected(status: status)
    }
}

/// Body of a GET reply after the 4-byte transaction ID: protobuf `field 4 { field 2: value }`.
/// String replies carry bytes in field 2, display config a varint.
public struct GetReply: Equatable, Sendable {
    public var command: GetCommand
    public var transactionID: UInt32
    public var body: [UInt8]

    public init(command: GetCommand, transactionID: UInt32, body: [UInt8]) {
        self.command = command
        self.transactionID = transactionID
        self.body = body
    }

    public enum DecodeError: Error, Equatable {
        case missingValue
    }

    /// The bytes of field 2 inside field 4 (firmware, DSP, serial: ASCII; factory config: JSON).
    public func bytesValue() throws -> [UInt8] {
        guard case .bytes(let inner)? = try parseProto(body[...]).first(4),
              case .bytes(let value)? = try parseProto(inner).first(2) else { throw DecodeError.missingValue }
        return Array(value)
    }

    public func stringValue() throws -> String {
        String(decoding: try bytesValue(), as: UTF8.self)
    }

    /// The varint in field 2 inside field 4 (display config; meaning of the value unknown, 9 on the test unit).
    public func integerValue() throws -> UInt64 {
        guard case .bytes(let inner)? = try parseProto(body[...]).first(4),
              case .varint(let value)? = try parseProto(inner).first(2) else { throw DecodeError.missingValue }
        return value
    }
}

public struct ButtonEvent: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case down, up
        case other(UInt32)
    }

    /// Key code as sent by the glasses. The recording has key 3 pressed twice, then key 2 twice, after the prompt
    /// "brightness up once, then brightness down once": 3 = up and 2 = down is likely but not confirmed.
    public var key: UInt32
    public var state: State

    public init(key: UInt32, state: State) {
        self.key = key
        self.state = state
    }
}

public enum WearState: Equatable, Sendable {
    case takenOff, putOn
    case other(UInt64)
}

/// A frame received on the control port, classified by magic.
public enum ControlMessage: Equatable, Sendable {
    case reply(GetReply)
    /// Reply to a `DisplayInputMode` request (`0x2822`).
    case setReply(SetReply)
    /// `0x272E`, 64-byte body: `u32 LE key, u32 LE state, ...`.
    case button(ButtonEvent)
    /// `0x273D`, protobuf body `field 3 varint`: 2 = taken off, 1 = put on.
    case wear(WearState)
    /// `0x278A`, protobuf `field 3 { field 1 varint index (absent = 0), field 2 float }`, every ~10 s.
    /// Three indices; values rise slowly (42→48, 38→42, 29→33 over the capture) and index 2 tracks the IMU
    /// temperature, so these are probably temperatures in °C. Inferred, not confirmed.
    case telemetry(index: UInt64, value: Float)
    /// `0x2712`, 64-byte body sent after button and wear events. Not decoded.
    case stateChange([UInt8])
    case unknown(Frame)

    public static let buttonMagic: UInt16 = 0x272E
    public static let wearMagic: UInt16 = 0x273D
    public static let telemetryMagic: UInt16 = 0x278A
    public static let stateChangeMagic: UInt16 = 0x2712

    public init(_ frame: Frame) {
        let p = frame.payload
        if let command = GetCommand(rawValue: frame.magic) {
            guard p.count >= 4 else { self = .unknown(frame); return }
            self = .reply(GetReply(command: command, transactionID: p.u32BE(at: 0) & 0x7FFF_FFFF, body: Array(p[4...])))
            return
        }
        if frame.magic == DisplayInputMode.command {
            guard p.count >= 4 else { self = .unknown(frame); return }
            self = .setReply(SetReply(transactionID: p.u32BE(at: 0) & 0x7FFF_FFFF, body: Array(p[4...])))
            return
        }
        switch frame.magic {
        case ControlMessage.buttonMagic where p.count >= 8:
            let state: ButtonEvent.State
            switch p.u32LE(at: 4) {
            case 1: state = .down
            case 2: state = .up
            case let s: state = .other(s)
            }
            self = .button(ButtonEvent(key: p.u32LE(at: 0), state: state))
        case ControlMessage.wearMagic:
            guard case .varint(let v)? = try? parseProto(p[...]).first(3) else { self = .unknown(frame); return }
            self = .wear(v == 2 ? .takenOff : v == 1 ? .putOn : .other(v))
        case ControlMessage.telemetryMagic:
            guard case .bytes(let inner)? = try? parseProto(p[...]).first(3),
                  let fields = try? parseProto(inner),
                  case .fixed32(let bits)? = fields.first(2) else { self = .unknown(frame); return }
            var index: UInt64 = 0
            if case .varint(let i)? = fields.first(1) { index = i }
            self = .telemetry(index: index, value: Float(bitPattern: bits))
        case ControlMessage.stateChangeMagic:
            self = .stateChange(p)
        default:
            self = .unknown(frame)
        }
    }
}
