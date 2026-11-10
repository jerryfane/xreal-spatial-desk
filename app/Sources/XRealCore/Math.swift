import Foundation

public struct Vec3: Equatable, Sendable {
    public var x, y, z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { dot(self).squareRoot() }
    public var normalized: Vec3 { self * (1 / length) }
}

/// Row-major 3×3 matrix.
public struct Mat3: Equatable, Sendable {
    public var m: [Double]

    public init(rowMajor m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = Mat3(rowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public static func * (a: Mat3, v: Vec3) -> Vec3 {
        Vec3(a.m[0] * v.x + a.m[1] * v.y + a.m[2] * v.z,
             a.m[3] * v.x + a.m[4] * v.y + a.m[5] * v.z,
             a.m[6] * v.x + a.m[7] * v.y + a.m[8] * v.z)
    }
}

/// Hamilton unit quaternion. As an orientation it maps head-frame vectors to world-frame vectors.
public struct Quat: Equatable, Sendable {
    public var w, x, y, z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    public init(axis: Vec3, angle: Double) {
        let n = axis.normalized
        let s = sin(angle / 2)
        self.init(w: cos(angle / 2), x: n.x * s, y: n.y * s, z: n.z * s)
    }

    /// Rotation by `v` (axis × angle in radians); exact for any magnitude.
    public init(rotationVector v: Vec3) {
        let angle = v.length
        if angle < 1e-12 {
            self.init(w: 1, x: v.x / 2, y: v.y / 2, z: v.z / 2)
        } else {
            self.init(axis: v, angle: angle)
        }
    }

    /// The shortest rotation taking unit vector `a` to unit vector `b`.
    public init(from a: Vec3, to b: Vec3) {
        let c = a.cross(b)
        let d = a.dot(b)
        if d < -0.999999 {
            // Opposite vectors: rotate 180° about any axis perpendicular to `a`.
            let p = abs(a.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
            self.init(axis: a.cross(p), angle: .pi)
        } else {
            self = Quat(w: 1 + d, x: c.x, y: c.y, z: c.z).normalized
        }
    }

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
             x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    public var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

    public var normalized: Quat {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return Quat(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public func rotate(_ v: Vec3) -> Vec3 {
        let u = Vec3(x, y, z)
        let t = u.cross(v) * 2
        return v + t * w + u.cross(t)
    }

    /// Angle of the rotation, radians in [0, π].
    public var angle: Double { 2 * atan2(Vec3(x, y, z).length, abs(w)) }
}
