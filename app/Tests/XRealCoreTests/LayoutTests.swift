import Foundation
import XCTest
@testable import XRealCore

final class LayoutTests: XCTestCase {
    /// Angular edges of the row's screens, left to right.
    func rowEdges(_ l: Layout) -> [(left: Double, right: Double, id: Int)] {
        l.screens.filter(\.inRow).sorted { $0.yaw < $1.yaw }.map {
            let half = $0.placement.angularSize.width / 2
            return ($0.yaw - half, $0.yaw + half, $0.id)
        }
    }

    func assertPacked(_ l: Layout, file: StaticString = #filePath, line: UInt = #line) {
        let edges = rowEdges(l)
        for (a, b) in zip(edges, edges.dropFirst()) {
            XCTAssertEqual(b.left - a.right, Layout.rowGap, accuracy: 1e-9, "gap between \(a.id) and \(b.id)", file: file, line: line)
        }
    }

    func testSizeComesFromTheDiagonalAndTheResolution() {
        let s = SpatialScreen(id: 1, diagonalInches: 40, pixelWidth: 1920, pixelHeight: 1080).placement
        XCTAssertEqual(s.width, 0.8856, accuracy: 1e-3)  // a 40-inch 16:9 monitor is 88.6 cm wide
        XCTAssertEqual(s.height, 0.4981, accuracy: 1e-3)
        let wide = SpatialScreen(id: 1, diagonalInches: 49, pixelWidth: 5120, pixelHeight: 1440).placement
        XCTAssertEqual(wide.width / wide.height, 32.0 / 9, accuracy: 1e-9)
        XCTAssertEqual(hypot(wide.width, wide.height), 49 * 0.0254, accuracy: 1e-9)
    }

    func testCurvedScreenKeepsItsWidthAlongTheArcAndBendsTowardTheViewer() {
        let flat = ScreenPlacement(distance: 1.5, width: 1.2, height: 0.5)
        var curved = flat
        curved.curveRadius = 1.0
        // Arc length across the surface = the flat width.
        let steps = 1000
        let length = (0..<steps).reduce(0.0) { sum, i in
            sum + (curved.localPoint(x: Double(i + 1) / Double(steps) - 0.5, y: 0)
                - curved.localPoint(x: Double(i) / Double(steps) - 0.5, y: 0)).length
        }
        XCTAssertEqual(length, 1.2, accuracy: 1e-5)
        // Centre unchanged; edges nearer the head; and every point on the arc is `radius` from the curve's axis.
        XCTAssertEqual((curved.point(x: 0, y: 0) - flat.center).length, 0, accuracy: 1e-9)
        XCTAssertLessThan(curved.point(x: 0.5, y: 0).length, flat.point(x: 0.5, y: 0).length - 0.1)
        let axis = Vec3(0, 0, 1.5 - 1.0)
        for x in stride(from: -0.5, through: 0.5, by: 0.1) {
            let p = curved.point(x: x, y: 0.3)
            XCTAssertEqual(hypot(p.x - axis.x, p.z - axis.z), 1.0, accuracy: 1e-9)
        }
        // The angle matches the edge; with the edges nearer, it wraps more of the view than the flat screen (here
        // 46.2° instead of 43.6°).
        let edge = curved.point(x: 0.5, y: 0)
        XCTAssertEqual(curved.angularSize.width, 2 * atan2(edge.x, edge.z) * 180 / .pi, accuracy: 1e-9)
        XCTAssertGreaterThan(curved.angularSize.width, flat.angularSize.width + 2)
    }

    func testPresetsHaveTheirScreensSideBySideWithoutOverlap() {
        for preset in Layout.presets {
            assertPacked(preset)
            XCTAssertEqual(Set(preset.screens.map(\.id)).count, preset.screens.count, preset.name)
        }
        let desk = Layout.desk
        XCTAssertEqual(desk.screen(1)?.yaw, 0, "the centre screen stays straight ahead")
        XCTAssertEqual(desk.screen(4)?.pitch, 28, "the screen above is not part of the row")
        XCTAssertEqual(rowEdges(desk).map(\.id), [2, 1, 3])
    }

    func testGrowingOrCurvingAScreenPushesItsNeighboursAside() {
        var l = Layout.threeInARow
        let before = l.screen(3)!.yaw
        l.update(1) { $0.diagonalInches = 65 }
        assertPacked(l)
        XCTAssertEqual(l.screen(1)?.yaw, 0)
        XCTAssertGreaterThan(l.screen(3)!.yaw, before)
        XCTAssertEqual(l.screen(2)!.yaw, -l.screen(3)!.yaw, accuracy: 1e-9)
        // Curving it widens the angle it covers (its edges come nearer), so the neighbours move further out.
        let grown = l.screen(3)!.yaw
        l.update(1) { $0.curveRadius = 1.0 }
        assertPacked(l)
        XCTAssertGreaterThan(l.screen(3)!.yaw, grown)
    }

