/// One frame on either TCP port: `magic u16 BE | length u32 BE | payload[length]`.
public struct Frame: Equatable, Sendable {
    public var magic: UInt16
    public var payload: [UInt8]

    public init(magic: UInt16, payload: [UInt8]) {
        self.magic = magic
        self.payload = payload
    }

    public static let headerSize = 6

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Frame.headerSize + payload.count)
        out.append(UInt8(magic >> 8))
        out.append(UInt8(magic & 0xFF))
        let n = UInt32(payload.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        out.append(contentsOf: payload)
        return out
    }
}

public enum FramingError: Error, Equatable {
    /// The length field exceeds `FrameDecoder.maxPayload`. The stream cannot be resynchronised; reconnect.
    case payloadTooLarge(magic: UInt16, length: UInt32)
}

/// Splits a TCP byte stream into frames. Bytes may arrive in arbitrary chunks.
public struct FrameDecoder {
    /// Largest observed payload is the factory config reply (193 323 bytes). Anything far above that is a
    /// desynchronised stream, not a frame.
    public static let maxPayload = 4 << 20

    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    /// Bytes buffered but not yet returned as a frame.
    public var pendingByteCount: Int { buffer.count - start }

    public mutating func push(_ bytes: some Collection<UInt8>) throws -> [Frame] {
        buffer.append(contentsOf: bytes)
        var frames: [Frame] = []
        while buffer.count - start >= Frame.headerSize {
            let b = start
            let magic = UInt16(buffer[b]) << 8 | UInt16(buffer[b + 1])
            let length = UInt32(buffer[b + 2]) << 24 | UInt32(buffer[b + 3]) << 16
                | UInt32(buffer[b + 4]) << 8 | UInt32(buffer[b + 5])
            guard length <= FrameDecoder.maxPayload else {
                throw FramingError.payloadTooLarge(magic: magic, length: length)
            }
            let end = b + Frame.headerSize + Int(length)
            guard buffer.count >= end else { break }
            frames.append(Frame(magic: magic, payload: Array(buffer[(b + Frame.headerSize)..<end])))
            start = end
        }
        // Compact once the consumed prefix dominates, so the buffer does not grow without bound.
        if start > 0 && start * 2 >= buffer.count {
            buffer.removeSubrange(0..<start)
            start = 0
        }
        return frames
    }
}
