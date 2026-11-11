#if canImport(Metal)
import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import simd
import XRealCore

/// Renders textures (the captured virtual displays) as flat or curved screens in 3D, side by side for both eyes
/// (left half: left eye, right half: right eye), using the factory per-eye intrinsics and eye poses and the current
/// head orientation. Black is see-through on the glasses.
public final class Renderer: NSObject, MTKViewDelegate {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4x4 mvp; float width; float height; float curveRadius; int columns; int hasTexture; };
    struct VOut { float4 position [[position]]; float2 uv; };

    // Triangle strip over `columns` vertical strips, in image orientation: x right, y down; uv (0,0) = top-left of
    // the captured display. Same surface as ScreenPlacement.localPoint: flat, or bent toward the viewer on a
    // cylinder of radius curveRadius with the width measured along the arc.
    vertex VOut quad_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 uv = float2(float(vid / 2) / float(u.columns), float(vid % 2));
        float x = uv.x - 0.5, y = uv.y - 0.5;
        float3 p = float3(x * u.width, y * u.height, 0.0);
        if (u.curveRadius > 0.0) {
            float a = x * u.width / u.curveRadius;
            p = float3(u.curveRadius * sin(a), y * u.height, -u.curveRadius * (1.0 - cos(a)));
        }
        VOut o;
        o.position = u.mvp * float4(p, 1.0);
        o.uv = uv;
        return o;
    }

    fragment float4 quad_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        if (u.hasTexture != 0) {
            return tex.sample(s, in.uv);
        }
        // No capture (yet): checkerboard placeholder.
        return fmod(floor(in.uv.x * 16.0) + floor(in.uv.y * 9.0), 2.0) < 1.0 ? float4(0.30, 0.30, 0.36, 1) : float4(0.12, 0.12, 0.15, 1);
    }
    """

    struct Uniforms {
        var mvp: simd_float4x4
        var width: Float
        var height: Float
        var curveRadius: Float
        var columns: Int32
        var hasTexture: Int32
    }

    /// Strips per curved screen: at 48 the chord of a 1 m wide, 1000R screen is within 0.03 mm of the arc.
    static let curvedColumns = 48

    /// One screen and what it shows.
    public struct Screen {
        public var placement: ScreenPlacement
        /// The captured display; nil draws a placeholder.
        public var texture: MTLTexture?

        public init(placement: ScreenPlacement, texture: MTLTexture?) {
            self.placement = placement
            self.texture = texture
        }
    }

    /// What to draw for one frame.
    public struct Scene {
        public var displays: DisplayCalibration
        /// Head → world, recentered (HeadTracker.orientation).
        public var head: Quat
        public var screens: [Screen]

        public init(displays: DisplayCalibration, head: Quat, screens: [Screen]) {
            self.displays = displays
            self.head = head
            self.screens = screens
        }
    }

    public struct MetalError: Error, CustomStringConvertible {
        public var description: String
    }

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sceneSource: () -> (scene: Scene?, keepAlive: Any?)
    private var target: MTLTexture?
    private var pendingSnapshot: (url: URL, done: (Bool) -> Void)?
    public private(set) var framesRendered = 0

    /// `sceneSource` is called on the main thread for every frame. `keepAlive` is retained until the GPU has finished
    /// with the frame (e.g. the CVMetalTexture behind a captured surface).
    public init(device: MTLDevice, sceneSource: @escaping () -> (scene: Scene?, keepAlive: Any?)) throws {
        self.device = device
        self.sceneSource = sceneSource
        guard let queue = device.makeCommandQueue() else { throw MetalError(description: "no command queue") }
        self.queue = queue
        let library = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "quad_vertex")
        desc.fragmentFunction = library.makeFunction(name: "quad_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        super.init()
    }

    /// Configures `view` to show the full side-by-side frame (scaled to the view's size).
    public func attach(to view: MTKView, eyeWidth: Int, eyeHeight: Int) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 2 * eyeWidth, height: eyeHeight)
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
    }

    /// Saves the next rendered frame as PNG; `done` reports success (on a Metal thread).
    public func snapshot(to url: URL, done: @escaping (Bool) -> Void) { pendingSnapshot = (url, done) }

    /// Encodes the side-by-side frame into `target` (BGRA8, width = 2 × eye width).
    public func encode(_ scene: Scene?, into target: MTLTexture, commandBuffer cb: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { enc.endEncoding() }
        guard let scene else { return }
        enc.setRenderPipelineState(pipeline)
        let d = scene.displays
        let eyeW = Double(target.width) / 2
        // Farthest first, so a nearer screen covers a farther one where they overlap.
        let screens = scene.screens.sorted { $0.placement.distance > $1.placement.distance }
        for (i, eye) in [d.left, d.right].enumerated() {
            enc.setViewport(MTLViewport(originX: Double(i) * eyeW, originY: 0, width: eyeW, height: Double(target.height), znear: 0, zfar: 1))
            let viewProjection = eye.projection(width: d.width, height: d.height) * eye.view(head: scene.head)
            for screen in screens {
                let p = screen.placement
                let columns = p.curveRadius > 0 ? Self.curvedColumns : 1
                var u = Uniforms(mvp: simd_float4x4(viewProjection * p.pose), width: Float(p.width), height: Float(p.height),
                                 curveRadius: Float(p.curveRadius), columns: Int32(columns),
                                 hasTexture: screen.texture == nil ? 0 : 1)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setFragmentTexture(screen.texture, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 2 * (columns + 1))
            }
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
        if target?.width != w || target?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            target = device.makeTexture(descriptor: d)
        }
        guard let target else { return }
        let (scene, keepAlive) = sceneSource()
        encode(scene, into: target, commandBuffer: cb)

        var snapshotTexture: MTLTexture?
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: target, to: drawable.texture)
            if pendingSnapshot != nil {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                d.storageMode = .shared
                snapshotTexture = device.makeTexture(descriptor: d)
                if let s = snapshotTexture { blit.copy(from: target, to: s) }
            }
            blit.endEncoding()
        }
        let snapshot = pendingSnapshot
        pendingSnapshot = nil
        cb.addCompletedHandler { _ in
            withExtendedLifetime(keepAlive) {}
            if let s = snapshotTexture, let snapshot { snapshot.done(Renderer.writePNG(s, to: snapshot.url)) }
        }
        cb.present(drawable)
        cb.commit()
        framesRendered += 1
    }

    /// Renders one frame offscreen and returns its BGRA bytes (width × height × 4). For tests and snapshots.
    public func renderOffscreen(_ scene: Scene?, width: Int, height: Int) throws -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else {
            throw MetalError(description: "cannot allocate the offscreen target")
        }
        encode(scene, into: texture, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw MetalError(description: "GPU: \(error)") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    public static func writePNG(_ texture: MTLTexture, to url: URL) -> Bool {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}

extension simd_float4x4 {
    init(_ m: Mat4) {
        let f = m.floats
        self.init(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                            SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
    }
}
#endif
