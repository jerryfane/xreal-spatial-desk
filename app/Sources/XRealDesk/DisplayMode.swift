#if os(macOS)
import AppKit
import CVirtualDisplay
import GlassesLink
import XRealCore

/// IDs of the virtual displays this process created, so they are never taken for the glasses (ours can also be
/// 1920×1080 or 3840×1080). Kept by ID: macOS is not guaranteed to report the vendor number we set.
enum OwnDisplays {
    private static let lock = NSLock()
    private static var ids: Set<CGDirectDisplayID> = []
    /// Invalidated by us but possibly still listed by WindowServer.
    private static var retired: Set<CGDirectDisplayID> = []

    static func add(_ id: CGDirectDisplayID) { lock.withLock { _ = ids.insert(id) } }

    /// The display was invalidated: it stays excluded until `pruneRetired` sees it gone from the display list.
    static func retire(_ id: CGDirectDisplayID) { lock.withLock { _ = retired.insert(id) } }

    /// Forgets retired displays no longer online (call on every display change).
    static func pruneRetired() {
        // Forget nothing unless the list is known: a failed query would make every retired display look gone.
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var online = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &online, &count) == .success else { return }
        let present = Set(online.prefix(Int(count)))
        lock.withLock {
            let gone = retired.subtracting(present)
            ids.subtract(gone)
            retired.subtract(gone)
        }
    }

    static func contains(_ id: CGDirectDisplayID) -> Bool {
        lock.withLock { ids.contains(id) } || CGDisplayVendorNumber(id) == XRVirtualDisplay.vendorID
    }
}

/// The glasses as a macOS display: external, 1080 pixels high, 1920 (regular) or 3840 (side-by-side) wide.
struct GlassesDisplay: Equatable {
    var id: CGDirectDisplayID
    var pixelWidth: Int
    var pixelHeight: Int

    var mode: DisplayInputMode? { DisplayInputMode(displayWidth: pixelWidth) }

    var description: String { "display \(id) \(pixelWidth)x\(pixelHeight) (\(mode.map { "\($0)" } ?? "unknown mode"))" }

    /// The single display that looks like the glasses, or nil (none, or several, which would be a guess). Our own
    /// virtual displays are skipped (`OwnDisplays`).
    static func find() -> GlassesDisplay? {
        let c = online().compactMap(\.candidate)
        return c.count == 1 ? c[0] : nil
    }

    /// `find`, plus a short reason when it finds nothing, naming every display and why it was or was not taken.
    /// Only for an explicit attempt: it formats a report for every display.
    static func search() -> (glasses: GlassesDisplay?, why: String) {
        let all = online()
        let candidates = all.compactMap(\.candidate)
        if candidates.count == 1 { return (candidates[0], "") }
        let list = all.map { d in
            let size = d.mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "no mode"
            return "\(d.id) \(size) vendor \(String(format: "0x%04x", CGDisplayVendorNumber(d.id))): \(d.skip ?? "candidate")"
        }.joined(separator: "; ")
        return (nil, candidates.isEmpty ? "no glasses display (\(list))" : "\(candidates.count) displays look like the glasses (\(list))")
    }

    /// Every online display with its mode and why it is not the glasses (nil skip = candidate).
    private static func online() -> [(id: CGDirectDisplayID, mode: CGDisplayMode?, skip: String?, candidate: GlassesDisplay?)] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { id in
            let m = CGDisplayCopyDisplayMode(id)
            let skip: String?
            let mirrors = CGDisplayMirrorsDisplay(id)
            if OwnDisplays.contains(id) { skip = "ours" }
            else if CGDisplayIsBuiltin(id) != 0 { skip = "built-in" }
            else if mirrors != kCGNullDirectDisplay { skip = "mirrors display \(mirrors)" }
            else if CGDisplayIsActive(id) == 0 { skip = "inactive" }
            else if let m, m.pixelHeight == 1080, m.pixelWidth == 1920 || m.pixelWidth == 3840 { skip = nil }
            else { skip = "not 1920/3840x1080" }
            let candidate = skip == nil ? m.map { GlassesDisplay(id: id, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight) } : nil
            return (id, m, skip, candidate)
        }
    }
}

/// Undoes macOS mirroring between one of our virtual displays and another display (the glasses mirroring one of our
/// screens shows that screen instead of our image, and leaves no glasses display to switch to side-by-side). Each
/// pair is undone at most once per run, so a mirror the user sets up again on purpose is left alone; a failed attempt
/// does not count and is retried at most every 10 s. Session only.
enum MirrorGuard {
    private static var undone: Set<[CGDirectDisplayID]> = []
    private static var retryAfter: [[CGDirectDisplayID]: Date] = [:]

