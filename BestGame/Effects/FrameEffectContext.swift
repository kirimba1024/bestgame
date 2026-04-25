import simd

/// Всё, что GPU-эффекты запрашивают у кадра: без ссылок на `Renderer` / сцену.
struct FrameEffectContext {
    var time: Float
    var deltaTime: Float
    var viewProjection: simd_float4x4
    var viewMatrix: simd_float4x4
    var projectionMatrix: simd_float4x4
    var cameraPosition: SIMD3<Float>
    var cameraRight: SIMD3<Float>
    var cameraUp: SIMD3<Float>
    /// Точка «витрины» для декоративных эмиттеров (центр полки / fallback).
    var showcaseFocalPoint: SIMD3<Float>
    /// Якорь частиц/светлячков — смещён от полки.
    var effectsAnchorPoint: SIMD3<Float>
    var hasSceneContent: Bool
}
