import Metal
import simd

final class SkyRenderer {
    struct Uniforms {
        var invViewProj: simd_float4x4
        var cameraPosWS: SIMD3<Float>
        var _pad0: Float = 0
        var sunDirWS: SIMD3<Float>
        var _pad1: Float = 0
        var sunDiskRadianceHDR: SIMD3<Float>
        var _pad2: Float = 0
    }

    private let pipeline: MTLRenderPipelineState

    init(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        guard let vs = library.makeFunction(name: "vertex_fullscreen"),
              let fs = library.makeFunction(name: "fragment_sky")
        else { fatalError("Missing sky shaders.") }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.colorAttachments[0].pixelFormat = colorPixelFormat
        // Render pass includes depth; keep formats consistent to satisfy validation.
        pd.depthAttachmentPixelFormat = depthPixelFormat
        pd.stencilAttachmentPixelFormat = .invalid

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            fatalError("Failed to create sky pipeline: \(error)")
        }
    }

    func draw(encoder: MTLRenderCommandEncoder, uniforms: Uniforms) {
        encoder.setRenderPipelineState(pipeline)
        var u = uniforms
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
