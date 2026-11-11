import Foundation

/// Column-major 4×4 matrix (Metal's layout). `m[c][r]`.
public struct Mat4: Equatable, Sendable {
    public var columns: [[Double]]

    public init(columns: [[Double]]) {
        precondition(columns.count == 4 && columns.allSatisfy { $0.count == 4 })
        self.columns = columns
    }

    public init(rows: [[Double]]) {
        self.init(columns: (0..<4).map { c in (0..<4).map { r in rows[r][c] } })
    }

    public static let identity = Mat4(rows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])

    /// Rotation `q` then translation `t`: p ↦ q·p + t.
    public init(rotation q: Quat, translation t: Vec3 = .zero) {
        let x = q.rotate(Vec3(1, 0, 0)), y = q.rotate(Vec3(0, 1, 0)), z = q.rotate(Vec3(0, 0, 1))
        self.init(columns: [[x.x, x.y, x.z, 0], [y.x, y.y, y.z, 0], [z.x, z.y, z.z, 0], [t.x, t.y, t.z, 1]])
    }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        Mat4(columns: (0..<4).map { c in
            (0..<4).map { r in (0..<4).reduce(0.0) { $0 + a.columns[$1][r] * b.columns[c][$1] } }
        })
    }

    /// Homogeneous transform of (x, y, z, 1).
    public func apply(_ p: Vec3) -> (x: Double, y: Double, z: Double, w: Double) {
        let v = [p.x, p.y, p.z, 1.0]
        let r = (0..<4).map { row in (0..<4).reduce(0.0) { $0 + columns[$1][row] * v[$1] } }
        return (r[0], r[1], r[2], r[3])
    }

    /// Column-major Float values for a GPU buffer.
    public var floats: [Float] { columns.flatMap { $0.map(Float.init) } }
}

extension EyeCalibration {
    /// Projection matching the factory pinhole model, for a viewport of the panel's size.
    ///
    /// Eye frame is the sensor convention (x right, y down, z forward), as in OpenCV, which the intrinsics use:
    /// pixel u = fx·x/z + cx, v = fy·y/z + cy, with v growing downward. Metal clip space has y up and depth 0…1.
    public func projection(width: Int, height: Int, near: Double = 0.1, far: Double = 100) -> Mat4 {
        let w = Double(width), h = Double(height)
        return Mat4(rows: [
            [2 * fx / w, 0, 2 * cx / w - 1, 0],
            [0, -2 * fy / h, 1 - 2 * cy / h, 0],
            [0, 0, far / (far - near), -far * near / (far - near)],
            [0, 0, 1, 0],
        ])
    }

    /// World → eye. `head` is the head orientation (head → world, from HeadTracker); the head sits at the world
    /// origin. The factory pose gives the eye in the IMU frame: p_imu = rotation·p_eye + position.
    public func view(head: Quat) -> Mat4 {
        let eyeToWorld = head * rotation
        let eyeOrigin = head.rotate(position)
        let inv = eyeToWorld.conjugate
        return Mat4(rotation: inv, translation: -inv.rotate(eyeOrigin))
    }

    /// Pixel coordinates of a world point, or nil if behind the eye.
    public func pixel(of world: Vec3, head: Quat, width: Int, height: Int) -> (u: Double, v: Double)? {
        let clip = (projection(width: width, height: height) * view(head: head)).apply(world)
        guard clip.w > 0 else { return nil }
        let x = clip.x / clip.w, y = clip.y / clip.w
        return ((x + 1) / 2 * Double(width), (1 - y) / 2 * Double(height))
    }
}

/// A virtual screen floating in the world frame (X right, Y down, Z forward at the recentered heading): flat, or bent
/// around a vertical axis like a curved monitor, edges toward the viewer.
public struct ScreenPlacement: Equatable, Sendable {
    /// Direction of the screen centre from the head, degrees (same sign conventions as HeadPose).
    public var yaw: Double
    public var pitch: Double
    /// Metres from the head to the screen centre.
    public var distance: Double
    /// Metres, measured along the surface (a curved screen keeps its flat width, like a real curved monitor).
    public var width: Double
    public var height: Double
    /// Radius of the curve in metres (1.8 = an "1800R" monitor); 0 = flat.
    public var curveRadius: Double

    public init(yaw: Double = 0, pitch: Double = 0, distance: Double = 1.6, width: Double = 0.9, height: Double = 0.50625,
                curveRadius: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.width = width
        self.height = height
        self.curveRadius = curveRadius
    }

    /// The screen faces the head: its local frame is the head frame turned by (yaw, pitch).
    var orientation: Quat { HeadPose(yaw: yaw, pitch: pitch, roll: 0).quaternion }

    public var center: Vec3 { orientation.rotate(Vec3(0, 0, distance)) }

    /// Screen-local → world: the local frame has +x right, +y down (image orientation), +z away from the viewer, and
    /// its origin at the screen centre.
    public var pose: Mat4 { Mat4(rotation: orientation, translation: center) }

    /// Curve angle across the whole width, radians (0 = flat). The renderer's vertex shader uses the same formula as
    /// `localPoint`.
    public var arc: Double { curveRadius > 0 ? width / curveRadius : 0 }

    /// Screen-local point (metres) for surface coordinates x, y ∈ [−0.5, 0.5] (+x right, +y down).
    public func localPoint(x: Double, y: Double) -> Vec3 {
        guard curveRadius > 0 else { return Vec3(x * width, y * height, 0) }
        let a = x * arc
        return Vec3(curveRadius * sin(a), y * height, -curveRadius * (1 - cos(a)))
    }

    /// World point for surface coordinates x, y ∈ [−0.5, 0.5].
    public func point(x: Double, y: Double) -> Vec3 {
        let p = pose.apply(localPoint(x: x, y: y))
        return Vec3(p.x, p.y, p.z)
    }

    /// Corners in world space: top-left, top-right, bottom-left, bottom-right.
    public var corners: [Vec3] {
        [(-0.5, -0.5), (0.5, -0.5), (-0.5, 0.5), (0.5, 0.5)].map { point(x: $0, y: $1) }
    }

    /// Horizontal and vertical angle the screen covers, seen from the head, degrees.
    public var angularSize: (width: Double, height: Double) {
        let edge = localPoint(x: 0.5, y: 0)
        let halfWidth = atan2(edge.x, distance + edge.z)
        return (2 * halfWidth * 180 / .pi, 2 * atan2(height / 2, distance) * 180 / .pi)
    }
}
