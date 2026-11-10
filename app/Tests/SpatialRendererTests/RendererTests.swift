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
        // Half resolution keeps the test fast; the projection scales with the viewport.
        let w = 1920, h = 540
        let scene = Renderer.Scene(displays: displays, head: head, screen: screen, texture: texture)
        return Image(bytes: try renderer.renderOffscreen(scene, width: w, height: h), width: w, height: h)
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
        let ahead = try XCTUnwrap(render(head: .identity, texture: tex).litBox(columns: 0..<960))
        let right = try XCTUnwrap(render(head: HeadPose(yaw: 10, pitch: 0, roll: 0).quaternion, texture: tex).litBox(columns: 0..<960))
        let up = try XCTUnwrap(render(head: HeadPose(yaw: 0, pitch: 8, roll: 0).quaternion, texture: tex).litBox(columns: 0..<960))
        // Turning right moves the world (and the screen) left in the image by ≈ fx·tan(10°)/2 ≈ 220 px at half size.
        XCTAssertEqual(Double(ahead.minX - right.minX), 2490 * tan(10 * Double.pi / 180) / 2, accuracy: 20)
        // Looking up moves it down.
        XCTAssertGreaterThan(up.minY, ahead.minY + 100)
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
}
#endif
