import Metal
import simd

final class DebugDraw {
    private struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    private let axisVertexBuffer: MTLBuffer
    private let axisVertexCount: Int

    init(device: MTLDevice) {
        let L: Float = 0.22
        let axisVertices: [Vertex] = [
            .init(position: .zero, color: [1, 0.2, 0.2]),
            .init(position: SIMD3<Float>(L, 0, 0), color: [1, 0.2, 0.2]),
            .init(position: .zero, color: [0.25, 1, 0.25]),
            .init(position: SIMD3<Float>(0, L, 0), color: [0.25, 1, 0.25]),
            .init(position: .zero, color: [0.3, 0.45, 1]),
            .init(position: SIMD3<Float>(0, 0, L), color: [0.3, 0.45, 1]),
        ]
        axisVertexCount = axisVertices.count
        let length = axisVertices.count * MemoryLayout<Vertex>.stride
        guard let buf = device.makeBuffer(bytes: axisVertices, length: length, options: [.storageModeShared]) else {
            fatalError("Failed to create axis vertex buffer.")
        }
        self.axisVertexBuffer = buf
    }

    func drawAxes(encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, viewProj: simd_float4x4) {
        struct Uniforms { var mvp: simd_float4x4 }
        encoder.setRenderPipelineState(pipeline)
        var u = Uniforms(mvp: viewProj)
        encoder.setVertexBuffer(axisVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: axisVertexCount)
    }

    func drawWorldAxesOverlay(encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, modelViewProj: simd_float4x4) {
        struct Uniforms { var mvp: simd_float4x4 }
        encoder.setRenderPipelineState(pipeline)
        var u = Uniforms(mvp: modelViewProj)
        encoder.setVertexBuffer(axisVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: axisVertexCount)
    }
}
