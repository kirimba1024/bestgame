import Metal
import MetalKit
import simd

/// Процедурный террейн “игрового типа”: читаемые формы (плато/склоны/пики), стабильная сетка, один меш.
final class TerrainRenderer {
    struct Config {
        var halfSizeXZ: Float = 260
        var resolution: Int = 257 // vertices per side (must be >= 2)
        var heightScale: Float = 38
        // Push terrain below the demo ground plane (Y=0) so the “test площадка” remains above it.
        var baseHeight: Float = -6.0
    }

    private let device: MTLDevice
    private let config: Config
    private let sampler: TerrainSampler
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?

    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int

    let worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)

    private struct TerrainVertex {
        var p: SIMD3<Float>
        var n: SIMD3<Float>
    }

    private struct TerrainUniforms {
        var viewProj: simd_float4x4
        var lightViewProj: simd_float4x4
        var cameraPosWS: SIMD3<Float>
        var time: Float
    }

    init(device: MTLDevice, config: Config = .init(), sampler: TerrainSampler? = nil) {
        self.device = device
        self.config = config
        self.sampler = sampler ?? ProceduralTerrainSampler(config: config)

        let n = max(2, config.resolution)
        let half = config.halfSizeXZ
        let step = (2 * half) / Float(n - 1)

        var verts: [TerrainVertex] = []
        verts.reserveCapacity(n * n)

        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for j in 0..<n {
            for i in 0..<n {
                let x = -half + Float(i) * step
                let z = -half + Float(j) * step
                let y = self.sampler.height(x: x, z: z)
                let normal = self.sampler.normal(x: x, z: z, step: step)
                let p = SIMD3<Float>(x, y, z)
                verts.append(.init(p: p, n: normal))
                bmin = simd_min(bmin, p)
                bmax = simd_max(bmax, p)
            }
        }

        var idx: [UInt32] = []
        idx.reserveCapacity((n - 1) * (n - 1) * 6)
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = UInt32(j * n + i)
                let b = UInt32(j * n + i + 1)
                let c = UInt32((j + 1) * n + i)
                let d = UInt32((j + 1) * n + i + 1)
                // Two triangles (a,b,c) (b,d,c)
                idx.append(a); idx.append(b); idx.append(c)
                idx.append(b); idx.append(d); idx.append(c)
            }
        }

        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<TerrainVertex>.stride, options: [.storageModeShared])!
        indexBuffer = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride, options: [.storageModeShared])!
        indexCount = idx.count
        worldBounds = (min: bmin, max: bmax)
    }

    func buildIfNeeded(library: MTLLibrary, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        if pipeline != nil { return }
        guard let vs = library.makeFunction(name: "terrain_vs"),
              let fs = library.makeFunction(name: "terrain_fs")
        else {
            fatalError("Terrain shaders missing from Metal library.")
        }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<TerrainVertex>.stride
        vd.layouts[0].stepFunction = .perVertex

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "Terrain"
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = colorPixelFormat
        pd.depthAttachmentPixelFormat = depthPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: ds)
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        cameraPosWS: SIMD3<Float>,
        lightViewProj: simd_float4x4,
        keyLight: SceneLighting.KeyLightFrame,
        shadowTexture: MTLTexture?,
        shadowSampler: MTLSamplerState?,
        time: Float
    ) {
        guard let pipeline, let depthState else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        // Be robust to winding/frontFacing differences: terrain should never “tear” due to culling.
        encoder.setCullMode(.none)

        var u = TerrainUniforms(
            viewProj: viewProj,
            lightViewProj: lightViewProj,
            cameraPosWS: cameraPosWS,
            time: time
        )
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<TerrainUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<TerrainUniforms>.stride, index: 0)
        var key = SceneLighting.KeyLightGPUBytes(keyLight)
        encoder.setFragmentBytes(&key, length: MemoryLayout<SceneLighting.KeyLightGPUBytes>.stride, index: 4)
        if let st = shadowTexture { encoder.setFragmentTexture(st, index: 0) }
        if let ss = shadowSampler { encoder.setFragmentSamplerState(ss, index: 0) }

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    // MARK: - Sampling (for forest placement)

    static func height(x: Float, z: Float, cfg: Config) -> Float {
        ProceduralTerrainGenerator.height(x: x, z: z, cfg: cfg)
    }

    static func normal(x: Float, z: Float, cfg: Config, step: Float) -> SIMD3<Float> {
        ProceduralTerrainGenerator.normal(x: x, z: z, cfg: cfg, step: step)
    }

    // MARK: - Sampler implementation (procedural fallback)

    private final class ProceduralTerrainSampler: TerrainSampler {
        let config: TerrainRenderer.Config
        init(config: TerrainRenderer.Config) { self.config = config }
        func height(x: Float, z: Float) -> Float { TerrainRenderer.height(x: x, z: z, cfg: config) }
        func normal(x: Float, z: Float, step: Float) -> SIMD3<Float> { TerrainRenderer.normal(x: x, z: z, cfg: config, step: step) }
    }

    // Noise moved to ProceduralTerrainGenerator.
}

