#if os(macOS)
import AppKit
import GlassesLink
import XRealCore

/// The glasses as a macOS display: external, 1080 pixels high, 1920 (regular) or 3840 (side-by-side) wide.
struct GlassesDisplay: Equatable {
    var id: CGDirectDisplayID
    var pixelWidth: Int
    var pixelHeight: Int

    var mode: DisplayInputMode? { DisplayInputMode(displayWidth: pixelWidth) }

    var description: String { "display \(id) \(pixelWidth)x\(pixelHeight) (\(mode.map { "\($0)" } ?? "unknown mode"))" }

    /// The single display that looks like the glasses, or nil (none, or several, which would be a guess).
    /// `excluding` is our own virtual display, which is also 1920×1080.
    static func find(excluding: CGDirectDisplayID?) -> GlassesDisplay? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let candidates: [GlassesDisplay] = ids.compactMap { id in
            guard id != excluding, CGDisplayIsBuiltin(id) == 0, CGDisplayIsActive(id) != 0,
                  let m = CGDisplayCopyDisplayMode(id), m.pixelHeight == 1080,
                  m.pixelWidth == 1920 || m.pixelWidth == 3840 else { return nil }
            return GlassesDisplay(id: id, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

/// Sends `DisplayInputMode` requests and makes sure the original mode comes back (see `DisplayModeKeeper`).
/// Thread-safe: replies arrive on the GlassesLink control thread; `sendAndWait` blocks its caller (never call it
/// from the control thread).
final class DisplayModeController: @unchecked Sendable {
    let keeper = DisplayModeKeeper(markerURL: DisplayModeKeeper.defaultMarkerURL)
    private let lock = NSCondition()
    private var link: GlassesLink?
    private var replies: [UInt32: SetReply] = [:]
    private var controlConnected = false

    func attach(_ link: GlassesLink) {
        lock.withLock { self.link = link }
        if let leftover = keeper.pendingRestore {
            Log.line("display mode: a previous run left the glasses switched; restoring \(leftover) when they connect")
        }
    }

    var isControlConnected: Bool { lock.withLock { controlConnected } }

    /// Feed every link event here.
    func handle(_ event: GlassesLink.Event) {
        switch event {
        case .connected(.control):
            lock.withLock { controlConnected = true; lock.broadcast() }
            if let mode = keeper.modeToSendOnConnect() { send(mode, why: "on connect") }
        case .disconnected(.control, _):
            lock.withLock { controlConnected = false }
        case .control(.setReply(let r)):
            let mode = keeper.handle(r)
            Log.line("display mode: reply tx \(r.transactionID) for \(mode.map { "\($0)" } ?? "unknown request"): body \(hex(r.body)) → \(r.result)")
            lock.withLock { replies[r.transactionID] = r; lock.broadcast() }
        default:
            break
        }
    }

    /// Sends `mode` if the control channel is up; logs the exact frame. Returns the transaction ID.
    @discardableResult
    func send(_ mode: DisplayInputMode, why: String) -> UInt32? {
        guard let link = lock.withLock({ link }) else { return nil }
        do {
            let keeper = self.keeper
            let tx = try link.send(mode) { keeper.sent(mode, transactionID: $0) }
            Log.line("display mode: sent \(mode) (\(why)), tx \(tx): \(hex(mode.request(transactionID: tx).encoded()))")
            return tx
        } catch {
            Log.line("display mode: \(mode) not sent (\(why)): \(error)")
            return nil
        }
    }

    /// Sends `mode` and waits for its reply.
    func sendAndWait(_ mode: DisplayInputMode, why: String, timeout: TimeInterval = 5) -> SetReply? {
        guard let tx = send(mode, why: why) else { return nil }
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock()
        defer { lock.unlock() }
        while replies[tx] == nil, lock.wait(until: deadline) {}
        if replies[tx] == nil { Log.line("display mode: no reply to tx \(tx) within \(timeout) s") }
        return replies.removeValue(forKey: tx)
    }

    func waitForControl(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock()
        defer { lock.unlock() }
        while !controlConnected, lock.wait(until: deadline) {}
        return controlConnected
    }

    /// Switches to `mode`, given what the glasses show now. Returns false if not done (logged).
    func switchTo(_ mode: DisplayInputMode, glasses: GlassesDisplay?) -> Bool {
        guard let current = glasses?.mode else {
            Log.line("display mode: glasses display not identified (\(describeDisplays())); not switching")
            return false
        }
        do {
            guard let toSend = try keeper.request(mode, current: current) else {
                Log.line("display mode: glasses already \(mode)")
                return true
            }
            if send(toSend, why: "requested") == nil {
                Log.line("display mode: will send \(toSend) when the glasses connect")
            }
            return true
        } catch {
            Log.line("display mode: \(error)")
            return false
        }
    }

    /// Puts the original mode back (if this run or a crashed one switched it) and returns only once the glasses are
    /// not seen side-by-side any more, or after a timeout. Whether or not anything is sent here: a restore started
    /// earlier (menu toggle) may have been accepted while the glasses are still re-enumerating (~2.4 s after the
    /// reply), and until they finish the caller must keep them covered.
    func restoreBlocking(excluding virtual: CGDirectDisplayID?, timeout: TimeInterval = 3) {
        if let mode = keeper.restore() {
            let reply = sendAndWait(mode, why: "restore", timeout: timeout)
            if reply?.result != .accepted {
                Log.line("display mode: restore to \(mode) NOT confirmed; it is retried on the next start")
                return
            }
        }
        // Wait while a switch by this run or a crashed one is accepted but not yet visible. If the glasses were never
        // switched by us, nothing is awaited (they may be side-by-side on their own and stay so).
        guard let original = keeper.awaitingPhysicalRestore else { return }
        let deadline = Date(timeIntervalSinceNow: 6)
        while Date() < deadline {
            if let mode = GlassesDisplay.find(excluding: virtual)?.mode { keeper.glassesObserved(mode) }
            if keeper.awaitingPhysicalRestore == nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if keeper.awaitingPhysicalRestore != nil { Log.line("display mode: glasses not seen back in \(original) within 6 s") }
        Log.line("display mode: on quit the glasses are \(GlassesDisplay.find(excluding: virtual)?.description ?? "not identified: \(describeDisplays())")")
    }

    /// Polls until the glasses display shows `mode` (the glasses re-enumerate after a switch).
    static func waitForGlasses(_ mode: DisplayInputMode, excluding: CGDirectDisplayID?, timeout: TimeInterval) -> GlassesDisplay? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let g = GlassesDisplay.find(excluding: excluding), g.mode == mode { return g }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// The first, owner-watched hardware run (milestone 1): read mode, switch to side-by-side, read back, restore,
    /// read back. Stops and restores on any error or mismatch; never retries or tries other values.
    /// Returns whether every step matched. Blocks: run it off the main thread.
    func runCheck() -> Bool {
        func step(_ s: String) { Log.line("sbs-check: \(s)") }
        guard waitForControl(timeout: 15) else { step("RESULT FAIL: glasses control channel not connected"); return false }
        guard let before = GlassesDisplay.find(excluding: nil) else {
            step("RESULT FAIL: glasses display not identified: \(describeDisplays())"); return false
        }
        step("1 read mode: \(before.description)")
        guard before.mode == .regular else { step("RESULT STOP: glasses not in regular mode; nothing sent"); return false }

        guard (try? keeper.request(.sideBySide, current: .regular)) != nil else {
            step("RESULT FAIL: cannot record the original mode; nothing sent"); return false
        }
        let reply = sendAndWait(.sideBySide, why: "check step 2")
        step("2 set side-by-side: reply \(reply.map { "\(hex($0.body)) → \($0.result)" } ?? "none")")
        var ok = reply?.result == .accepted
        if ok {
            let after = DisplayModeController.waitForGlasses(.sideBySide, excluding: nil, timeout: 15)
            step("3 read back: \(after?.description ?? "no 3840x1080 glasses display within 15 s: \(describeDisplays())")")
            ok = after != nil
            if ok { Thread.sleep(forTimeInterval: 5) }
        }
        if !ok { step("stopping after a mismatch; restoring") }
        let restore = sendAndWait(keeper.restore() ?? .regular, why: "check step 4")
        step("4 restore regular: reply \(restore.map { "\(hex($0.body)) → \($0.result)" } ?? "none")")
        let back = DisplayModeController.waitForGlasses(.regular, excluding: nil, timeout: 15)
        step("5 read back: \(back?.description ?? "no 1920x1080 glasses display within 15 s: \(describeDisplays())")")
        let all = ok && restore?.result == .accepted && back != nil
        step("RESULT \(all ? "PASS" : "FAIL")")
        return all
    }
}
#endif
