import Metal
import simd

final class DebugDraw {
    private struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    private let axisVertices: [Vertex] = [
        .init(position: [0, 0, 0], color: [1, 0, 0]), .init(position: [2, 0, 0], color: [1, 0, 0]), // X
        .init(position: [0, 0, 0], color: [0, 1, 0]), .init(position: [0, 2, 0], color: [0, 1, 0]), // Y
        .init(position: [0, 0, 0], color: [0, 0, 1]), .init(position: [0, 0, 2], color: [0, 0, 1]), // Z
    ]

    private let axisVertexBuffer: MTLBuffer

    init(device: MTLDevice) {
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
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: axisVertices.count)
    }

    /// Мировые оси X/Y/Z из якоря у камеры (масштаб в мире), уже умноженные на `proj * view`.
    func drawWorldAxesOverlay(encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, modelViewProj: simd_float4x4) {
        struct Uniforms { var mvp: simd_float4x4 }
        encoder.setRenderPipelineState(pipeline)
        var u = Uniforms(mvp: modelViewProj)
        encoder.setVertexBuffer(axisVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: axisVertices.count)
    }
}

