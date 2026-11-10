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
        XCTAssertEqual(next.modeToSendOnConnect(), .regular)
        next.sent(.regular, transactionID: 9)
        next.handle(accepted(9))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(next.modeToSendOnConnect(), "a fresh run with nothing to restore sends nothing")
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
        XCTAssertEqual(keeper.modeToSendOnConnect(), .sideBySide)
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

    func testSeeingTheOriginalModeBeforeTheRestoreIsAcceptedDoesNotEndTheWait() throws {
        // E.g. observed in the instant before the switch took effect: the restore is still owed.
        let keeper = DisplayModeKeeper(markerURL: marker)
        _ = try keeper.request(.sideBySide, current: .regular)
        keeper.glassesObserved(.regular)
        XCTAssertEqual(keeper.awaitingPhysicalRestore, .regular)
    }

    func testNoSwitchWhenTheOriginalCannotBeRecorded() throws {
        // A regular file where the directory should be: the marker cannot be written.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("XRealDesk"))
        let keeper = DisplayModeKeeper(markerURL: marker)
        XCTAssertThrowsError(try keeper.request(.sideBySide, current: .regular))
        XCTAssertNil(keeper.requested)
        XCTAssertNil(keeper.modeToSendOnConnect())
    }
}
