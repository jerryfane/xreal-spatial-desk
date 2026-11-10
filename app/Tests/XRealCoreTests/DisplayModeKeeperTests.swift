import Foundation
import XCTest
@testable import XRealCore

final class DisplayModeKeeperTests: XCTestCase {
    var dir: URL!
    var marker: URL { dir.appendingPathComponent("XRealDesk/display-mode-restore") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func accepted(_ tx: UInt32) -> SetReply { SetReply(transactionID: tx, body: [0x22, 0x00]) }

    var nextTx: UInt32 = 100

    /// Sends the keeper's current intent through a fake link; returns what was written.
    @discardableResult
    func sendIntent(_ keeper: DisplayModeKeeper) throws -> (mode: DisplayInputMode, transactionID: UInt32)? {
        try keeper.sendIntent { _, register in
            nextTx += 1
            register(nextTx)
            return nextTx
        }
    }

    func testSwitchWritesTheOriginalBeforeSendingAndRestoreClearsIt() throws {
        let keeper = DisplayModeKeeper(markerURL: marker)
        XCTAssertEqual(try keeper.request(.sideBySide, current: .regular), .sideBySide)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "0\n", "original recorded before anything is sent")
        keeper.sent(.sideBySide, transactionID: 1)
        keeper.handle(accepted(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "still switched: keep the marker")

        XCTAssertEqual(keeper.restore(), .regular)
        keeper.sent(.regular, transactionID: 2)
        XCTAssertEqual(keeper.handle(accepted(2)), .regular)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(keeper.pendingRestore)
        XCTAssertNil(keeper.restore(), "nothing left to undo")
    }

    func testACrashedRunIsRestoredOnTheNextConnect() throws {
        do {
            let crashed = DisplayModeKeeper(markerURL: marker)
            _ = try crashed.request(.sideBySide, current: .regular)
            crashed.sent(.sideBySide, transactionID: 1)
            crashed.handle(accepted(1))
        }  // process dies here: no restore

        let next = DisplayModeKeeper(markerURL: marker)
        XCTAssertEqual(next.pendingRestore, .regular)
        let sent = try XCTUnwrap(sendIntent(next), "restore sent on connect")
        XCTAssertEqual(sent.mode, .regular)
        next.handle(accepted(sent.transactionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(try sendIntent(next), "a fresh run with nothing to restore sends nothing")
    }

    func testRestoreThatIsRejectedOrUnansweredKeepsTheMarker() throws {
        let keeper = DisplayModeKeeper(markerURL: marker)
        _ = try keeper.request(.sideBySide, current: .regular)
        _ = keeper.restore()
        keeper.sent(.regular, transactionID: 3)
        keeper.handle(SetReply(transactionID: 3, body: [0x22, 0x03, 0x08, 0x91, 0x4E]))
        XCTAssertEqual(keeper.last?.result, .rejected(status: 10001))
        XCTAssertEqual(keeper.pendingRestore, .regular)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        // A reply nobody asked for changes nothing.
        XCTAssertNil(keeper.handle(accepted(99)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReconnectReappliesWhatThisRunWants() throws {
        let keeper = DisplayModeKeeper(markerURL: marker)
        _ = try keeper.request(.sideBySide, current: .regular)
        XCTAssertEqual(try sendIntent(keeper)?.mode, .sideBySide)
    }

    func testAlreadyInTheRequestedModeSendsNothing() throws {
        let keeper = DisplayModeKeeper(markerURL: marker)
        XCTAssertNil(try keeper.request(.sideBySide, current: .sideBySide))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(keeper.restore(), "the glasses were already side by side; quitting leaves them so")
    }

    func testRegularAcceptedWhileStillWantingSideBySideKeepsTheMarker() throws {
        // E.g. a crash-restore sent on connect is answered after this run already asked for side-by-side again:
        // the run will switch away again, so the original must stay recorded.
        let keeper = DisplayModeKeeper(markerURL: marker)
        _ = try keeper.request(.sideBySide, current: .regular)
        keeper.sent(.regular, transactionID: 4)
        keeper.handle(accepted(4))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(keeper.restore(), .regular)
    }

    /// Quitting may uncover the glasses only once they are seen back in the original mode, which happens ~2.4 s after
    /// the accepted reply. Three ways to get there: restore at quit, restore earlier from the menu, crash recovery.
    func testGlassesStayCoveredUntilSeenBackInTheOriginalMode() throws {
        // This run switched, then restored (menu or quit): accepted, but the display has not changed yet.
        let keeper = DisplayModeKeeper(markerURL: marker)
        XCTAssertNil(keeper.awaitingPhysicalRestore)
        _ = try keeper.request(.sideBySide, current: .regular)
        XCTAssertEqual(keeper.awaitingPhysicalRestore, .regular)
        XCTAssertEqual(keeper.restore(), .regular)
        keeper.sent(.regular, transactionID: 1)
        keeper.handle(accepted(1))
        XCTAssertNil(keeper.pendingRestore, "nothing left to send")
        XCTAssertEqual(keeper.awaitingPhysicalRestore, .regular, "but the glasses are not back yet")
        keeper.glassesObserved(.sideBySide)
        XCTAssertEqual(keeper.awaitingPhysicalRestore, .regular)
        keeper.glassesObserved(.regular)
        XCTAssertNil(keeper.awaitingPhysicalRestore)
    }

    func testCrashRecoveryAlsoKeepsTheGlassesCoveredUntilRestored() throws {
        do {
            let crashed = DisplayModeKeeper(markerURL: marker)
            _ = try crashed.request(.sideBySide, current: .regular)
        }
        // The new run never asks for side-by-side; it only recovers.
        let next = DisplayModeKeeper(markerURL: marker)
        XCTAssertEqual(next.awaitingPhysicalRestore, .regular)
        next.sent(.regular, transactionID: 2)
        next.handle(accepted(2))
        XCTAssertEqual(next.awaitingPhysicalRestore, .regular)
        next.glassesObserved(.regular)
        XCTAssertNil(next.awaitingPhysicalRestore)
    }

    func testRestoreSeenBeforeItsAcceptanceEndsTheWaitWhenTheAcceptanceArrives() throws {
        // The display change can be processed before the reply. No further display change follows, so the
        // acceptance itself must end the wait (otherwise the glasses stay covered forever).
        let keeper = DisplayModeKeeper(markerURL: marker)
        _ = try keeper.request(.sideBySide, current: .regular)
        keeper.glassesObserved(.sideBySide)
        XCTAssertEqual(keeper.restore(), .regular)
        keeper.sent(.regular, transactionID: 1)
        keeper.glassesObserved(.regular)
        XCTAssertEqual(keeper.awaitingPhysicalRestore, .regular, "not accepted yet")
        keeper.handle(accepted(1))
        XCTAssertNil(keeper.awaitingPhysicalRestore)
    }

    func testAnObservationFromBeforeTheSwitchDoesNotCount() throws {
        let keeper = DisplayModeKeeper(markerURL: marker)
        keeper.glassesObserved(.regular)
        _ = try keeper.request(.sideBySide, current: .regular)
        XCTAssertEqual(keeper.restore(), .regular)
        keeper.sent(.regular, transactionID: 1)
        keeper.handle(accepted(1))
        XCTAssertEqual(keeper.awaitingPhysicalRestore, .regular, "must be seen regular after the switch")
    }

    func testNoSwitchWhenTheOriginalCannotBeRecorded() throws {
        // A regular file where the directory should be: the marker cannot be written.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("XRealDesk"))
        let keeper = DisplayModeKeeper(markerURL: marker)
        XCTAssertThrowsError(try keeper.request(.sideBySide, current: .regular))
        XCTAssertNil(keeper.requested)
        XCTAssertNil(try sendIntent(keeper))
    }

    // Issue #9: the reconnect replay chose side-by-side, then the menu restored regular and sent it, then the
    // replay wrote its stale side-by-side: the glasses ended up switched with nothing left to restore them.
    func testAStaleRequestCannotBeWrittenAfterANewerRestore() throws {
        let keeper = DisplayModeKeeper(markerURL: marker)
        _ = try keeper.request(.sideBySide, current: .regular)
        /// What reached the glasses, in order. Written from two threads.
        final class Wire: @unchecked Sendable {
            let lock = NSLock()
            var frames: [(DisplayInputMode, UInt32)] = []
            func write(_ mode: DisplayInputMode, _ register: (UInt32) -> Void) -> UInt32 {
                let tx: UInt32 = lock.withLock { UInt32(frames.count + 1) }
                register(tx)
                lock.withLock { frames.append((mode, tx)) }
                return tx
            }
        }
        let wire = Wire()
        let chosen = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchGroup()
        // The control thread replays on connect: chooses its mode, then is preempted before writing.
        DispatchQueue.global().async(group: done) {
            _ = try? keeper.sendIntent { mode, register in
                chosen.signal()
                release.wait()
                return wire.write(mode, register)
            }
        }
        chosen.wait()
        // Meanwhile the menu turns side-by-side off and sends.
        XCTAssertEqual(keeper.restore(), .regular)
        DispatchQueue.global().async(group: done) { _ = try? keeper.sendIntent(wire.write) }
        Thread.sleep(forTimeInterval: 0.2)  // give the menu send every chance to overtake
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(wire.frames.map(\.0), [.sideBySide, .regular], "the newest intent is written last")
        // The glasses answer in wire order.
        for (_, tx) in wire.frames { keeper.handle(accepted(tx)) }
        XCTAssertNil(keeper.pendingRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAcceptedRestoreWithAnotherRequestStillInFlightKeepsTheMarker() throws {
        let keeper = DisplayModeKeeper(markerURL: marker)
        _ = try keeper.request(.sideBySide, current: .regular)
        let sbs = try XCTUnwrap(sendIntent(keeper))
        _ = keeper.restore()
        let regular = try XCTUnwrap(sendIntent(keeper))
        keeper.handle(accepted(regular.transactionID))  // side-by-side not answered yet: it could still land after
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        keeper.handle(accepted(sbs.transactionID))
        XCTAssertEqual(keeper.pendingRestore, .regular, "the glasses may be side-by-side: restore still owed")
    }

    func testRequestsLostWithTheConnectionDoNotBlockTheNextRestore() throws {
        let keeper = DisplayModeKeeper(markerURL: marker)
        _ = try keeper.request(.sideBySide, current: .regular)
        keeper.handle(accepted(try XCTUnwrap(sendIntent(keeper)).transactionID))
        _ = keeper.restore()
        _ = try sendIntent(keeper)  // glasses unplugged: no reply ever
        keeper.connectionLost()
        let again = try XCTUnwrap(sendIntent(keeper), "restore replayed on reconnect")
        XCTAssertEqual(again.mode, .regular)
        keeper.handle(accepted(again.transactionID))
        XCTAssertNil(keeper.pendingRestore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
