import Metal
import MetalKit
import simd

/// Узкая «река» по полу: одна сетка, волны в VS, IBL + пена по depth — без дорогого захвата цвета кадра.
final class RiverWaterRenderer {

    /// Общая геометрия полосы (мир), чтобы трава не застилала воду.
    enum RiverStrip {
        static let surfaceY: Float = 0.056
        static let halfWidthX: Float = 5.6
        static let lengthZScale: Float = 1.75

        static func centerXZ(shelf: DemoScenePlacements.ShelfFrame, config: DemoScenePlacements.Config) -> SIMD2<Float> {
            let cx = (shelf.slotSpanMinX + shelf.slotSpanMaxX) * 0.5
            let halfW = max(18, (shelf.slotSpanMaxX - shelf.slotSpanMinX) * 0.5 + config.groundMarginX)
            let posX = cx - halfW * 0.72
            return SIMD2(posX, config.sceneDepthZ)
        }

        static func halfLengthZ(config: DemoScenePlacements.Config) -> Float {
            config.groundHalfDepthZ * lengthZScale
        }

        static func modelMatrix(shelf: DemoScenePlacements.ShelfFrame, config: DemoScenePlacements.Config) -> simd_float4x4 {
            let c = centerXZ(shelf: shelf, config: config)
            let hz = halfLengthZ(config: config)
            let sx = halfWidthX * 2
            let sz = hz * 2
            return simd_float4x4.translation(SIMD3(c.x, surfaceY, c.y))
                * simd_float4x4.scale(SIMD3(sx, 1, sz))
        }

        /// Точка на полу (XZ) попадает в полосу реки — не ставим траву.
        static func suppressGrass(worldX: Float, worldZ: Float, shelf: DemoScenePlacements.ShelfFrame, config: DemoScenePlacements.Config) -> Bool {
            let c = centerXZ(shelf: shelf, config: config)
            let hz = halfLengthZ(config: config)
            let margin: Float = 1.08
            return abs(worldX - c.x) < halfWidthX * margin && abs(worldZ - c.y) < hz * margin
        }
    }

    private struct WaterVertex {
        var position: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    private struct WaterUniforms {
        var viewProj: simd_float4x4
        var model: simd_float4x4
        var normalMatrix: simd_float4x4
        var camAndTime: SIMD4<Float>
        var sunAndFlow: SIMD4<Float>
        var nearFarInvWInvH: SIMD4<Float>
    }

    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let uniformBuffer: MTLBuffer
    private let indexCount: Int

    init(device: MTLDevice) {
        let nx = 52
        let nz = 40
        var verts: [WaterVertex] = []
        verts.reserveCapacity((nx + 1) * (nz + 1))
        for j in 0...nz {
            for i in 0...nx {
                let u = Float(i) / Float(nx)
                let v = Float(j) / Float(nz)
                verts.append(WaterVertex(position: SIMD3(u - 0.5, 0, v - 0.5), uv: SIMD2(u, v)))
            }
        }
        var idx: [UInt32] = []
        idx.reserveCapacity(nx * nz * 6)
        let stride = nx + 1
        for j in 0..<nz {
            for i in 0..<nx {
                let i0 = UInt32(j * stride + i)
                let i1 = i0 + 1
                let i2 = i0 + UInt32(stride + 1)
                let i3 = i0 + UInt32(stride)
                idx.append(contentsOf: [i0, i1, i2, i0, i2, i3])
            }
        }
        indexCount = idx.count
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<WaterVertex>.stride, options: .storageModeShared)!
        indexBuffer = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)!
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
        pd.label = "RiverWater"
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
        shelf: DemoScenePlacements.ShelfFrame,
        config: DemoScenePlacements.Config,
        depthTexture: MTLTexture,
        environmentTexture: MTLTexture,
        environmentSampler: MTLSamplerState,
        keyLightBytes: SceneLighting.KeyLightGPUBytes
    ) {
        guard let pipeline, let depthState else { return }

        let model = RiverStrip.modelMatrix(shelf: shelf, config: config)
        let normalMatrix = model.inverse.transpose
        let sun = length(sunDirectionWS) > 1e-5 ? normalize(sunDirectionWS) : SIMD3<Float>(0.38, 0.92, 0.28)
        var u = WaterUniforms(
            viewProj: viewProj,
            model: model,
            normalMatrix: normalMatrix,
            camAndTime: SIMD4(cameraPos.x, cameraPos.y, cameraPos.z, time),
            sunAndFlow: SIMD4(sun.x, sun.y, sun.z, time * 0.15),
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
    }
}
