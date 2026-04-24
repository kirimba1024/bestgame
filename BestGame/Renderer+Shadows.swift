import Metal
import simd

extension Renderer {
    // MARK: - Directional shadow

    func makeLightViewProj(sunDir: SIMD3<Float>, shelf: DemoScenePlacements.ShelfFrame) -> simd_float4x4 {
        var wmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var wmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        func growWorldAABB(model: simd_float4x4, localMin: SIMD3<Float>, localMax: SIMD3<Float>) {
            for c in DirectionalShadowFrustum.worldAABB8Corners(min: localMin, max: localMax) {
                let p = DirectionalShadowFrustum.transformWorldPoint(model, c)
                wmin = simd_min(wmin, p)
                wmax = simd_max(wmax, p)
            }
        }

        for (index, renderer) in staticPBRRenderers.enumerated() {
            let modelM = shelf.staticModelMatrices[index]
            growWorldAABB(
                model: modelM,
                localMin: renderer.localBounds.min,
                localMax: renderer.localBounds.max
            )
        }

        if let skinned = skinnedRenderer, let foxX = shelf.foxSlotCenterX {
            let foxY = sceneShelfConfig.heroRestHeightY + sceneShelfConfig.foxGridExtraLiftY
            let origin = SIMD3(foxX, foxY, sceneShelfConfig.sceneDepthZ)
            let grid = DemoScenePlacements.foxInstancingGrid(origin: origin)
            let s = sceneShelfConfig.foxModelScale
            for t in grid {
                let modelM =
                    simd_float4x4.translation(t)
                    * simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])
                    * simd_float4x4.scale([s, s, s])
                growWorldAABB(model: modelM, localMin: skinned.localBounds.min, localMax: skinned.localBounds.max)
            }
        }

        if let ground = groundPlaneRenderer {
            let gm = DemoScenePlacements.groundWorldMatrix(shelf: shelf, config: sceneShelfConfig)
            growWorldAABB(model: gm, localMin: ground.localBounds.min, localMax: ground.localBounds.max)
        }
        if let probe = materialProbeRenderer {
            let pm = DemoScenePlacements.materialProbeWorldMatrix(shelf: shelf, config: sceneShelfConfig)
            growWorldAABB(model: pm, localMin: probe.localBounds.min, localMax: probe.localBounds.max)
        }

        if !wmin.x.isFinite || !wmax.x.isFinite {
            let center = SIMD3<Float>(0, 1.0, sceneShelfConfig.sceneDepthZ)
            return DirectionalShadowFrustum.fallbackLightViewProjection(sunDir: sunDir, sceneCenter: center)
        }

        return DirectionalShadowFrustum.lightViewProjection(
            sunDir: sunDir,
            worldMin: wmin,
            worldMax: wmax,
            shadowMapResolution: shadowMap.size
        )
    }

    func drawShadowCasters(
        encoder: MTLRenderCommandEncoder,
        lightViewProj: simd_float4x4,
        time: Float,
        shelf: DemoScenePlacements.ShelfFrame
    ) {
        for (index, renderer) in staticPBRRenderers.enumerated() {
            let modelM = shelf.staticModelMatrices[index]
            renderer.drawShadow(encoder: encoder, lightViewProj: lightViewProj, model: modelM)
        }

        if let skinned = skinnedRenderer, let foxX = shelf.foxSlotCenterX {
            let foxY = sceneShelfConfig.heroRestHeightY + sceneShelfConfig.foxGridExtraLiftY
            let origin = SIMD3(foxX, foxY, sceneShelfConfig.sceneDepthZ)
            let grid = DemoScenePlacements.foxInstancingGrid(origin: origin)
            skinned.drawShadowInstances(
                encoder: encoder,
                lightViewProj: lightViewProj,
                time: time,
                translations: grid,
                modelScale: sceneShelfConfig.foxModelScale
            )
        }

        let groundM = DemoScenePlacements.groundWorldMatrix(shelf: shelf, config: sceneShelfConfig)
        groundPlaneRenderer?.drawShadow(encoder: encoder, lightViewProj: lightViewProj, model: groundM)

        let probeM = DemoScenePlacements.materialProbeWorldMatrix(shelf: shelf, config: sceneShelfConfig)
        materialProbeRenderer?.drawShadow(encoder: encoder, lightViewProj: lightViewProj, model: probeM)
    }
}
