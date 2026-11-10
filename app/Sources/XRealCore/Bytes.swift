import Foundation

extension Array where Element == UInt8 {
    func u32BE(at i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func u32LE(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func u64LE(at i: Int) -> UInt64 {
        UInt64(u32LE(at: i)) | UInt64(u32LE(at: i + 4)) << 32
    }

    func f32LE(at i: Int) -> Float {
        Float(bitPattern: u32LE(at: i))
    }
}

/// Minimal protobuf wire-format reader. The glasses wrap replies and some events in small protobuf messages;
/// field numbers are known from captures only, so callers pick fields by number and ignore the rest.
struct ProtoField {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    var number: Int
    var value: Value
}

enum ProtoError: Error {
    case truncated
    case unsupportedWireType(Int)
}

func parseProto(_ data: ArraySlice<UInt8>) throws -> [ProtoField] {
    var fields: [ProtoField] = []
    var i = data.startIndex

    func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < data.endIndex, shift < 64 else { throw ProtoError.truncated }
            let byte = data[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, data.endIndex - i >= n else { throw ProtoError.truncated }
        defer { i += n }
        return data[i..<(i + n)]
    }

    func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    while i < data.endIndex {
        let key = try varint()
        let number = Int(key >> 3)
        switch Int(key & 7) {
        case 0: fields.append(ProtoField(number: number, value: .varint(try varint())))
        case 1: fields.append(ProtoField(number: number, value: .fixed64(littleEndian(try take(8)))))
        case 2:
            let n = try varint()
            guard n <= UInt64(Int.max) else { throw ProtoError.truncated }
            fields.append(ProtoField(number: number, value: .bytes(try take(Int(n)))))
        case 5: fields.append(ProtoField(number: number, value: .fixed32(UInt32(littleEndian(try take(4))))))
        case let wire: throw ProtoError.unsupportedWireType(wire)
        }
    }
    return fields
}

extension Array where Element == ProtoField {
    func first(_ number: Int) -> ProtoField.Value? {
        first { $0.number == number }?.value
    }
}