    static func check() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }
        let now = Date()
        let pairs = ids.prefix(Int(count)).compactMap { id -> [CGDirectDisplayID]? in
            let source = CGDisplayMirrorsDisplay(id)
            guard source != kCGNullDirectDisplay, OwnDisplays.contains(id) != OwnDisplays.contains(source) else { return nil }
            return [id, source]
        }.filter { !undone.contains($0) && (retryAfter[$0].map { now >= $0 } ?? true) }
        guard !pairs.isEmpty else { return }
        let described = pairs.map { "\($0[0]) mirrored \($0[1])" }.joined(separator: ", ")
        func failed(_ why: String) {
            for p in pairs { retryAfter[p] = now.addingTimeInterval(10) }
            Log.line("mirroring: \(described): \(why); retrying in 10 s")
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return failed("could not begin configuration") }
        for pair in pairs where CGConfigureDisplayMirrorOfDisplay(config, pair[0], kCGNullDirectDisplay) != .success {
            CGCancelDisplayConfiguration(config)
            return failed("could not unmirror \(pair[0])")
        }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        guard result == .success else { return failed("FAILED (\(result.rawValue))") }
        undone.formUnion(pairs)
        for p in pairs { retryAfter[p] = nil }
        Log.line("mirroring: \(described): undone")
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
            send(why: "on connect")
        case .disconnected(.control, _):
            keeper.connectionLost()
            lock.withLock { controlConnected = false }
        case .control(.setReply(let r)):
            let mode = keeper.handle(r)
            Log.line("display mode: reply tx \(r.transactionID) for \(mode.map { "\($0)" } ?? "unknown request"): body \(hex(r.body)) → \(r.result)")
            lock.withLock { replies[r.transactionID] = r; lock.broadcast() }
        default:
            break
        }
    }

    /// Sends the keeper's current intent (see `DisplayModeKeeper.sendIntent`) if the control channel is up; logs the
    /// exact frame. Change the intent first (`keeper.request` / `keeper.restore`), then call this. Returns the
    /// transaction ID, or nil if nothing was sent.
    @discardableResult
    func send(why: String) -> UInt32? {
        guard let link = lock.withLock({ link }) else { return nil }
        do {
            guard let sent = try keeper.sendIntent({ mode, register in try link.send(mode, register: register) }) else {
                return nil
            }
            Log.line("display mode: sent \(sent.mode) (\(why)), tx \(sent.transactionID): \(hex(sent.mode.request(transactionID: sent.transactionID).encoded()))")
            return sent.transactionID
        } catch {
            Log.line("display mode: not sent (\(why)): \(error)")
            return nil
        }
    }

    /// Sends the current intent and waits for its reply.
    func sendAndWait(why: String, timeout: TimeInterval = 5) -> SetReply? {
        guard let tx = send(why: why) else { return nil }
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
            guard try keeper.request(mode, current: current) != nil else {
                Log.line("display mode: glasses already \(mode)")
                return true
            }
            if send(why: "requested") == nil {
                Log.line("display mode: will send \(mode) when the glasses connect")
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
    func restoreBlocking(timeout: TimeInterval = 3) {
        if let mode = keeper.restore() {
            let reply = sendAndWait(why: "restore", timeout: timeout)
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
            if let mode = GlassesDisplay.find()?.mode { keeper.glassesObserved(mode) }
            if keeper.awaitingPhysicalRestore == nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if keeper.awaitingPhysicalRestore != nil { Log.line("display mode: glasses not seen back in \(original) within 6 s") }
        Log.line("display mode: on quit the glasses are \(GlassesDisplay.find()?.description ?? "not identified: \(describeDisplays())")")
    }

    /// Polls until the glasses display shows `mode` (the glasses re-enumerate after a switch).
    static func waitForGlasses(_ mode: DisplayInputMode, timeout: TimeInterval) -> GlassesDisplay? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if let g = GlassesDisplay.find(), g.mode == mode { return g }
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
        guard let before = GlassesDisplay.find() else {
            step("RESULT FAIL: glasses display not identified: \(describeDisplays())"); return false
        }
        step("1 read mode: \(before.description)")
        guard before.mode == .regular else { step("RESULT STOP: glasses not in regular mode; nothing sent"); return false }

        guard (try? keeper.request(.sideBySide, current: .regular)) != nil else {
            step("RESULT FAIL: cannot record the original mode; nothing sent"); return false
        }
        let reply = sendAndWait(why: "check step 2")
        step("2 set side-by-side: reply \(reply.map { "\(hex($0.body)) → \($0.result)" } ?? "none")")
        var ok = reply?.result == .accepted
        if ok {
            let after = DisplayModeController.waitForGlasses(.sideBySide, timeout: 15)
            step("3 read back: \(after?.description ?? "no 3840x1080 glasses display within 15 s: \(describeDisplays())")")
            ok = after != nil
            if ok { Thread.sleep(forTimeInterval: 5) }
        }
        if !ok { step("stopping after a mismatch; restoring") }
        _ = keeper.restore()
        let restore = sendAndWait(why: "check step 4")
        step("4 restore regular: reply \(restore.map { "\(hex($0.body)) → \($0.result)" } ?? "none")")
        let back = DisplayModeController.waitForGlasses(.regular, timeout: 15)
        step("5 read back: \(back?.description ?? "no 1920x1080 glasses display within 15 s: \(describeDisplays())")")
        let all = ok && restore?.result == .accepted && back != nil
        step("RESULT \(all ? "PASS" : "FAIL")")
        return all
    }
}
#endif
