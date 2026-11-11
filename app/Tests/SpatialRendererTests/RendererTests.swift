#if canImport(Metal)
import CaptureTools
import Foundation
import Metal
import SpatialRenderer
import XCTest
import XRealCore

/// Offscreen Metal render of the side-by-side frame: the screen must land where the factory calibration says,
/// in each eye's half, and follow the head. Skipped where there is no Metal device.
final class RendererTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    var device: MTLDevice!
    var renderer: Renderer!
    var displays: DisplayCalibration!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        self.device = device
        renderer = try Renderer(device: device) { (nil, nil) }
        displays = try Capture(directory: Self.repoRoot.appendingPathComponent("captures/20261110-140512")).calibration.displays
    }

    /// A solid-colour texture standing in for the captured display.
    func solid(_ bgra: [UInt8], width: Int = 64, height: Int = 36) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        let t = device.makeTexture(descriptor: d)!
        let bytes = [UInt8]((0..<(width * height)).flatMap { _ in bgra })
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return t
    }

    struct Image {
        var bytes: [UInt8]
        var width: Int, height: Int
        func bgra(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
        func isLit(_ x: Int, _ y: Int) -> Bool { bgra(x, y)[0...2].contains { $0 > 0 } }
        /// Bounding box of lit pixels in columns [x0, x1).
        func litBox(columns: Range<Int>) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            var box: (Int, Int, Int, Int)?
            for y in 0..<height {
                for x in columns where isLit(x, y) {
                    box = box.map { (min($0.0, x), max($0.1, x), min($0.2, y), max($0.3, y)) } ?? (x, x, y, y)
                }
            }
            return box.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
        }
    }

    func render(head: Quat, screen: ScreenPlacement = ScreenPlacement(), texture: MTLTexture?) throws -> Image {
        try render(head: head, screens: [Renderer.Screen(placement: screen, texture: texture)])
    }

    func render(head: Quat, screens: [Renderer.Screen]) throws -> Image {
        // Half resolution keeps the test fast; the projection scales with the viewport.
        let w = 1920, h = 540
        let scene = Renderer.Scene(displays: displays, head: head, screens: screens)
        return Image(bytes: try renderer.renderOffscreen(scene, width: w, height: h), width: w, height: h)
    }

    /// Pixel bounds (full panel resolution) of a screen's outline in one eye, from the calibration.
    func expectedBox(_ screen: ScreenPlacement, eye: EyeCalibration) throws -> (minU: Double, maxU: Double, minV: Double, maxV: Double) {
        let steps = (0...64).map { Double($0) / 64 - 0.5 }
        let outline = steps.flatMap { t in [screen.point(x: t, y: -0.5), screen.point(x: t, y: 0.5),
                                            screen.point(x: -0.5, y: t), screen.point(x: 0.5, y: t)] }
        let px = outline.compactMap { eye.pixel(of: $0, head: .identity, width: displays.width, height: displays.height) }
        XCTAssertEqual(px.count, outline.count)
        return (px.map(\.u).min()!, px.map(\.u).max()!, px.map(\.v).min()!, px.map(\.v).max()!)
    }

    func testScreenAppearsInBothEyesWhereTheCalibrationProjectsIt() throws {
        let red: [UInt8] = [0, 0, 255, 255]
        let screen = ScreenPlacement()
        let image = try render(head: .identity, screen: screen, texture: solid(red))
        for (i, eye) in [displays.left, displays.right].enumerated() {
            let half = (i * 960)..<(i * 960 + 960)
            let box = try XCTUnwrap(image.litBox(columns: half), "eye \(i) shows the screen")
            // Expected corners from the same calibration, scaled to the half-size render.
            let px = screen.corners.compactMap { eye.pixel(of: $0, head: .identity, width: displays.width, height: displays.height) }
            XCTAssertEqual(px.count, 4)
            XCTAssertEqual(Double(box.minX - i * 960), px.map(\.u).min()! / 2, accuracy: 2)
            XCTAssertEqual(Double(box.maxX - i * 960), px.map(\.u).max()! / 2, accuracy: 2)
            XCTAssertEqual(Double(box.minY), px.map(\.v).min()! / 2, accuracy: 2)
            XCTAssertEqual(Double(box.maxY), px.map(\.v).max()! / 2, accuracy: 2)
            let cx = (box.minX + box.maxX) / 2, cy = (box.minY + box.maxY) / 2
            XCTAssertEqual(image.bgra(cx, cy), red, "texture is drawn, not the placeholder")
        }
        XCTAssertEqual(image.bgra(5, 5), [0, 0, 0, 255], "outside the screen is black (see-through)")
    }

    func testTextureIsNotMirrored() throws {
        // Left half of the texture green, right half blue: green must be on the left in both eyes.
        let w = 64, h = 36
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        let t = device.makeTexture(descriptor: d)!
        let top: [UInt8] = [0, 255, 0, 255], bottom: [UInt8] = [255, 0, 0, 255]
        // Top half green, bottom half blue as well, to check the vertical orientation.
        var bytes: [UInt8] = []
        for y in 0..<h { for x in 0..<w { bytes += (x < w / 2) == (y < h / 2) ? top : bottom } }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        let image = try render(head: .identity, texture: t)
        for i in 0..<2 {
            let box = try XCTUnwrap(image.litBox(columns: (i * 960)..<(i * 960 + 960)))
            let qx = (box.maxX - box.minX) / 4, qy = (box.maxY - box.minY) / 4
            XCTAssertEqual(image.bgra(box.minX + qx, box.minY + qy), top, "top-left quadrant")
            XCTAssertEqual(image.bgra(box.maxX - qx, box.minY + qy), bottom, "top-right quadrant")
            XCTAssertEqual(image.bgra(box.minX + qx, box.maxY - qy), bottom, "bottom-left quadrant")
        }
    }

    func testScreenStaysInPlaceWhenTheHeadTurns() throws {
        let tex = solid([255, 255, 255, 255])
        let screen = ScreenPlacement()
        // Small turns, so the screen (±15.7° × ±9° at 1.6 m) stays inside the 42° × 24.7° field of view, unclipped.
        for pose in [HeadPose(yaw: 4, pitch: 0, roll: 0), HeadPose(yaw: -4, pitch: 0, roll: 0),
                     HeadPose(yaw: 0, pitch: 2, roll: 0), HeadPose(yaw: 0, pitch: -2, roll: 0)] {
            let head = pose.quaternion
            let box = try XCTUnwrap(render(head: head, screen: screen, texture: tex).litBox(columns: 0..<960))
            let px = screen.corners.compactMap { displays.left.pixel(of: $0, head: head, width: displays.width, height: displays.height) }
            XCTAssertEqual(Double(box.minX), px.map(\.u).min()! / 2, accuracy: 2, "\(pose)")
            XCTAssertEqual(Double(box.maxX), px.map(\.u).max()! / 2, accuracy: 2, "\(pose)")
            XCTAssertEqual(Double(box.minY), px.map(\.v).min()! / 2, accuracy: 2, "\(pose)")
            XCTAssertEqual(Double(box.maxY), px.map(\.v).max()! / 2, accuracy: 2, "\(pose)")
        }
        // Direction: turning right moves the world left in the image; looking up moves it down.
        let ahead = try XCTUnwrap(render(head: .identity, texture: tex).litBox(columns: 0..<960))
        let right = try XCTUnwrap(render(head: HeadPose(yaw: 4, pitch: 0, roll: 0).quaternion, texture: tex).litBox(columns: 0..<960))
        let up = try XCTUnwrap(render(head: HeadPose(yaw: 0, pitch: 2, roll: 0).quaternion, texture: tex).litBox(columns: 0..<960))
        XCTAssertLessThan(right.maxX, ahead.maxX - 50)
        XCTAssertGreaterThan(up.minY, ahead.minY + 30)
    }

    func testPlaceholderWithoutCapture() throws {
        let image = try render(head: .identity, texture: nil)
        let box = try XCTUnwrap(image.litBox(columns: 0..<960))
        XCTAssertGreaterThan(box.maxX - box.minX, 200)
    }

    func testNothingIsDrawnWithoutCalibration() throws {
        let bytes = try renderer.renderOffscreen(nil, width: 64, height: 32)
        XCTAssertTrue(stride(from: 0, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 0 })
    }

    func testCurvedScreenIsDrawnOnItsCurve() throws {
        let flat = ScreenPlacement(distance: 1.6, width: 0.9, height: 0.5)
        var curved = flat
        curved.curveRadius = 1.0
        let tex = solid([255, 255, 255, 255])
        let flatBox = try XCTUnwrap(render(head: .identity, screen: flat, texture: tex).litBox(columns: 0..<960))
        let image = try render(head: .identity, screen: curved, texture: tex)
        for (i, eye) in [displays.left, displays.right].enumerated() {
            let box = try XCTUnwrap(image.litBox(columns: (i * 960)..<(i * 960 + 960)))
            let e = try expectedBox(curved, eye: eye)
            XCTAssertEqual(Double(box.minX - i * 960), e.minU / 2, accuracy: 2)
            XCTAssertEqual(Double(box.maxX - i * 960), e.maxU / 2, accuracy: 2)
            XCTAssertEqual(Double(box.minY), e.minV / 2, accuracy: 2)
            XCTAssertEqual(Double(box.maxY), e.maxV / 2, accuracy: 2)
        }
        // The edges come toward the viewer: taller at the sides than the flat screen, and wider in view.
        let left = try XCTUnwrap(image.litBox(columns: 0..<960))
        XCTAssertGreaterThan(flatBox.minY - left.minY, 3)
        XCTAssertGreaterThan(left.maxX - left.minX, flatBox.maxX - flatBox.minX)
    }

    func testEveryScreenIsDrawnAndTheNearerOneCoversTheFartherOne() throws {
        let red: [UInt8] = [0, 0, 255, 255], blue: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 255]
        let near = Renderer.Screen(placement: ScreenPlacement(distance: 1.2, width: 0.2, height: 0.12), texture: solid(red))
        let far = Renderer.Screen(placement: ScreenPlacement(distance: 2.5, width: 1.0, height: 0.5), texture: solid(blue))
        let side = Renderer.Screen(placement: ScreenPlacement(yaw: -14, distance: 1.6, width: 0.2, height: 0.12), texture: solid(green))
        for order in [[near, far, side], [far, side, near]] {
            let image = try render(head: .identity, screens: order)
            for (screen, colour) in [(near, red), (side, green)] {
                let c = try XCTUnwrap(displays.left.pixel(of: screen.placement.center, head: .identity,
                                                          width: displays.width, height: displays.height))
                XCTAssertEqual(image.bgra(Int(c.u / 2), Int(c.v / 2)), colour, "order \(order.map(\.placement.distance))")
            }
            let farEdge = try XCTUnwrap(displays.left.pixel(of: far.placement.point(x: 0.4, y: 0), head: .identity,
                                                            width: displays.width, height: displays.height))
            XCTAssertEqual(image.bgra(Int(farEdge.u / 2), Int(farEdge.v / 2)), blue, "the far screen shows around the near one")
        }
    }

    // Issue #15: two screens that cut through each other. Whichever is nearer along each line of sight must show,
    // whatever order they are drawn in.
    func testIntersectingScreensShowWhicheverIsNearerAtEachPoint() throws {
        let red: [UInt8] = [0, 0, 255, 255], blue: [UInt8] = [255, 0, 0, 255]
        let size = SpatialScreen(id: 1, diagonalInches: 85).placement
        let row = ScreenPlacement(distance: 1.5, width: size.width, height: size.height)
        var upper = row
        upper.pitch = 25
        let head = HeadPose(yaw: 0, pitch: 12, roll: 0).quaternion  // both sight lines inside the 24.7° view
        // Along 8° up the row screen (z = 1.5) is nearer; along 17° up the upper one is.
        func hit(_ elevation: Double, distance: Double) throws -> (x: Int, y: Int) {
            let point = HeadPose(yaw: 0, pitch: elevation, roll: 0).quaternion.rotate(Vec3(0, 0, distance))
            let px = try XCTUnwrap(displays.left.pixel(of: point, head: head, width: displays.width, height: displays.height))
            return (Int(px.u / 2), Int(px.v / 2))
        }
        let rad = Double.pi / 180
        let low = try hit(8, distance: 1.5 / cos(8 * rad)), high = try hit(17, distance: 1.5 / cos(8 * rad))
        for order in [[(row, red), (upper, blue)], [(upper, blue), (row, red)]] {
            let image = try render(head: head, screens: order.map { Renderer.Screen(placement: $0.0, texture: solid($0.1)) })
            XCTAssertEqual(image.bgra(low.x, low.y), red, "row screen in front at 8°, drawn \(order.map(\.0.pitch))")
            XCTAssertEqual(image.bgra(high.x, high.y), blue, "upper screen in front at 17°, drawn \(order.map(\.0.pitch))")
        }
    }
}
#endif