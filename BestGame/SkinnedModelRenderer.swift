import Metal
import MetalKit
import simd

/// Скинированный glTF + PBR; shadow pass использует те же joint matrices.
final class SkinnedModelRenderer {
    // MARK: - DrawParams

    struct DrawParams {
        var proj: simd_float4x4
        var view: simd_float4x4
        var cameraPosWS: SIMD3<Float>
        var time: Float
        var modelTranslation: SIMD3<Float> = .zero
        var modelScale: Float = 0.02
        var lightViewProj: simd_float4x4
        var keyLight: SceneLighting.KeyLightFrame
        var shadowTexture: MTLTexture?
        var shadowSampler: MTLSamplerState?
        var debugMode: UInt32 = 0
    }

    // MARK: - State

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let shadowPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let environment: EnvironmentMap
    let localBounds: (min: SIMD3<Float>, max: SIMD3<Float>)

    var model: GLBSkinnedModel
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    let jointBuffer: MTLBuffer
    let jointCount: Int
    var jointMatsScratch: [simd_float4x4] = []

    let baseColorTex: MTLTexture?
    let metallicRoughnessTex: MTLTexture?
    let baseColorFactor: SIMD4<Float>
    let metallicFactor: Float
    let roughnessFactor: Float

    // MARK: - Life cycle

    init(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        model: GLBSkinnedModel,
        environment: EnvironmentMap
    ) {
        self.device = device
        self.model = model
        self.environment = environment

        guard let vs = library.makeFunction(name: "vertex_skinned"),
              let fs = library.makeFunction(name: "fragment_pbr_mr")
        else { fatalError("Missing skinned/PBR shaders.") }

        // Main color pass
        let vd = SkinnedModelRenderer.makeVertexDescriptor()
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = colorPixelFormat
        pd.depthAttachmentPixelFormat = depthPixelFormat

        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            fatalError("Failed to create skinned pipeline: \(error)")
        }

        // Shadow map pass (depth only)
        do {
            let spd = MTLRenderPipelineDescriptor()
            spd.vertexFunction = library.makeFunction(name: "vertex_shadow_skinned")
            spd.fragmentFunction = nil
            spd.vertexDescriptor = vd
            spd.depthAttachmentPixelFormat = .depth32Float
            self.shadowPipeline = try device.makeRenderPipelineState(descriptor: spd)
        } catch {
            fatalError("Failed to create skinned shadow pipeline: \(error)")
        }

        // Material sampling
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .repeat
        sd.tAddressMode = .repeat
        sd.maxAnisotropy = 4
        guard let s = device.makeSamplerState(descriptor: sd) else {
            fatalError("Failed to create sampler.")
        }
        self.sampler = s

        // GPU vertex/index buffers + bounds
        struct GPUVertex {
            var position: SIMD4<Float>
            var normal: SIMD4<Float>
            var uv: SIMD4<Float>
            var joints: SIMD4<UInt16>
            var weights: SIMD4<Float>
        }
        let verts: [GPUVertex] = model.vertices.map { v in
            GPUVertex(
                position: SIMD4<Float>(v.position.x, v.position.y, v.position.z, 1),
                normal: SIMD4<Float>(v.normal.x, v.normal.y, v.normal.z, 0),
                uv: SIMD4<Float>(v.uv.x, v.uv.y, 0, 0),
                joints: v.joints,
                weights: v.weights
            )
        }
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in model.vertices {
            bmin = simd_min(bmin, v.position)
            bmax = simd_max(bmax, v.position)
        }
        self.localBounds = (min: bmin, max: bmax)

        self.indexCount = model.indices.count
        self.jointCount = model.jointNodes.count

        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<GPUVertex>.stride, options: [.storageModeShared]),
              let ib = device.makeBuffer(bytes: model.indices, length: model.indices.count * MemoryLayout<UInt32>.stride, options: [.storageModeShared])
        else { fatalError("Failed to create mesh buffers.") }
        self.vertexBuffer = vb
        self.indexBuffer = ib

        let jointMats = Array(repeating: matrix_identity_float4x4, count: jointCount)
        guard let jb = device.makeBuffer(bytes: jointMats, length: jointMats.count * MemoryLayout<simd_float4x4>.stride, options: [.storageModeShared]) else {
            fatalError("Failed to create joint buffer.")
        }
        self.jointBuffer = jb

        // Material + textures
        let mat = model.material
        baseColorFactor = mat.baseColorFactor
        metallicFactor = mat.metallicFactor
        roughnessFactor = mat.roughnessFactor

        let loader = MTKTextureLoader(device: device)
        if let d = mat.baseColorImageData {
            baseColorTex = try? loader.newTexture(data: d, options: [MTKTextureLoader.Option.SRGB: true])
        } else {
            baseColorTex = nil
        }
        if let d = mat.metallicRoughnessImageData {
            metallicRoughnessTex = try? loader.newTexture(data: d, options: [MTKTextureLoader.Option.SRGB: false])
        } else {
            metallicRoughnessTex = nil
        }
    }
}
