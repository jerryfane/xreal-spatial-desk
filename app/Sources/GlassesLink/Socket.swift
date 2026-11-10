import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct SocketError: Error, CustomStringConvertible {
    var description: String

    static func errno(_ what: String) -> SocketError {
        SocketError(description: "\(what): \(String(cString: strerror(Foundation.errno)))")
    }
}

/// A connected IPv4 TCP socket. Plain BSD sockets so the same code runs on macOS and on Linux (tests against
/// tools/fake_glasses.py run on both).
///
/// The descriptor is closed only in `deinit`, so a reader thread can never poll a recycled descriptor number;
/// `shutdown()` wakes a blocked reader from another thread.
final class TCPSocket: @unchecked Sendable {
    private let fd: Int32
    private let sendLock = NSLock()

    /// Connects to `host:port` within `timeout` seconds. `host` is an IPv4 address or a resolvable name.
    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            addr.sin_addr = try TCPSocket.resolve(host)
        }
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), Int32(IPPROTO_TCP))
        #endif
        guard fd >= 0 else { throw SocketError.errno("socket") }
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        try connect(addr, timeout: timeout)
    }

    deinit {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }

    private static func resolve(_ host: String) throws -> in_addr {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result, let sa = info.pointee.ai_addr else {
            throw SocketError(description: "cannot resolve \(host)")
        }
        defer { freeaddrinfo(result) }
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    private func connect(_ address: sockaddr_in, timeout: TimeInterval) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = address
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { throw SocketError.errno("connect") }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(timeout * 1000))
            guard n > 0 else { throw SocketError(description: n == 0 ? "connect: timed out" : "connect: poll failed") }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { throw SocketError(description: "connect: \(String(cString: strerror(err)))") }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    /// Waits up to `timeout` for data and reads it into `buffer`. Returns the byte count, nil on timeout, or 0 once
    /// the peer closed or `shutdown()` was called.
    func receive(into buffer: inout [UInt8], timeout: TimeInterval) throws -> Int? {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&p, 1, Int32(timeout * 1000))
        if ready == 0 { return nil }
        if ready < 0 {
            if errno == EINTR { return nil }
            throw SocketError.errno("poll")
        }
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n < 0 {
            if errno == EINTR || errno == EAGAIN { return nil }
            throw SocketError.errno("recv")
        }
        return n
    }

    func send(_ bytes: [UInt8]) throws {
        try sendLock.withLock {
            var sent = 0
            while sent < bytes.count {
                #if canImport(Darwin)
                let flags: Int32 = 0
                #else
                let flags = Int32(MSG_NOSIGNAL)
                #endif
                let n = bytes.withUnsafeBytes { Foundation.send(fd, $0.baseAddress! + sent, bytes.count - sent, flags) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.errno("send")
                }
                sent += n
            }
        }
    }

    /// Ends both directions; a blocked `receive` returns [] promptly.
    func shutdown() {
        _ = Foundation.shutdown(fd, Int32(SHUT_RDWR))
    }
}
