#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ScreenCaptureKit

/// Screen Recording permission (TCC). macOS shows its own prompt; only the user can grant it.
enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS to show the permission prompt (once per app; afterwards the user must use System Settings).
    /// Returns whether access is granted now; a new grant usually takes effect only after the app restarts.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static var instructions: String {
        let app = Bundle.main.bundleURL.path
        return "Screen Recording permission is missing for \(app). Grant it in System Settings › Privacy & Security › "
            + "Screen & System Audio Recording: switch on \"XRealDesk\" (use + and choose that app if it is not listed), "
            + "then quit and reopen XRealDesk."
    }
}

/// Live frames of one display as Metal textures.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame {
        let texture: MTLTexture
        /// Keeps the IOSurface-backed texture alive while the GPU reads it.
        let backing: CVMetalTexture
    }

    enum CaptureError: Error, CustomStringConvertible {
        case displayNotShareable(CGDirectDisplayID)
        case textureCache(CVReturn)

        var description: String {
            switch self {
            case .displayNotShareable(let id): return "display \(id) did not appear in ScreenCaptureKit's shareable content"
            case .textureCache(let r): return "CVMetalTextureCacheCreate failed (\(r))"
            }
        }
    }

    private let queue = DispatchQueue(label: "XRealDesk.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var cache: CVMetalTextureCache?
    private var latest: Frame?
    private var stream: SCStream?
    private(set) var frameCount = 0
    var onStop: ((Error) -> Void)?

    init(device: MTLDevice) throws {
        super.init()
        let r = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard r == kCVReturnSuccess else { throw CaptureError.textureCache(r) }
    }

    var latestFrame: Frame? { lock.withLock { latest } }
    var framesReceived: Int { lock.withLock { frameCount } }

    /// Starts capturing `displayID` at its native pixel size. A just-created display can take a moment to become
    /// shareable, so this retries for a few seconds.
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int = 60) async throws {
        var display: SCDisplay?
        for _ in 0..<25 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let display else { throw CaptureError.displayNotShareable(displayID) }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.showsCursor = true
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
    }

    func stop() async {
        guard let stream = lock.withLock({ self.stream }) else { return }
        try? await stream.stopCapture()
        lock.withLock { self.stream = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = lock.withLock({ self.cache }) else { return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, .bgra8Unorm, w, h, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return }
        lock.withLock {
            latest = Frame(texture: texture, backing: cvTexture)
            frameCount += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { self.stream = nil }
        onStop?(error)
    }
}
#endif
