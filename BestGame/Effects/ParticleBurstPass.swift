import Metal
import MetalKit
import simd

private struct BurstParticle {
    var position: SIMD3<Float> = .zero
    var life: Float = 0
    var velocity: SIMD3<Float> = .zero
    var size: Float = 0.2
    var color: SIMD4<Float> = .zero
    var seed: UInt32 = 0
    var _pad: SIMD3<UInt32> = .zero
}

private struct BurstSimUniforms {
    var time: Float = 0
    var dt: Float = 0
    var particleCount: UInt32 = 0
    var _pad0: UInt32 = 0
    var emitterCenter: SIMD3<Float> = .zero
    var emitterJitter: Float = 1
    var gravity: SIMD3<Float> = SIMD3(0, -6, 0)
    var drag: Float = 1.1
    var spawnSpeed: Float = 8
    var lifeDecay: Float = 0.5
    var minParticleSize: Float = 0.07
    var maxParticleSize: Float = 0.45
}

private struct BurstDrawUniforms {
    var viewProj: simd_float4x4 = matrix_identity_float4x4
    var cameraRight: SIMD3<Float> = .zero
    var _padR: Float = 0
    var cameraUp: SIMD3<Float> = .zero
    var _padU: Float = 0
}

/// Аддитивный «фейерверк» над витриной; не знает про `Renderer`, только `FrameEffectContext`.
final class ParticleBurstPass: GPUFrameEffect {
    var compositeDrawOrder: Int { 20 }

    private static let maxParticles = 16_384

    private let particlesBuffer: MTLBuffer
    private let simUniformBuffer: MTLBuffer
    private let drawUniformBuffer: MTLBuffer

    private var computePSO: MTLComputePipelineState?
    private var renderPSO: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?

    init(device: MTLDevice) {
        var seeds: [BurstParticle] = []
        seeds.reserveCapacity(Self.maxParticles)
        for i in 0..<Self.maxParticles {
            seeds.append(BurstParticle(life: 0, seed: UInt32(i)))
        }
        let stride = MemoryLayout<BurstParticle>.stride
        particlesBuffer = device.makeBuffer(bytes: seeds, length: seeds.count * stride, options: .storageModeShared)!
        simUniformBuffer = device.makeBuffer(length: MemoryLayout<BurstSimUniforms>.stride, options: .storageModeShared)!
        drawUniformBuffer = device.makeBuffer(length: MemoryLayout<BurstDrawUniforms>.stride, options: .storageModeShared)!
    }

    func buildIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) {
        if computePSO != nil, renderPSO != nil, depthStencilState != nil { return }

        let kernel = library.makeFunction(name: "burst_update_sim")!
        computePSO = try! device.makeComputePipelineState(function: kernel)

        renderPSO = try! EffectPipelineBuilders.makeAdditiveBillboardRenderPSO(
            device: device,
            library: library,
            label: "BurstAdditive",
            vertex: "burst_billboard_vs",
            fragment: "burst_soft_additive_fs",
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )

        // Depth-test against the scene so particles don't show through opaque geometry.
        // (We no longer draw dense grass in world mode, so the old "always" compare is unnecessary.)
        depthStencilState = EffectPipelineBuilders.makeDepthState(device: device, compare: .lessEqual, writeEnabled: false)
    }

    func encodeCompute(into commandBuffer: MTLCommandBuffer, context: FrameEffectContext) {
        guard let computePSO else { return }
        let simDt = max(1e-4, context.deltaTime)
        let u = BurstSimUniforms(
            time: context.time,
            dt: simDt,
            particleCount: UInt32(Self.maxParticles),
            _pad0: 0,
            emitterCenter: context.effectsAnchorPoint,
            emitterJitter: 1.85,
            gravity: SIMD3(0, -7.2, 0),
            drag: 1.35,
            spawnSpeed: 8.5,
            lifeDecay: 0.48,
            minParticleSize: 0.075,
            maxParticleSize: 0.48
        )
        simUniformBuffer.contents().assumingMemoryBound(to: BurstSimUniforms.self).pointee = u

        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "BurstSim"
        enc.setComputePipelineState(computePSO)
        enc.setBuffer(particlesBuffer, offset: 0, index: 0)
        enc.setBuffer(simUniformBuffer, offset: 0, index: 1)
        let tg = 256
        let groups = (Self.maxParticles + tg - 1) / tg
        enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
        enc.endEncoding()
    }

    func encodeDraw(encoder: MTLRenderCommandEncoder, context: FrameEffectContext) {
        guard let renderPSO, let depthStencilState else { return }
        let du = BurstDrawUniforms(
            viewProj: context.viewProjection,
            cameraRight: context.cameraRight,
            _padR: 0,
            cameraUp: context.cameraUp,
            _padU: 0
        )
        drawUniformBuffer.contents().assumingMemoryBound(to: BurstDrawUniforms.self).pointee = du
        encoder.setRenderPipelineState(renderPSO)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBuffer(particlesBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(drawUniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Self.maxParticles)
    }
}
