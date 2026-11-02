import Accelerate
import MetalKit
import simd

struct GaussianSplatUniforms: Sendable {
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var forward: SIMD4<Float>
    var eye: SIMD4<Float>
    var viewport: SIMD4<Float>

    init(scene: GaussianSplatScene, camera: GaussianSplatCamera, size: CGSize) {
        let width = max(Float(size.width), 1), height = max(Float(size.height), 1)
        let direction = SIMD3(sin(camera.yaw) * cos(camera.pitch), cos(camera.yaw) * cos(camera.pitch), sin(camera.pitch))
        let distance = scene.extent * 1.15 / sin(camera.fieldOfView * 0.5) * max(1, height / width) / camera.zoom
        let f = -direction
        let r = simd_normalize(simd_cross(f, SIMD3(0, 0, 1)))
        let u = simd_cross(r, f)
        right = SIMD4(r, 0)
        up = SIMD4(u, 0)
        forward = SIMD4(f, 0)
        eye = SIMD4(scene.center + direction * distance, 0)
        viewport = SIMD4(width, height, height * 0.5 / tan(camera.fieldOfView * 0.5), 0)
    }

    func sortedIndices(in scene: GaussianSplatScene) -> [UInt32] {
        let depths = scene.splats.map { simd_dot($0.position - eye, forward) }
        var indices = scene.splats.indices.map(vDSP_Length.init)
        vDSP_vsorti(depths, &indices, nil, vDSP_Length(indices.count), -1)
        return indices.map(UInt32.init)
    }
}

@MainActor
final class GaussianSplatRenderer: NSObject, MTKViewDelegate {
    enum RenderError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The 3D preview couldn’t initialize Metal on this Mac. You can still save the PLY." }
    }

    let device: MTLDevice
    let scene: GaussianSplatScene
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let splatBuffer: MTLBuffer
    private var indices: MTLBuffer?
    private var uniforms: GaussianSplatUniforms?
    private var pending: GaussianSplatUniforms?
    private var sortTask: Task<Void, Never>?
    weak var view: MTKView?
    var camera: GaussianSplatCamera { didSet { requestFrame() } }

    init(scene: GaussianSplatScene, camera: GaussianSplatCamera) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let buffer = scene.splats.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { throw RenderError.unavailable }
        self.device = device
        self.queue = queue
        self.scene = scene
        self.camera = camera
        self.splatBuffer = buffer
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "splatVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "splatFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestFrame(size: size)
    }

    func requestFrame(size: CGSize? = nil) {
        guard let size = size ?? view?.drawableSize, size.width > 0, size.height > 0 else { return }
        pending = GaussianSplatUniforms(scene: scene, camera: camera, size: size)
        guard sortTask == nil else { return }
        sortNextFrame()
    }

    private func sortNextFrame() {
        guard let next = pending else { sortTask = nil; return }
        pending = nil
        let scene = scene
        // Coalesce drag events while sorting, keeping both sorting and file decoding off the UI thread.
        sortTask = Task { [weak self] in
            let order = await Task.detached(priority: .userInitiated) { next.sortedIndices(in: scene) }.value
            guard let self else { return }
            indices = order.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            uniforms = next
            view?.setNeedsDisplay(view?.bounds ?? .zero)
            sortNextFrame()
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let uniforms, let indices,
              let command = queue.makeCommandBuffer() else { return }
        encode(command: command, target: drawable.texture, uniforms: uniforms, indices: indices)
        command.present(drawable)
        command.commit()
    }

    /// Shared by the interactive view and offscreen rendering checks.
    func encode(command: MTLCommandBuffer, target: MTLTexture, uniforms: GaussianSplatUniforms, indices: MTLBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.035, green: 0.043, blue: 0.051, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(splatBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(indices, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GaussianSplatUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: scene.splats.count)
        encoder.endEncoding()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Splat { float4 position, covarianceA, covarianceB, color; };
    struct Camera { float4 right, up, forward, eye, viewport; };
    struct Vertex {
        float4 position [[position]];
        float2 delta;
        float3 conic [[flat]];
        float4 color [[flat]];
    };
    vertex Vertex splatVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                             device const Splat* splats [[buffer(0)]],
                             device const uint* order [[buffer(1)]], constant Camera& c [[buffer(2)]]) {
        Splat s = splats[order[instanceID]];
        float3 p = s.position.xyz - c.eye.xyz;
        float z = dot(p, c.forward.xyz);
        Vertex out;
        out.position = float4(2, 2, 0, 1);
        out.delta = 0; out.conic = 0; out.color = 0;
        if (z <= 0.01) return out;
        float2 xy = float2(dot(p, c.right.xyz), dot(p, c.up.xyz));
        float f = c.viewport.z;
        float3 jx = (c.right.xyz - c.forward.xyz * xy.x / z) * f / z;
        float3 jy = (c.up.xyz - c.forward.xyz * xy.y / z) * f / z;
        float4 a = s.covarianceA;
        float2 b = s.covarianceB.xy;
        float3x3 cov = float3x3(float3(a.x, a.y, a.z), float3(a.y, a.w, b.x), float3(a.z, b.x, b.y));
        float xx = dot(jx, cov * jx) + 0.3;
        float yy = dot(jy, cov * jy) + 0.3;
        float xyc = dot(jx, cov * jy);
        float determinant = xx * yy - xyc * xyc;
        if (determinant <= 0 || !isfinite(determinant)) return out;
        const float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                                   float2(-1,1), float2(1,-1), float2(1,1)};
        float2 delta = corners[vertexID] * 3 * sqrt(float2(xx, yy));
        float2 screen = xy * f / z + delta;
        out.position = float4(screen * 2 / c.viewport.xy, 0, 1);
        out.delta = delta;
        out.conic = float3(yy, -xyc, xx) / determinant;
        out.color = s.color;
        return out;
    }
    fragment float4 splatFragment(Vertex in [[stage_in]]) {
        float2 d = in.delta;
        float power = in.conic.x*d.x*d.x + 2*in.conic.y*d.x*d.y + in.conic.z*d.y*d.y;
        if (power > 9) discard_fragment();
        float alpha = min(0.99f, in.color.a * exp(-0.5f * power));
        if (alpha < 1.0f / 255) discard_fragment();
        return float4(in.color.rgb, alpha);
    }
    """
}
