import Metal
import MetalKit
import simd

final class SkinnedModelRenderer {
    struct DrawParams {
        var proj: simd_float4x4
        var view: simd_float4x4
        var cameraPosWS: SIMD3<Float>
        var time: Float
        /// Дополнительное смещение в мире (до поворота/масштаба), например для расстановки на сцене.
        var modelTranslation: SIMD3<Float> = .zero
        var modelScale: Float = 0.02
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var model: GLBSkinnedModel
    private var vertexBuffer: MTLBuffer
    private var indexBuffer: MTLBuffer
    private var indexCount: Int

    private var jointBuffer: MTLBuffer
    private var jointCount: Int

    private var baseColorTex: MTLTexture?
    private var metallicRoughnessTex: MTLTexture?
    private var baseColorFactor: SIMD4<Float>
    private var metallicFactor: Float
    private var roughnessFactor: Float

    init(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat, model: GLBSkinnedModel) {
        self.device = device
        self.model = model

        // Pipeline
        guard let vs = library.makeFunction(name: "vertex_skinned"),
              let fs = library.makeFunction(name: "fragment_pbr_mr")
        else { fatalError("Missing skinned/PBR shaders.") }

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

        // Sampler
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

        // Buffers
        // NOTE: Swift pads `SIMD3<Float>` to 16 bytes, which easily breaks manual stride math.
        // Use `SIMD4<Float>` for predictable 16-byte slots and describe the first 3/2 components.
        struct GPUVertex {
            var position: SIMD4<Float> // xyz used
            var normal: SIMD4<Float>   // xyz used
            var uv: SIMD4<Float>       // xy used
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

        baseColorFactor = model.material.baseColorFactor
        metallicFactor = model.material.metallicFactor
        roughnessFactor = model.material.roughnessFactor

        let loader = MTKTextureLoader(device: device)
        if let d = model.material.baseColorImageData {
            baseColorTex = try? loader.newTexture(data: d, options: [MTKTextureLoader.Option.SRGB: true])
        }
        if let d = model.material.metallicRoughnessImageData {
            metallicRoughnessTex = try? loader.newTexture(data: d, options: [MTKTextureLoader.Option.SRGB: false])
        }
    }

    func draw(encoder: MTLRenderCommandEncoder, params: DrawParams) {
        updateJoints(time: params.time)

        let modelM =
            simd_float4x4.translation(params.modelTranslation)
            * simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])
            * simd_float4x4.scale([params.modelScale, params.modelScale, params.modelScale])

        let mvp = params.proj * params.view * modelM

        encoder.setRenderPipelineState(pipeline)

        var u = PBRTypes.Uniforms(
            mvp: mvp,
            model: modelM,
            cameraPosWS: params.cameraPosWS,
            jointCount: UInt32(jointCount),
            baseColorFactor: baseColorFactor,
            metallicFactor: metallicFactor,
            roughnessFactor: roughnessFactor
        )
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<PBRTypes.Uniforms>.stride, index: 1)
        encoder.setVertexBuffer(jointBuffer, offset: 0, index: 2)

        encoder.setFragmentBytes(&u, length: MemoryLayout<PBRTypes.Uniforms>.stride, index: 0)
        if let baseColorTex { encoder.setFragmentTexture(baseColorTex, index: 0) }
        if let metallicRoughnessTex { encoder.setFragmentTexture(metallicRoughnessTex, index: 1) }
        encoder.setFragmentSamplerState(sampler, index: 0)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    // MARK: - Internals

    private static func makeVertexDescriptor() -> MTLVertexDescriptor {
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

    private func updateJoints(time: Float) {
        guard jointCount > 0 else { return }

        var trs = model.nodeLocalTRS
        if let anim = model.animation, anim.duration > 0 {
            let t = fmodf(time, anim.duration)
            for (node, track) in anim.translations { trs[node].t = sampleVec3(track.times, track.values, t) }
            for (node, track) in anim.scales { trs[node].s = sampleVec3(track.times, track.values, t) }
            for (node, track) in anim.rotations { trs[node].r = sampleQuat(track.times, track.values, t) }
        }

        var global: [simd_float4x4] = Array(repeating: matrix_identity_float4x4, count: trs.count)
        var computed: [Bool] = Array(repeating: false, count: trs.count)

        func localMatrix(_ i: Int) -> simd_float4x4 {
            simd_float4x4.translation(trs[i].t) * simd_float4x4(trs[i].r) * simd_float4x4.scale(trs[i].s)
        }
        func compute(_ i: Int) -> simd_float4x4 {
            if computed[i] { return global[i] }
            let l = simd_float4x4.translation(trs[i].t) * simd_float4x4(trs[i].r) * simd_float4x4.scale(trs[i].s)
            if let p = model.parentIndex[i] { global[i] = compute(p) * l } else { global[i] = l }
            computed[i] = true
            return global[i]
        }
        for i in 0..<trs.count { _ = compute(i) }

        let meshGlobal = global[model.meshNodeIndex]
        let invMeshGlobal = meshGlobal.inverse

        var jointMats: [simd_float4x4] = []
        jointMats.reserveCapacity(jointCount)
        for j in 0..<jointCount {
            let nodeIndex = model.jointNodes[j]
            jointMats.append(invMeshGlobal * global[nodeIndex] * model.inverseBindMatrices[j])
        }

        memcpy(jointBuffer.contents(), jointMats, jointMats.count * MemoryLayout<simd_float4x4>.stride)
    }

    private func sampleVec3(_ times: [Float], _ values: [SIMD3<Float>], _ t: Float) -> SIMD3<Float> {
        guard let last = times.last, last > 0, times.count == values.count else { return values.first ?? .zero }
        if t <= times[0] { return values[0] }
        if t >= last { return values[values.count - 1] }
        var i = 0
        while i + 1 < times.count, times[i + 1] < t { i += 1 }
        let t0 = times[i], t1 = times[i + 1]
        let a = (t - t0) / max(1e-6, (t1 - t0))
        return simd_mix(values[i], values[i + 1], SIMD3<Float>(repeating: a))
    }

    private func sampleQuat(_ times: [Float], _ values: [simd_quatf], _ t: Float) -> simd_quatf {
        guard let last = times.last, last > 0, times.count == values.count else { return values.first ?? simd_quatf(angle: 0, axis: [0, 1, 0]) }
        if t <= times[0] { return values[0] }
        if t >= last { return values[values.count - 1] }
        var i = 0
        while i + 1 < times.count, times[i + 1] < t { i += 1 }
        let t0 = times[i], t1 = times[i + 1]
        let a = (t - t0) / max(1e-6, (t1 - t0))
        return simd_slerp(values[i], values[i + 1], a)
    }
}

