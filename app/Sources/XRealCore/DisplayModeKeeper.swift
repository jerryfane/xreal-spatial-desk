import Foundation

/// Decides which `DisplayInputMode` to send, and guarantees the glasses get their original mode back.
///
/// Before the first switch away from the original mode, the original is written to `markerURL`. The marker is
/// deleted only when the glasses accept a switch back to it. So if the app crashes, is killed or loses the glasses
/// while switched, the next run finds the marker and restores the original mode as soon as the glasses connect.
/// If the marker cannot be written, no switch is made.
public final class DisplayModeKeeper: @unchecked Sendable {
    public struct MarkerError: Error, CustomStringConvertible {
        public var description: String
    }

    private let lock = NSLock()
    /// Held while a request is chosen and written, so requests reach the glasses in the order intents were set.
    private let sendMutex = NSLock()
    private let markerURL: URL
    /// Mode the glasses had before this app (or a crashed earlier run) switched them; nil if not switched.
    private var original: DisplayInputMode?
    /// Mode this run wants while it is connected; nil = none requested (only restore if a marker is left).
    private var desired: DisplayInputMode?
    private var inFlight: [UInt32: DisplayInputMode] = [:]
    private var lastResult: (mode: DisplayInputMode, result: SetReply.Result)?
    /// The original mode, from the moment the glasses were switched away from it (this run, or a crashed earlier run
    /// found at launch) until `glassesObserved` sees them back in it. Unlike `original`, this survives the accepted
    /// reply: the display changes ~2.4 s later, and until then the glasses must stay covered.
    private var physicalRestore: DisplayInputMode?
    /// The glasses' mode as last observed.
    private var lastObserved: DisplayInputMode?

    public init(markerURL: URL) {
        self.markerURL = markerURL
        original = (try? String(contentsOf: markerURL, encoding: .utf8))
            .flatMap { UInt8($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap(DisplayInputMode.init(rawValue:))
        physicalRestore = original
    }

    /// The mode the glasses still have to show again before they may be uncovered; nil once they are seen in it.
    public var awaitingPhysicalRestore: DisplayInputMode? { lock.withLock { physicalRestore } }

    /// Call with the glasses' mode as currently seen (display size). Seeing them in the original mode ends the wait.
    public func glassesObserved(_ mode: DisplayInputMode) {
        lock.withLock {
            lastObserved = mode
            settleLocked()
        }
    }

    /// Ends the wait once the restore is accepted and the glasses are seen in the original mode, in either order.
    private func settleLocked() {
        if original == nil, let target = physicalRestore, lastObserved == target { physicalRestore = nil }
    }

    /// `~/Library/Application Support/XRealDesk/display-mode-restore`.
    public static var defaultMarkerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XRealDesk/display-mode-restore")
    }

    /// Mode the glasses must return to, if they were switched (by this run or a crashed earlier one).
    public var pendingRestore: DisplayInputMode? { lock.withLock { original } }

    /// Mode this run asked for, if any.
    public var requested: DisplayInputMode? { lock.withLock { desired } }

    /// Result of the last reply to a mode request.
    public var last: (mode: DisplayInputMode, result: SetReply.Result)? { lock.withLock { lastResult } }

    /// Sends what the glasses should be in now: this run's wish, else a restore left by a crash; nothing if neither.
    ///
    /// Every request goes through here (connect replay, menu, quit), and the mode is read while the send mutex is
    /// held: so a request chosen before an intent change is always written before the request that follows it, and
    /// the last request on the wire is always the latest intent. `send` must call `register` with the transaction ID
    /// before writing (GlassesLink does), so a fast reply finds it.
    @discardableResult
    public func sendIntent(_ send: (DisplayInputMode, _ register: (UInt32) -> Void) throws -> UInt32) throws
        -> (mode: DisplayInputMode, transactionID: UInt32)? {
        sendMutex.lock()
        defer { sendMutex.unlock() }
        guard let mode = lock.withLock({ desired ?? original }) else { return nil }
        let tx = try send(mode) { self.sent(mode, transactionID: $0) }
        return (mode, tx)
    }

    /// The control connection dropped: replies to requests sent on it will never come.
    public func connectionLost() {
        lock.withLock { inFlight.removeAll() }
    }

    /// Asks for `mode`. `current` is the glasses' mode as observed now (from their display size). Writes the marker
    /// first if this is the first switch away from the original. Returns the mode to send, or nil if the glasses are
    /// already in that mode and nothing is pending.
    public func request(_ mode: DisplayInputMode, current: DisplayInputMode) throws -> DisplayInputMode? {
        try lock.withLock {
            if original == nil {
                guard mode != current else { desired = nil; return nil }
                try writeMarker(current)
                original = current
                physicalRestore = current
                lastObserved = nil
            }
            desired = mode
            return mode
        }
    }

    /// Asks for the original mode back (menu toggle off, quit). Returns the mode to send, or nil if nothing to undo.
    public func restore() -> DisplayInputMode? {
        lock.withLock {
            desired = original
            return original
        }
    }

    /// Records that `mode` was sent with this transaction ID.
    public func sent(_ mode: DisplayInputMode, transactionID: UInt32) {
        lock.withLock { inFlight[transactionID] = mode }
    }

    /// Handles a reply; returns the mode it answers, if it answers one of our requests.
    @discardableResult
    public func handle(_ reply: SetReply) -> DisplayInputMode? {
        lock.withLock {
            guard let mode = inFlight.removeValue(forKey: reply.transactionID) else { return nil }
            let result = reply.result
            lastResult = (mode, result)
            // Back in the original mode, this run wants nothing else, and no other request can still land after this
            // one: nothing left to undo.
            if result == .accepted, mode == original, desired == nil || desired == mode, inFlight.isEmpty {
                try? FileManager.default.removeItem(at: markerURL)
                original = nil
                desired = nil
                settleLocked()
            }
            return mode
        }
    }

    private func writeMarker(_ mode: DisplayInputMode) throws {
        do {
            try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(mode.rawValue)\n".utf8).write(to: markerURL, options: .atomic)
        } catch {
            throw MarkerError(description: "cannot record the original display mode at \(markerURL.path): \(error)")
        }
    }
}
