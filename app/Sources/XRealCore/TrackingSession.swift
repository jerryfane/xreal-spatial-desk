import Foundation

/// Head tracking shared between the GlassesLink threads (writers) and the renderer (reader).
///
/// IMU samples that arrive before the factory calibration are buffered (last 2 s) and replayed when it arrives.
/// Tracking recenters itself once, 0.5 s after it starts (first gravity-like sample), so the view starts straight
/// ahead whatever order the calibration and the first samples arrive in.
public final class TrackingSession: @unchecked Sendable {
    private enum AutoRecenter {
        case waitingForTracking
        case at(UInt64)
        case done
    }

    private let lock = NSLock()
    private var tracker: HeadTracker?
    private var storedCalibration: FactoryCalibration?
    private var pending: [IMUSample] = []
    private var autoRecenter = AutoRecenter.waitingForTracking
    private static let autoRecenterDelayNs: UInt64 = 500_000_000
    private static let maxPending = 2000

    public init() {}

    /// The factory calibration, once received.
    public var calibration: FactoryCalibration? { lock.withLock { storedCalibration } }

    /// Head orientation (head → world, recentered); identity until tracking starts.
    public var orientation: Quat { lock.withLock { trackingTracker?.orientation ?? .identity } }

    /// Current pose, or nil until tracking starts.
    public var pose: HeadPose? { lock.withLock { trackingTracker?.pose } }

    /// Sets the calibration. The first one starts tracking (replaying buffered samples); later ones (reconnects)
    /// only replace the stored value. Returns whether this call started tracking.
    @discardableResult
    public func setCalibration(_ calibration: FactoryCalibration) -> Bool {
        lock.withLock {
            storedCalibration = calibration
            guard tracker == nil else { return false }
            tracker = HeadTracker(calibration: calibration.imu)
            let buffered = pending
            pending = []
            buffered.forEach(updateLocked)
            return true
        }
    }

    public func add(_ sample: IMUSample) {
        lock.withLock {
            guard tracker != nil else {
                pending.append(sample)
                if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
                return
            }
            updateLocked(sample)
        }
    }

    public func recenter() {
        lock.withLock { tracker?.recenter() }
    }

    private var trackingTracker: HeadTracker? {
        guard let t = tracker, t.isInitialized else { return nil }
        return t
    }

    private func updateLocked(_ sample: IMUSample) {
        tracker!.update(sample)
        guard tracker!.isInitialized, let now = tracker!.lastTimestampNs else { return }
        switch autoRecenter {
        case .waitingForTracking:
            autoRecenter = .at(now + Self.autoRecenterDelayNs)
        case .at(let deadline) where now >= deadline:
            tracker!.recenter()
            autoRecenter = .done
        case .at, .done:
            break
        }
    }
}
