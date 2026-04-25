import Metal
import MetalKit
import simd

private struct FireflyParticle {
    var position: SIMD3<Float> = .zero
    var life: Float = 0
    var velocity: SIMD3<Float> = .zero
    var size: Float = 0.12
    var color: SIMD4<Float> = .zero
    var seed: UInt32 = 0
    var _pad: SIMD3<UInt32> = .zero
}

private struct FireflySimUniforms {
    var time: Float = 0
    var dt: Float = 0
    var particleCount: UInt32 = 0
    var _pad0: UInt32 = 0
    var anchor: SIMD3<Float> = .zero
    var driftRadius: Float = 5
    var gravity: SIMD3<Float> = SIMD3(0, 0.15, 0)
    var drag: Float = 0.85
    var wander: Float = 1.1
    var lifeDecay: Float = 0.12
    var minSize: Float = 0.04
    var maxSize: Float = 0.14
}

private struct FireflyDrawUniforms {
    var viewProj: simd_float4x4 = matrix_identity_float4x4
    var cameraRight: SIMD3<Float> = .zero
    var _padR: Float = 0
    var cameraUp: SIMD3<Float> = .zero
    var _padU: Float = 0
}

/// Мягкий additive-слой вокруг якоря (ниже витрины).
final class FireflyDriftPass: GPUFrameEffect {
    var compositeDrawOrder: Int { 30 }

    private static let maxParticles = 8192

    private let particlesBuffer: MTLBuffer
    private let simUniformBuffer: MTLBuffer
    private let drawUniformBuffer: MTLBuffer

    private var computePSO: MTLComputePipelineState?
    private var renderPSO: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?

    init(device: MTLDevice) {
        var seeds: [FireflyParticle] = []
        seeds.reserveCapacity(Self.maxParticles)
        for i in 0..<Self.maxParticles {
            seeds.append(FireflyParticle(life: 0, seed: UInt32(i)))
        }
        let stride = MemoryLayout<FireflyParticle>.stride
        particlesBuffer = device.makeBuffer(bytes: seeds, length: seeds.count * stride, options: .storageModeShared)!
        simUniformBuffer = device.makeBuffer(length: MemoryLayout<FireflySimUniforms>.stride, options: .storageModeShared)!
        drawUniformBuffer = device.makeBuffer(length: MemoryLayout<FireflyDrawUniforms>.stride, options: .storageModeShared)!
    }

    func buildIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) {
        if computePSO != nil, renderPSO != nil, depthStencilState != nil { return }

        let kernel = library.makeFunction(name: "firefly_update_sim")!
        computePSO = try! device.makeComputePipelineState(function: kernel)

        renderPSO = try! EffectPipelineBuilders.makeAdditiveBillboardRenderPSO(
            device: device,
            library: library,
            label: "FireflyAdditive",
            vertex: "firefly_billboard_vs",
            fragment: "firefly_soft_additive_fs",
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat
        )

        // Depth-test against the scene so glow doesn't show through opaque geometry.
        depthStencilState = EffectPipelineBuilders.makeDepthState(device: device, compare: .lessEqual, writeEnabled: false)
    }

    func encodeCompute(into commandBuffer: MTLCommandBuffer, context: FrameEffectContext) {
        guard let computePSO else { return }
        let anchor = context.effectsAnchorPoint + SIMD3(0, -1.1, -1.2)
        let u = FireflySimUniforms(
            time: context.time,
            dt: max(1e-4, context.deltaTime),
            particleCount: UInt32(Self.maxParticles),
            _pad0: 0,
            anchor: anchor,
            driftRadius: context.hasSceneContent ? 7.5 : 4.2,
            gravity: SIMD3(0, 0.12, 0),
            drag: 0.9,
            wander: 1.05,
            lifeDecay: 0.11,
            minSize: 0.035,
            maxSize: 0.13
        )
        simUniformBuffer.contents().assumingMemoryBound(to: FireflySimUniforms.self).pointee = u

        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "FireflySim"
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
        let du = FireflyDrawUniforms(
            viewProj: context.viewProjection,
            cameraRight: context.cameraRight,
            _padR: 0,
            cameraUp: context.cameraUp,
            _padU: 0
        )
        drawUniformBuffer.contents().assumingMemoryBound(to: FireflyDrawUniforms.self).pointee = du
        encoder.setRenderPipelineState(renderPSO)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBuffer(particlesBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(drawUniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Self.maxParticles)
    }
}
