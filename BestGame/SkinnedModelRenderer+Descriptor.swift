import Metal
import simd

extension SkinnedModelRenderer {
    // MARK: - Vertex descriptor

    static func makeVertexDescriptor() -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        struct GPUVertex {
            var position: SIMD4<Float>
            var normal: SIMD4<Float>
            var uv: SIMD4<Float>
            var joints: SIMD4<UInt16>
            var weights: SIMD4<Float>
        }

        vd.attributes[0].format = .float3
        vd.attributes[0].offset = MemoryLayout<GPUVertex>.offset(of: \.position) ?? 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<GPUVertex>.offset(of: \.normal) ?? 0
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2
        vd.attributes[2].offset = MemoryLayout<GPUVertex>.offset(of: \.uv) ?? 0
        vd.attributes[2].bufferIndex = 0
        vd.attributes[3].format = .ushort4
        vd.attributes[3].offset = MemoryLayout<GPUVertex>.offset(of: \.joints) ?? 0
        vd.attributes[3].bufferIndex = 0
        vd.attributes[4].format = .float4
        vd.attributes[4].offset = MemoryLayout<GPUVertex>.offset(of: \.weights) ?? 0
        vd.attributes[4].bufferIndex = 0

        vd.layouts[0].stride = MemoryLayout<GPUVertex>.stride
        return vd
    }
}