    func testAddingFillsTheEmptierSideAndStopsAtTheLimit() throws {
        var l = Layout.single
        let second = try XCTUnwrap(l.addScreen())
        XCTAssertGreaterThan(second.yaw, 0, "right on a tie")
        let third = try XCTUnwrap(l.addScreen())
        XCTAssertLessThan(third.yaw, 0, "then the emptier left side")
        assertPacked(l)
        XCTAssertEqual(l.screen(1)?.yaw, 0)
        XCTAssertEqual(Set(l.screens.map(\.id)), [1, 2, 3])
        XCTAssertEqual(second.diagonalInches, l.screen(1)?.diagonalInches, "copies the screen ahead")
        while l.screens.count < Layout.maxScreens { XCTAssertNotNil(l.addScreen()) }
        XCTAssertNil(l.addScreen())
        XCTAssertEqual(l.screens.count, Layout.maxScreens)
        assertPacked(l)
    }

    func testRemovingCloseTheGap() {
        var l = Layout.threeInARow
        l.removeScreen(2)
        assertPacked(l)
        XCTAssertEqual(l.screens.map(\.id), [1, 3])
        XCTAssertEqual(l.screen(1)?.yaw, 0)
    }

    func testSanitizedLayoutIsUsableWhateverTheFileSaid() {
        let bad = Layout(name: "x", screens: [
            SpatialScreen(id: 1, distance: -3, diagonalInches: .nan, pixelWidth: 10, pixelHeight: 100_000, curveRadius: 0.1),
            SpatialScreen(id: 1, yaw: 30),
            SpatialScreen(id: 0),
        ] + (2...9).map { SpatialScreen(id: $0) })
        let s = bad.sanitized
        XCTAssertEqual(s.screens.map(\.id), [1, 2, 3, 4, 5, 6], "unique positive IDs, at most six")
        let first = s.screens[0]
        XCTAssertEqual(first.distance, 0.5)
        XCTAssertEqual(first.diagonalInches, 40)
        XCTAssertEqual(first.pixelWidth, 640)
        XCTAssertEqual(first.pixelHeight, 4320)
        XCTAssertEqual(first.curveRadius, 0.8)
        XCTAssertEqual(Layout(name: "empty", screens: []).sanitized.screens, Layout.single.screens)
    }

    func testLibraryRoundTripAndBadFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("XRealDesk/layouts.json")

        let missing = LayoutLibrary.load(from: url)
        XCTAssertEqual(missing.library, LayoutLibrary())
        XCTAssertNil(missing.problem)

        var lib = LayoutLibrary(current: .desk)
        var mine = Layout.threeInARow
        mine.name = "Mine"
        lib.save(mine)
        mine.screens.removeLast()
        lib.save(mine)
        XCTAssertEqual(lib.saved.count, 1, "saving under the same name replaces")
        try lib.write(to: url)
        XCTAssertEqual(LayoutLibrary.load(from: url).library, lib)

        try Data("{ not json".utf8).write(to: url)
        let broken = LayoutLibrary.load(from: url)
        XCTAssertEqual(broken.library, LayoutLibrary())
        XCTAssertNotNil(broken.problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("bad")), Data("{ not json".utf8), "kept for the user")
    }

    func testArrangementFollowsTheLayout() {
        typealias Item = DisplayArrangement.Item
        let items = [
            Item(id: 10, yaw: 40, pitch: 0, width: 1920, height: 1080),
            Item(id: 11, yaw: -40, pitch: 0, width: 2560, height: 1440),
            Item(id: 12, yaw: 0, pitch: 28, width: 1920, height: 1080),
            Item(id: 13, yaw: 0, pitch: -30, width: 1920, height: 1080),
            Item(id: 14, yaw: 0, pitch: 3, width: 1920, height: 1080),
        ]
        let o = DisplayArrangement.origins(items, rightOf: (x: 0, y: 0, width: 1512, height: 982))
        // Row, left to right by yaw, starting at the right edge of the other displays, top-aligned with them.
        XCTAssertEqual(o[11].map { [$0.x, $0.y] }, [1512, 0])
        XCTAssertEqual(o[14].map { [$0.x, $0.y] }, [1512 + 2560, 0])
        XCTAssertEqual(o[10].map { [$0.x, $0.y] }, [1512 + 2560 + 1920, 0])
        XCTAssertEqual(o[12].map { [$0.x, $0.y] }, [1512, -1080], "above the row")
        XCTAssertEqual(o[13].map { [$0.x, $0.y] }, [1512, 1440], "below the tallest row display")
    }
}
