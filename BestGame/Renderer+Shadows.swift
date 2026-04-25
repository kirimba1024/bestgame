import Metal
import simd

extension Renderer {
    // MARK: - Directional shadow

    func makeLightViewProj(sunDir: SIMD3<Float>) -> simd_float4x4 {
        // Keep it stable: scene provides world bounds (terrain + foliage chunks later).
        var wmin = SIMD3<Float>(-120, -40, -120)
        var wmax = SIMD3<Float>(120, 90, 120)
        if let b = scene.shadowWorldBounds() {
            wmin = simd_min(wmin, b.min)
            wmax = simd_max(wmax, b.max)
        }
        return DirectionalShadowFrustum.lightViewProjection(
            sunDir: sunDir,
            worldMin: wmin,
            worldMax: wmax,
            shadowMapResolution: shadowMap.size
        )
    }

    func drawShadowCasters(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4, time: Float) {
        scene.drawShadowCasters(encoder: encoder, lightViewProj: lightViewProj, time: time)
    }
}
