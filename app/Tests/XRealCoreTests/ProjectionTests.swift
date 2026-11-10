import CaptureTools
import XCTest
@testable import XRealCore

final class ProjectionTests: XCTestCase {
    func displays() throws -> DisplayCalibration { try Fixtures.capture().calibration.displays }

    func testPointOnTheEyeAxisLandsOnThePrincipalPoint() throws {
        let d = try displays()
        for eye in [d.left, d.right] {
            // A point 2 m along the eye's own optical axis.
            let world = eye.position + eye.rotation.rotate(Vec3(0, 0, 2))
            let px = try XCTUnwrap(eye.pixel(of: world, head: .identity, width: d.width, height: d.height))
            XCTAssertEqual(px.u, eye.cx, accuracy: 1e-6)
            XCTAssertEqual(px.v, eye.cy, accuracy: 1e-6)
        }
    }

    func testFieldOfViewMatchesBrief() throws {
        let l = try displays().left
        // BRIEF.md: 42.2° × 24.7°.
        XCTAssertEqual(2 * atan(960 / l.fx) * 180 / .pi, 42.2, accuracy: 0.1)
        XCTAssertEqual(2 * atan(540 / l.fy) * 180 / .pi, 24.7, accuracy: 0.1)
    }

    func testStereoDisparityAndHeadTurn() throws {
        let d = try displays()
        let screen = ScreenPlacement(distance: 1.6)
        let l = try XCTUnwrap(d.left.pixel(of: screen.center, head: .identity, width: d.width, height: d.height))
        let r = try XCTUnwrap(d.right.pixel(of: screen.center, head: .identity, width: d.width, height: d.height))
        // The left eye sits 64.4 mm left of the right eye, so a near object appears further right in the left image:
        // fx·baseline/z ≈ 2490·0.0644/1.6 ≈ 100 px. The factory eye rotations toe the displays in by 0.66° + 0.56°
        // (≈ 53 px), so the images converge at ≈ 3 m and the disparity at 1.6 m is ≈ 47 px.
        XCTAssertEqual((l.u - d.left.cx) - (r.u - d.right.cx), 47, accuracy: 5)
        let far = ScreenPlacement(distance: 3.0)
        let lf = try XCTUnwrap(d.left.pixel(of: far.center, head: .identity, width: d.width, height: d.height))
        let rf = try XCTUnwrap(d.right.pixel(of: far.center, head: .identity, width: d.width, height: d.height))
        XCTAssertEqual((lf.u - d.left.cx) - (rf.u - d.right.cx), 0, accuracy: 5)

        // Turning the head 20° right moves the screen ≈ fx·tan(20°) ≈ 906 px left in both images.
        let turned = HeadPose(yaw: 20, pitch: 0, roll: 0).quaternion
        let lt = try XCTUnwrap(d.left.pixel(of: screen.center, head: turned, width: d.width, height: d.height))
        XCTAssertEqual(l.u - lt.u, 906, accuracy: 40)
        XCTAssertEqual(lt.v, l.v, accuracy: 15)

        // Looking up 10° moves it down in the image.
        let up = HeadPose(yaw: 0, pitch: 10, roll: 0).quaternion
        let lu = try XCTUnwrap(d.left.pixel(of: screen.center, head: up, width: d.width, height: d.height))
        XCTAssertEqual(lu.v - l.v, 2463 * tan(10 * Double.pi / 180), accuracy: 40)
    }

    func testPointBehindTheHeadIsNotProjected() throws {
        let d = try displays()
        XCTAssertNil(d.left.pixel(of: Vec3(0, 0, -2), head: .identity, width: d.width, height: d.height))
    }

    func testScreenCornersFaceTheHeadInImageOrientation() {
        let s = ScreenPlacement(yaw: 30, pitch: 10, distance: 2, width: 1, height: 0.5)
        let c = s.corners
        // Top-left → top-right runs to the viewer's right; top → bottom runs down.
        let right = (c[1] - c[0]).normalized, down = (c[2] - c[0]).normalized
        let toward = (Vec3.zero - s.center).normalized
        XCTAssertEqual((c[1] - c[0]).length, 1, accuracy: 1e-9)
        XCTAssertEqual((c[2] - c[0]).length, 0.5, accuracy: 1e-9)
        XCTAssertEqual(right.cross(down).dot(toward), -1, accuracy: 1e-9)  // normal points away from the viewer
        XCTAssertEqual(HeadPose(yaw: 30, pitch: 10, roll: 0).quaternion.rotate(Vec3(1, 0, 0)).dot(right), 1, accuracy: 1e-9)
        XCTAssertEqual(s.center.length, 2, accuracy: 1e-9)
    }
}
