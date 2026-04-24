import Metal
import simd

extension SkinnedModelRenderer {
    // MARK: - Public draw entry points

    func draw(encoder: MTLRenderCommandEncoder, params: DrawParams) {
        updateJoints(time: params.time)
        drawPrepared(encoder: encoder, params: params)
    }

    func drawInstances(encoder: MTLRenderCommandEncoder, baseParams: DrawParams, translations: [SIMD3<Float>]) {
        updateJoints(time: baseParams.time)
        for t in translations {
            var p = baseParams
            p.modelTranslation = t
            drawPrepared(encoder: encoder, params: p)
        }
    }

    func drawShadow(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4, time: Float, modelTranslation: SIMD3<Float>, modelScale: Float) {
        updateJoints(time: time)
        drawShadowPrepared(encoder: encoder, lightViewProj: lightViewProj, modelTranslation: modelTranslation, modelScale: modelScale)
    }

    func drawShadowInstances(
        encoder: MTLRenderCommandEncoder,
        lightViewProj: simd_float4x4,
        time: Float,
        translations: [SIMD3<Float>],
        modelScale: Float
    ) {
        updateJoints(time: time)
        for t in translations {
            drawShadowPrepared(encoder: encoder, lightViewProj: lightViewProj, modelTranslation: t, modelScale: modelScale)
        }
    }

    // MARK: - Encoders

    private func drawPrepared(encoder: MTLRenderCommandEncoder, params: DrawParams) {
        let modelM =
            simd_float4x4.translation(params.modelTranslation)
            * simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])
            * simd_float4x4.scale([params.modelScale, params.modelScale, params.modelScale])

        let mvp = params.proj * params.view * modelM
        let normalMatrix = modelM.inverse.transpose

        encoder.setRenderPipelineState(pipeline)

        var u = PBRTypes.Uniforms(
            mvp: mvp,
            model: modelM,
            normalMatrix: normalMatrix,
            lightViewProj: params.lightViewProj,
            cameraPosWS: params.cameraPosWS,
            jointCount: UInt32(jointCount),
            baseColorFactor: baseColorFactor,
            metallicFactor: metallicFactor,
            roughnessFactor: roughnessFactor,
            exposure: 1.0,
            debugMode: params.debugMode
        )
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<PBRTypes.Uniforms>.stride, index: 1)
        encoder.setVertexBuffer(jointBuffer, offset: 0, index: 2)

        encoder.setFragmentBytes(&u, length: MemoryLayout<PBRTypes.Uniforms>.stride, index: 0)
        var keyL = SceneLighting.KeyLightGPUBytes(params.keyLight)
        encoder.setFragmentBytes(&keyL, length: MemoryLayout<SceneLighting.KeyLightGPUBytes>.stride, index: 4)
        encoder.setFragmentTexture(baseColorTex ?? environment.neutralBaseColor1x1, index: 0)
        encoder.setFragmentTexture(metallicRoughnessTex ?? environment.neutralMetallicRoughness1x1, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(environment.texture, index: 2)
        encoder.setFragmentSamplerState(environment.sampler, index: 1)
        if let st = params.shadowTexture { encoder.setFragmentTexture(st, index: 3) }
        if let ss = params.shadowSampler { encoder.setFragmentSamplerState(ss, index: 2) }

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    private func drawShadowPrepared(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4, modelTranslation: SIMD3<Float>, modelScale: Float) {
        let modelM =
            simd_float4x4.translation(modelTranslation)
            * simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])
            * simd_float4x4.scale([modelScale, modelScale, modelScale])

        struct ShadowUniforms {
            var lightViewProj: simd_float4x4
            var model: simd_float4x4
            var jointCount: UInt32
            var _pad0: SIMD3<Float> = .zero
        }

        encoder.setRenderPipelineState(shadowPipeline)
        var u = ShadowUniforms(lightViewProj: lightViewProj, model: modelM, jointCount: UInt32(jointCount))
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<ShadowUniforms>.stride, index: 1)
        encoder.setVertexBuffer(jointBuffer, offset: 0, index: 2)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }
}
