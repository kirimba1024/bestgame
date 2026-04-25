import Metal
import MetalKit
import simd

/// Вода в низинах: генерим меш один раз по высотам террейна (плоский уровень воды).
final class DepressionWaterRenderer {
    struct Config {
        // Low and subtle by default (so it doesn't look like a giant translucent screen).
        var waterLevelY: Float = -0.95
        /// Насколько глубже уровня воды должна быть “низина”, чтобы рисовать воду.
        var minDepth: Float = 0.25
    }

    private let device: MTLDevice
    private let cfg: Config

    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?

    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let uniformBuffer: MTLBuffer
    private let indexCount: Int

    private struct WaterVertex {
        var position: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    // Must match WaterUniforms in WaterRiver.metal
    private struct WaterUniforms {
        var viewProj: simd_float4x4
        var invViewProj: simd_float4x4
        var model: simd_float4x4
        var normalMatrix: simd_float4x4
        var camAndTime: SIMD4<Float>
        var sunAndFlow: SIMD4<Float>
        var foamStrength: Float
        var _pad0: SIMD3<Float> = .zero
        var nearFarInvWInvH: SIMD4<Float>
    }

    init(device: MTLDevice, terrain: TerrainSampler, config: Config = .init()) {
        self.device = device
        self.cfg = config

        // Rebuild the same grid layout as terrain (deterministic).
        let n = max(2, terrain.config.resolution)
        let half = terrain.config.halfSizeXZ
        let step = (2 * half) / Float(n - 1)

        var verts: [WaterVertex] = []
        verts.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                let x = -half + Float(i) * step
                let z = -half + Float(j) * step
                let y = cfg.waterLevelY
                let uv = SIMD2<Float>((x / (2 * half)) + 0.5, (z / (2 * half)) + 0.5)
                verts.append(.init(position: SIMD3(x, y, z), uv: uv))
            }
        }

        var idx: [UInt32] = []
        idx.reserveCapacity((n - 1) * (n - 1) * 6)
        let stride = n
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                // Decide if this cell is “underwater enough”.
                let x0 = -half + Float(i) * step
                let z0 = -half + Float(j) * step
                let x1 = x0 + step
                let z1 = z0 + step

                let h00 = terrain.height(x: x0, z: z0)
                let h10 = terrain.height(x: x1, z: z0)
                let h01 = terrain.height(x: x0, z: z1)
                let h11 = terrain.height(x: x1, z: z1)

                let maxH = max(max(h00, h10), max(h01, h11))
                let depth = cfg.waterLevelY - maxH
                if depth < cfg.minDepth { continue }

                let a = UInt32(j * stride + i)
                let b = UInt32(j * stride + i + 1)
                let c = UInt32((j + 1) * stride + i)
                let d = UInt32((j + 1) * stride + i + 1)
                idx.append(a); idx.append(b); idx.append(c)
                idx.append(b); idx.append(d); idx.append(c)
            }
        }

        indexCount = idx.count
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<WaterVertex>.stride, options: .storageModeShared)!
        if idx.isEmpty {
            // Metal debug device aborts on zero-length buffers.
            indexBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared)!
        } else {
            indexBuffer = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)!
        }
        uniformBuffer = device.makeBuffer(length: MemoryLayout<WaterUniforms>.stride, options: .storageModeShared)!
    }

    func buildPipelineIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) {
        if pipeline != nil { return }
        guard let vs = library.makeFunction(name: "water_river_vs"),
              let fs = library.makeFunction(name: "water_river_fs")
        else { fatalError("WaterRiver shaders missing.") }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<WaterVertex>.offset(of: \.uv) ?? 16
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<WaterVertex>.stride
        vd.layouts[0].stepFunction = .perVertex

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "DepressionWater"
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = colorPixelFormat
        pd.depthAttachmentPixelFormat = depthPixelFormat
        let ca = pd.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.alphaBlendOperation = .add
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = false
        depthState = device.makeDepthStencilState(descriptor: ds)
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        cameraPos: SIMD3<Float>,
        time: Float,
        sunDirectionWS: SIMD3<Float>,
        viewportWidth: Float,
        viewportHeight: Float,
        depthTexture: MTLTexture,
        environmentTexture: MTLTexture,
        environmentSampler: MTLSamplerState,
        keyLightBytes: SceneLighting.KeyLightGPUBytes
    ) {
        guard let pipeline, let depthState, indexCount > 0 else { return }

        let model = matrix_identity_float4x4
        let normalMatrix = model.inverse.transpose
        let sun = length(sunDirectionWS) > 1e-5 ? normalize(sunDirectionWS) : SIMD3<Float>(0.38, 0.92, 0.28)
        let invViewProj = viewProj.inverse
        var u = WaterUniforms(
            viewProj: viewProj,
            invViewProj: invViewProj,
            model: model,
            normalMatrix: normalMatrix,
            camAndTime: SIMD4(cameraPos.x, cameraPos.y, cameraPos.z, time),
            sunAndFlow: SIMD4(sun.x, sun.y, sun.z, time * 0.12),
            foamStrength: 0.35,
            nearFarInvWInvH: SIMD4(
                RendererFrameTiming.depthNear,
                RendererFrameTiming.depthFar,
                1 / max(1, viewportWidth),
                1 / max(1, viewportHeight)
            )
        )
        uniformBuffer.contents().assumingMemoryBound(to: WaterUniforms.self).pointee = u

        var key = keyLightBytes
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&key, length: MemoryLayout<SceneLighting.KeyLightGPUBytes>.stride, index: 1)
        encoder.setFragmentTexture(depthTexture, index: 0)
        encoder.setFragmentTexture(environmentTexture, index: 1)
        encoder.setFragmentSamplerState(environmentSampler, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
        encoder.setCullMode(.back)
    }
}

