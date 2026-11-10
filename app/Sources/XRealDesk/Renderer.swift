#if os(macOS)
import Foundation
import ImageIO
import Metal
import MetalKit
import simd
import XRealCore

/// Renders the captured virtual display as a flat screen in 3D, side by side for both eyes (2 × 1920×1080),
/// using the factory per-eye intrinsics and eye poses and the current head orientation.
final class Renderer: NSObject, MTKViewDelegate {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4x4 mvp; int hasTexture; };
    struct VOut { float4 position [[position]]; float2 uv; };

    // Unit quad in image orientation: x right, y down; uv (0,0) = top-left of the captured display.
    vertex VOut quad_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        const float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
        VOut o;
        o.position = u.mvp * float4(corners[vid], 0.0, 1.0);
        o.uv = corners[vid] + 0.5;
        return o;
    }

    fragment float4 quad_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c;
        if (u.hasTexture != 0) {
            c = tex.sample(s, in.uv);
        } else {  // no capture (yet): checkerboard placeholder
            c = fmod(floor(in.uv.x * 16.0) + floor(in.uv.y * 9.0), 2.0) < 1.0 ? float4(0.30, 0.30, 0.36, 1) : float4(0.12, 0.12, 0.15, 1);
        }
        float edge = min(min(in.uv.x, 1.0 - in.uv.x), min(in.uv.y, 1.0 - in.uv.y));
        return edge < 0.003 ? float4(0.85, 0.85, 0.85, 1) : c;
    }
    """

    struct Uniforms {
        var mvp: simd_float4x4
        var hasTexture: Int32
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let head: HeadState
    private let frameSource: () -> ScreenCapture.Frame?
    private var target: MTLTexture?
    private var pendingSnapshot: URL?
    var screen = ScreenPlacement()
    private(set) var framesRendered = 0

    init(device: MTLDevice, head: HeadState, frameSource: @escaping () -> ScreenCapture.Frame?) throws {
        self.device = device
        self.head = head
        self.frameSource = frameSource
        guard let queue = device.makeCommandQueue() else { throw OptionError("Metal: no command queue") }
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
    func attach(to view: MTKView, eyeWidth: Int, eyeHeight: Int) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 2 * eyeWidth, height: eyeHeight)
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
    }

    /// Saves the next rendered frame as PNG.
    func snapshot(to url: URL) { pendingSnapshot = url }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
        if target?.width != w || target?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            target = device.makeTexture(descriptor: d)
        }
        guard let target else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)  // black = see-through
        pass.colorAttachments[0].storeAction = .store
        let frame = frameSource()
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            if let cal = head.calibration?.displays {
                enc.setRenderPipelineState(pipeline)
                let orientation = head.orientation
                for (i, eye) in [cal.left, cal.right].enumerated() {
                    let eyeW = Double(w) / 2
                    enc.setViewport(MTLViewport(originX: Double(i) * eyeW, originY: 0, width: eyeW, height: Double(h), znear: 0, zfar: 1))
                    let mvp = eye.projection(width: cal.width, height: cal.height) * eye.view(head: orientation) * screen.model
                    var u = Uniforms(mvp: simd_float4x4(mvp), hasTexture: frame == nil ? 0 : 1)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.setFragmentTexture(frame?.texture, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            enc.endEncoding()
        }

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
        let snapshotURL = pendingSnapshot
        pendingSnapshot = nil
        cb.addCompletedHandler { _ in
            _ = frame  // the captured surface stays alive until the GPU is done with it
            if let s = snapshotTexture, let url = snapshotURL { Renderer.writePNG(s, to: url) }
        }
        cb.present(drawable)
        cb.commit()
        framesRendered += 1
    }

    static func writePNG(_ texture: MTLTexture, to url: URL) {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            Log.line("snapshot: could not encode \(url.lastPathComponent)")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        Log.line(CGImageDestinationFinalize(dest) ? "snapshot: wrote \(url.lastPathComponent)" : "snapshot: FAILED \(url.lastPathComponent)")
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
