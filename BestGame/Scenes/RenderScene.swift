import Metal
import MetalKit
import simd

/// Минимальный контракт сцены: рендерер остаётся тонким, а логика мира/демо живёт в отдельных модулях.
protocol RenderScene: AnyObject {
    var hudLine: String? { get }

    func buildIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        environment: EnvironmentMap
    )

    /// AABB в мире для стабилизации directional shadow (можно фиксировать на чанки).
    func shadowWorldBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)?
    func drawShadowCasters(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4, time: Float)

    func effectsAnchor(time: Float) -> (showcaseFocal: SIMD3<Float>, effectsAnchor: SIMD3<Float>)

    /// Opaque geometry pass (writes depth).
    func drawOpaque(
        encoder: MTLRenderCommandEncoder,
        proj: simd_float4x4,
        view: simd_float4x4,
        viewProj: simd_float4x4,
        lightViewProj: simd_float4x4,
        cameraPos: SIMD3<Float>,
        time: Float,
        keyLight: SceneLighting.KeyLightFrame,
        shadowTexture: MTLTexture?,
        shadowSampler: MTLSamplerState?,
        environment: EnvironmentMap,
        drawableSize: CGSize
    )

    /// Transparent pass (must not sample the depth attachment; use `depthTextureForSampling`).
    func drawTransparent(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        lightViewProj: simd_float4x4,
        cameraPos: SIMD3<Float>,
        time: Float,
        keyLight: SceneLighting.KeyLightFrame,
        environment: EnvironmentMap,
        depthTextureForSampling: MTLTexture?,
        drawableSize: CGSize
    )
}

