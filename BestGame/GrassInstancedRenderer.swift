import Metal
import MetalKit
import simd

/// Плотная трава одним инстансированным draw: процедурный квад-лезвие, ветер в VS, без отдельного GLB.
final class GrassInstancedRenderer {
    private static let maxInstances = 62_000
    /// Увеличь при смене сетки/плотности — пересоздаст инстансы за один кадр.
    private static let grassLayoutVersion: UInt32 = 3

    private let device: MTLDevice
    private var renderPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?

    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let instanceBuffer: MTLBuffer
    private let uniformBuffer: MTLBuffer

    private var instanceCount: Int = 0
    private var filledGrassLayoutVersion: UInt32 = 0

    private struct GrassVertex {
        /// x — −0.5…0.5 по ширине лезвия, y — 0…1 по высоте, z = 0.
        var p: SIMD3<Float>
    }

    private struct GrassUniforms {
        var viewProj: simd_float4x4
        var cam_time: SIMD4<Float>
        var sun_wind: SIMD4<Float>
        var blade: SIMD4<Float>
    }

    init(device: MTLDevice) {
        self.device = device
        let verts: [GrassVertex] = [
            .init(p: SIMD3(-0.5, 0, 0)),
            .init(p: SIMD3(0.5, 0, 0)),
            .init(p: SIMD3(0.5, 1, 0)),
            .init(p: SIMD3(-0.5, 1, 0)),
        ]
        let idx: [UInt32] = [0, 1, 2, 2, 3, 0]
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<GrassVertex>.stride, options: .storageModeShared)!
        indexBuffer = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)!
        instanceBuffer = device.makeBuffer(length: Self.maxInstances * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
        uniformBuffer = device.makeBuffer(length: MemoryLayout<GrassUniforms>.stride, options: .storageModeShared)!
    }

    func buildPipelineIfNeeded(
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) {
        if renderPipeline != nil { return }
        guard let vs = library.makeFunction(name: "grass_instanced_vs"),
              let fs = library.makeFunction(name: "grass_instanced_fs")
        else {
            fatalError("Grass shaders missing from Metal library.")
        }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<GrassVertex>.stride
        vd.layouts[0].stepFunction = .perVertex

        vd.attributes[1].format = .float4
        vd.attributes[1].offset = 0
        vd.attributes[1].bufferIndex = 1
        vd.layouts[1].stride = MemoryLayout<SIMD4<Float>>.stride
        vd.layouts[1].stepFunction = .perInstance

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "GrassInstanced"
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

        renderPipeline = try! device.makeRenderPipelineState(descriptor: pd)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = false
        depthState = device.makeDepthStencilState(descriptor: ds)
    }

    /// Заполняет инстансы один раз: сетка по полу демо-сцены с джиттером.
    func ensureInstances(
        shelf: DemoScenePlacements.ShelfFrame,
        config: DemoScenePlacements.Config
    ) {
        if filledGrassLayoutVersion == Self.grassLayoutVersion, instanceCount > 0 { return }
        filledGrassLayoutVersion = Self.grassLayoutVersion

        let cx = (shelf.slotSpanMinX + shelf.slotSpanMaxX) * 0.5
        let halfW = max(18, (shelf.slotSpanMaxX - shelf.slotSpanMinX) * 0.5 + config.groundMarginX)
        let dz = config.groundHalfDepthZ
        let z0 = config.sceneDepthZ

        let nx = 251
        let nz = 247
        var count = 0
        let ptr = instanceBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)

        outer: for j in 0..<nz {
            for i in 0..<nx {
                if count >= Self.maxInstances { break outer }
                let fi = Float(i), fj = Float(j)
                let h1 = GrassInstancedRenderer.stableHash2D(fi, fj, seed: 1)
                let h2 = GrassInstancedRenderer.stableHash2D(fi, fj, seed: 3)
                let u = (fi + h1) / Float(nx)
                let v = (fj + h2) / Float(nz)
                let lx = u - 0.5
                let lz = v - 0.5
                let wx = cx + lx * (2 * halfW)
                let wz = z0 + lz * (2 * dz)
                if RiverWaterRenderer.RiverStrip.suppressGrass(worldX: wx, worldZ: wz, shelf: shelf, config: config) {
                    continue
                }
                let wy = 0.035 + GrassInstancedRenderer.stableHash2D(fi, fj, seed: 7) * 0.018
                let h3 = GrassInstancedRenderer.stableHash2D(fi, fj, seed: 11)
                let seedMix = h1 * 0.618 + h2 * 0.379 + h3
                let seed = seedMix - floor(seedMix)
                ptr[count] = SIMD4(wx, wy, wz, seed)
                count += 1
            }
        }
        instanceCount = count
    }

    private static func stableHash2D(_ i: Float, _ j: Float, seed: Float) -> Float {
        let x = sin(i * 12.9898 + j * 78.233 + seed * 45.164) * 43758.5453
        return x - floor(x)
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        cameraPos: SIMD3<Float>,
        time: Float,
        sunDirectionWS: SIMD3<Float>
    ) {
        guard let renderPipeline, let depthState, instanceCount > 0 else { return }

        let sun = normalize(sunDirectionWS)
        let wind = 0.42 + 0.08 * sin(time * 0.7)
        var u = GrassUniforms(
            viewProj: viewProj,
            cam_time: SIMD4(cameraPos.x, cameraPos.y, cameraPos.z, time),
            sun_wind: SIMD4(sun.x, sun.y, sun.z, wind),
            blade: SIMD4(0.044, 1.02, 0.14, 0)
        )
        uniformBuffer.contents().assumingMemoryBound(to: GrassUniforms.self).pointee = u

        encoder.setRenderPipelineState(renderPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: 6,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0,
            instanceCount: instanceCount
        )
        encoder.setCullMode(.back)
    }
}
