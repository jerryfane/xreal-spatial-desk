import Foundation
import XRealCore

/// Both TCP connections to the glasses: sensor stream (52998) and control channel (52999).
///
/// Each port has its own thread that connects, reads and reconnects with backoff until `stop()` or until the link
/// is released. Events are delivered on those threads: sensor events (1000 Hz) on the sensor thread, control events
/// on the control thread. Keep the handler short and thread-safe. The handler may call `stop()`.
///
/// Only the read-only GETs in `GetCommand` and the side-by-side switch `DisplayInputMode` can be sent. On every
/// control connection the link sends `Configuration.initialRequests` (by default all five GETs).
public final class GlassesLink: @unchecked Sendable {
    public static let defaultHost = "169.254.2.1"
    public static let sensorPort: UInt16 = 52998
    public static let controlPort: UInt16 = 52999

    public struct Configuration: Sendable {
        /// `169.254.2.1` for the glasses, `127.0.0.1` for tools/fake_glasses.py.
        public var host = GlassesLink.defaultHost
        public var sensorPort = GlassesLink.sensorPort
        public var controlPort = GlassesLink.controlPort
        public var connectTimeout: TimeInterval = 2
        /// First retry delay after a failed or dropped connection; doubles up to `maxReconnectDelay`.
        public var reconnectDelay: TimeInterval = 0.25
        public var maxReconnectDelay: TimeInterval = 4
        /// A connection with no data for this long is considered dead and reopened. The sensor port streams at
        /// 1000 Hz; the control port is quiet for long stretches, so it only uses TCP errors.
        public var sensorIdleTimeout: TimeInterval = 2
        public var initialRequests: [GetCommand] = GetCommand.allCases

        public init(host: String = GlassesLink.defaultHost) {
            self.host = host
        }
    }

    public enum Channel: String, Sendable {
        case sensor, control
    }

    public enum Event: Sendable {
        case connected(Channel)
        case disconnected(Channel, reason: String)
        case sensor(SensorMessage)
        case control(ControlMessage)
    }

    public struct NotConnected: Error {}

    // The worker threads retain only `core`, so releasing the last reference to the link runs `deinit` and stops them.
    private let core: Core

    public var configuration: Configuration { core.configuration }

    public init(configuration: Configuration, handler: @escaping @Sendable (Event) -> Void) {
        core = Core(configuration: configuration, handler: handler)
    }

    deinit { core.stop() }

    public func start() { core.start() }

    /// Closes both connections. From any other thread it returns once both worker threads have exited. From the
    /// handler (a worker thread) it only signals the shutdown and returns at once: waiting there could deadlock with
    /// the other worker's handler doing the same. No events are delivered after the workers see the signal, except
    /// from a handler call already in progress.
    public func stop() { core.stop() }

    /// Sends a GET on the control connection. The reply arrives as `.control(.reply)` with this transaction ID.
    @discardableResult
    public func send(_ command: GetCommand) throws -> UInt32 { try core.send(command.request(transactionID:)) }

    /// Switches the display input mode. The reply arrives as `.control(.setReply)` with this transaction ID.
    @discardableResult
    public func send(_ mode: DisplayInputMode) throws -> UInt32 { try core.send(mode.request(transactionID:)) }
}

private final class Core: @unchecked Sendable {
    typealias Channel = GlassesLink.Channel

    let configuration: GlassesLink.Configuration
    private let handler: @Sendable (GlassesLink.Event) -> Void
    private let condition = NSCondition()
    private var running = false
    private var sockets: [Channel: TCPSocket] = [:]
    private var workers: Set<ObjectIdentifier> = []
    private var nextTransactionID: UInt32 = 1

    init(configuration: GlassesLink.Configuration, handler: @escaping @Sendable (GlassesLink.Event) -> Void) {
        self.configuration = configuration
        self.handler = handler
    }

    func start() {
        condition.lock()
        defer { condition.unlock() }
        guard !running, workers.isEmpty else { return }
        running = true
        for channel in [Channel.sensor, .control] {
            let thread = Thread { [self] in run(channel) }
            thread.name = "GlassesLink.\(channel.rawValue)"
            thread.qualityOfService = .userInteractive
            workers.insert(ObjectIdentifier(thread))
            thread.start()
        }
    }

    func stop() {
        condition.lock()
        running = false
        for socket in sockets.values { socket.shutdown() }
        condition.broadcast()
        if !workers.contains(ObjectIdentifier(Thread.current)) {
            while !workers.isEmpty { condition.wait() }
        }
        condition.unlock()
    }

    func send(_ request: (UInt32) -> Frame) throws -> UInt32 {
        condition.lock()
        let socket = sockets[.control]
        let tx = nextTransactionID
        nextTransactionID = nextTransactionID % 0x7FFF_FFFF + 1
        condition.unlock()
        guard let socket else { throw GlassesLink.NotConnected() }
        try socket.send(request(tx).encoded())
        return tx
    }

    private var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return running
    }

    private func run(_ channel: Channel) {
        defer {
            condition.lock()
            workers.remove(ObjectIdentifier(Thread.current))
            condition.broadcast()
            condition.unlock()
        }
        let port = channel == .sensor ? configuration.sensorPort : configuration.controlPort
        var delay = configuration.reconnectDelay
        while isRunning {
            let reason: String
            do {
                let socket = try TCPSocket(host: configuration.host, port: port, timeout: configuration.connectTimeout)
                condition.lock()
                guard running else { condition.unlock(); return }
                sockets[channel] = socket
                condition.unlock()
                handler(.connected(channel))
                delay = configuration.reconnectDelay
                reason = read(socket, channel)
                condition.lock()
                sockets[channel] = nil
                condition.unlock()
            } catch {
                reason = "\(error)"
            }
            guard isRunning else { return }
            handler(.disconnected(channel, reason: reason))
            condition.lock()
            if running { _ = condition.wait(until: Date(timeIntervalSinceNow: delay)) }
            condition.unlock()
            delay = min(delay * 2, configuration.maxReconnectDelay)
        }
    }

    /// Reads until the connection ends; returns why.
    private func read(_ socket: TCPSocket, _ channel: Channel) -> String {
        if channel == .control {
            do {
                for command in configuration.initialRequests { _ = try send(command.request(transactionID:)) }
            } catch {
                return "sending GET requests: \(error)"
            }
        }
        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var lastData = Date()
        while isRunning {
            do {
                guard let n = try socket.receive(into: &buffer, timeout: 0.25) else {
                    if channel == .sensor && Date().timeIntervalSince(lastData) > configuration.sensorIdleTimeout {
                        return "no sensor data for \(configuration.sensorIdleTimeout) s"
                    }
                    continue
                }
                if n == 0 { return "closed by peer" }
                lastData = Date()
                for frame in try decoder.push(buffer[0..<n]) {
                    switch channel {
                    case .sensor:
                        if let message = SensorMessage(frame) { handler(.sensor(message)) }
                    case .control:
                        handler(.control(ControlMessage(frame)))
                    }
                }
            } catch {
                return "\(error)"
            }
        }
        return "stopped"
    }
}
