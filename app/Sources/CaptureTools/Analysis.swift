import Foundation
import XRealCore

/// Head pose over a recording, for measuring the tracker against the recorded steps.
public struct PoseTrack {
    /// Seconds from the first marker.
    public private(set) var times: [Double] = []
    public private(set) var poses: [HeadPose] = []
    /// Calibrated angular rate magnitude, °/s.
    public private(set) var rates: [Double] = []

    public init() {}

    public mutating func append(time: Double, pose: HeadPose, rate: Double) {
        times.append(time)
        poses.append(pose)
        rates.append(rate)
    }

    /// Runs a fresh tracker over `samples` and records every pose.
    public init(samples: [IMUSample], tracker: HeadTracker, time: (IMUSample) -> Double) {
        var tracker = tracker
        reserve(samples.count)
        for s in samples {
            tracker.update(s)
            guard tracker.isInitialized else { continue }
            append(time: time(s), pose: tracker.pose, rate: tracker.angularRate.length * 180 / .pi)
        }
    }

    mutating func reserve(_ n: Int) {
        times.reserveCapacity(n)
        poses.reserveCapacity(n)
        rates.reserveCapacity(n)
    }

    public var isEmpty: Bool { times.isEmpty }

    func index(atOrAfter t: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func range(_ start: Double, _ end: Double) -> Range<Int> {
        index(atOrAfter: start)..<index(atOrAfter: end)
    }

    /// Rate smoothed with a centred moving average of `window` samples.
    func smoothedRates(window: Int) -> [Double] {
        guard !rates.isEmpty else { return [] }
        var prefix = [0.0]
        prefix.reserveCapacity(rates.count + 1)
        for r in rates { prefix.append(prefix.last! + r) }
        return rates.indices.map { i in
            let lo = max(0, i - window / 2), hi = min(rates.count, i + window / 2 + 1)
            return (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
    }
}

/// Extent of a pose over an interval, relative to the pose at its start. Degrees.
public struct Excursion: Equatable, Sendable {
    public var yaw: ClosedRange<Double>
    public var pitch: ClosedRange<Double>
    public var roll: ClosedRange<Double>
    /// Pose at the end minus pose at the start.
    public var net: HeadPose

    init(_ track: PoseTrack, _ r: Range<Int>) {
        let p0 = track.poses[r.lowerBound]
        var y = (0.0, 0.0), p = (0.0, 0.0), q = (0.0, 0.0)
        for i in r {
            let d = track.poses[i]
            let dy = angleDifference(d.yaw, p0.yaw), dp = d.pitch - p0.pitch, dr = angleDifference(d.roll, p0.roll)
            y = (min(y.0, dy), max(y.1, dy))
            p = (min(p.0, dp), max(p.1, dp))
            q = (min(q.0, dr), max(q.1, dr))
        }
        yaw = y.0...y.1
        pitch = p.0...p.1
        roll = q.0...q.1
        let e = track.poses[r.upperBound - 1]
        net = HeadPose(yaw: angleDifference(e.yaw, p0.yaw), pitch: e.pitch - p0.pitch, roll: angleDifference(e.roll, p0.roll))
    }

    /// The axis with the largest excursion.
    public var dominantAxis: String {
        let spans = [("yaw", yaw.upperBound - yaw.lowerBound), ("pitch", pitch.upperBound - pitch.lowerBound),
                     ("roll", roll.upperBound - roll.lowerBound)]
        return spans.max { $0.1 < $1.1 }!.0
    }
}

/// a − b wrapped to (−180, 180].
func angleDifference(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d <= -180 { d += 360 }
    return d
}

public struct StepReport: Sendable {
    public var name: String
    public var start: Double
    public var end: Double
    public var excursion: Excursion
}

public struct MotionSegment: Sendable {
    public var start: Double
    public var end: Double
    /// Recorded step whose window contains the start.
    public var step: String
    public var excursion: Excursion
}

public struct StillPose: Sendable {
    public var step: String
    /// The quietest second inside the step window.
    public var start: Double
    public var end: Double
    public var mean: HeadPose
}

public struct RestDrift: Sendable {
    /// Longest interval with smoothed rate below the threshold (glasses lying still).
    public var start: Double
    public var end: Double
    /// Pose change over the interval divided by its length, °/min.
    public var yawPerMinute: Double
    public var pitchPerMinute: Double
    public var rollPerMinute: Double
}

public struct TrackingReport: Sendable {
    public var steps: [StepReport]
    public var motions: [MotionSegment]
    /// still_center and still_end, the two "look straight ahead" periods.
    public var still: [StillPose]
    public var rest: RestDrift?
    public var duration: Double

    /// Pose at still_end minus pose at still_center (absolute, no recenter in between).
    public var startToEnd: HeadPose? {
        guard let a = still.first, let b = still.last, still.count == 2 else { return nil }
        return HeadPose(yaw: angleDifference(b.mean.yaw, a.mean.yaw), pitch: b.mean.pitch - a.mean.pitch,
                        roll: angleDifference(b.mean.roll, a.mean.roll))
    }

    /// - Parameters:
    ///   - markers: step names and start times (s); the last entry ends the recording.
    ///   - motionThreshold: smoothed rate (°/s) above which the head counts as moving.
    ///   - restThreshold: smoothed rate (°/s) below which the glasses count as lying still.
    public init(track: PoseTrack, markers: [(name: String, start: Double)],
                motionThreshold: Double = 15, restThreshold: Double = 1.5) {
        precondition(markers.count >= 2)
        duration = (track.times.last ?? 0) - (track.times.first ?? 0)
        func step(at t: Double) -> String {
            markers.last { $0.start <= t }?.name ?? markers[0].name
        }

        steps = zip(markers, markers.dropFirst()).compactMap { a, b in
            let r = track.range(a.start, b.start)
            guard r.count > 1 else { return nil }
            return StepReport(name: a.name, start: a.start, end: b.start, excursion: Excursion(track, r))
        }

        // Motion segments: smoothed rate above threshold, gaps shorter than 150 ms bridged, shorter than 80 ms dropped.
        let smooth = track.smoothedRates(window: 100)
        var motions: [MotionSegment] = []
        var i = 0
        while i < smooth.count {
            guard smooth[i] > motionThreshold else { i += 1; continue }
            let s = i
            var lastMoving = i
            while i < smooth.count && track.times[i] - track.times[lastMoving] < 0.15 {
                if smooth[i] > motionThreshold { lastMoving = i }
                i += 1
            }
            let r = s..<(lastMoving + 1)
            if track.times[lastMoving] - track.times[s] >= 0.08 {
                motions.append(MotionSegment(start: track.times[s], end: track.times[lastMoving],
                                             step: step(at: track.times[s]), excursion: Excursion(track, r)))
            }
        }
        self.motions = motions

        still = ["still_center", "still_end"].compactMap { name in
            guard let k = markers.firstIndex(where: { $0.name == name }), k + 1 < markers.count else { return nil }
            let r = track.range(markers[k].start, markers[k + 1].start)
            let n = track.index(atOrAfter: track.times[r.lowerBound] + 1) - r.lowerBound
            guard n > 0, r.count > n else { return nil }
            var best = r.lowerBound, bestSum = Double.infinity, sum = 0.0
            for j in r.lowerBound..<(r.lowerBound + n) { sum += track.rates[j] }
            for j in r.lowerBound..<(r.upperBound - n) {
                if sum < bestSum { bestSum = sum; best = j }
                sum += track.rates[j + n] - track.rates[j]
            }
            let w = best..<(best + n)
            let ref = track.poses[w.lowerBound]
            var y = 0.0, p = 0.0, q = 0.0
            for j in w {
                y += angleDifference(track.poses[j].yaw, ref.yaw)
                p += track.poses[j].pitch
                q += angleDifference(track.poses[j].roll, ref.roll)
            }
            let c = Double(n)
            return StillPose(step: name, start: track.times[w.lowerBound], end: track.times[w.upperBound - 1],
                             mean: HeadPose(yaw: ref.yaw + y / c, pitch: p / c, roll: ref.roll + q / c))
        }

        var bestRest: Range<Int>?
        i = 0
        while i < smooth.count {
            guard smooth[i] < restThreshold else { i += 1; continue }
            let s = i
            while i < smooth.count && smooth[i] < restThreshold { i += 1 }
            if bestRest == nil || track.times[i - 1] - track.times[s] > track.times[bestRest!.upperBound - 1] - track.times[bestRest!.lowerBound] {
                bestRest = s..<i
            }
        }
        if let r = bestRest, track.times[r.upperBound - 1] - track.times[r.lowerBound] >= 0.5 {
            let e = Excursion(track, r)
            let minutes = (track.times[r.upperBound - 1] - track.times[r.lowerBound]) / 60
            rest = RestDrift(start: track.times[r.lowerBound], end: track.times[r.upperBound - 1],
                             yawPerMinute: e.net.yaw / minutes, pitchPerMinute: e.net.pitch / minutes,
                             rollPerMinute: e.net.roll / minutes)
        } else {
            rest = nil
        }
    }

    public func formatted() -> String {
        func f(_ x: Double, _ w: Int = 6) -> String {
            let s = String(format: "%.1f", x)
            return String(repeating: " ", count: max(0, w - s.count)) + s
        }
        func r(_ x: ClosedRange<Double>) -> String { "[\(f(x.lowerBound)),\(f(x.upperBound))]" }
        func pad(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: max(0, w - s.count)) }

        var out = "Per recorded step (degrees relative to the pose at the step's start; yaw>0 right, pitch>0 up, roll>0 right ear down)\n"
        out += "step          window s        yaw range         pitch range       roll range        net y/p/r\n"
        for s in steps {
            let e = s.excursion
            out += "\(pad(s.name, 13)) \(f(s.start, 5))–\(f(s.end, 5))  \(r(e.yaw))  \(r(e.pitch))  \(r(e.roll))  \(f(e.net.yaw))\(f(e.net.pitch))\(f(e.net.roll))\n"
        }
        out += "\nDetected head motions (smoothed rate > 15 °/s)\n"
        out += "time s          during step   dominant  yaw range         pitch range       roll range\n"
        for m in motions {
            let e = m.excursion
            out += "\(f(m.start, 5))–\(f(m.end, 5))  \(pad(m.step, 13)) \(pad(e.dominantAxis, 8))  \(r(e.yaw))  \(r(e.pitch))  \(r(e.roll))\n"
        }
        out += "\nDrift\n"
        for s in still {
            out += "  \(pad(s.step, 13)) quietest 1 s at \(f(s.start, 5)) s: yaw \(f(s.mean.yaw)) pitch \(f(s.mean.pitch)) roll \(f(s.mean.roll))\n"
        }
        if let d = startToEnd {
            out += "  still_end − still_center: yaw \(f(d.yaw)) pitch \(f(d.pitch)) roll \(f(d.roll))  (over \(f(still[1].start - still[0].start, 4)) s)\n"
        }
        if let d = rest {
            out += "  longest rest (glasses still) \(f(d.start, 5))–\(f(d.end, 5)) s: yaw \(f(d.yawPerMinute)) pitch \(f(d.pitchPerMinute)) roll \(f(d.rollPerMinute)) °/min\n"
        }
        return out
    }
}
