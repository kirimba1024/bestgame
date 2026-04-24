import simd

/// Расстановка и анимация демо-сцены в мировых координатах. Рендерер опирается на протокол, а не на `DemoScenePlacements` напрямую.
protocol ScenePlacementProviding: AnyObject {
    var shelfConfig: DemoScenePlacements.Config { get set }

    func computeShelfFrame(
        staticAssetNames: [String],
        staticHeroScale: [Bool],
        staticRendererCount: Int,
        skinnedAssetNames: [String],
        skinnedRendererCount: Int,
        hasFoxMeshFallback: Bool
    ) -> DemoScenePlacements.ShelfFrame

    func staticWorldModelMatrix(base: simd_float4x4, assetName: String, time: Float) -> simd_float4x4
    func skinnedStyle(assetName: String) -> DemoScenePlacements.SkinnedSlotStyle
    func foxInstancingGrid(origin: SIMD3<Float>) -> [SIMD3<Float>]
    func groundWorldMatrix(shelf: DemoScenePlacements.ShelfFrame) -> simd_float4x4
    func materialProbeWorldMatrix(shelf: DemoScenePlacements.ShelfFrame) -> simd_float4x4
}

/// Текущая демо-полка Khronos: делегирует в `DemoScenePlacements`.
final class DemoScenePlacementProvider: ScenePlacementProviding {
    var shelfConfig: DemoScenePlacements.Config

    init(config: DemoScenePlacements.Config = .init()) {
        self.shelfConfig = config
    }

    func computeShelfFrame(
        staticAssetNames: [String],
        staticHeroScale: [Bool],
        staticRendererCount: Int,
        skinnedAssetNames: [String],
        skinnedRendererCount: Int,
        hasFoxMeshFallback: Bool
    ) -> DemoScenePlacements.ShelfFrame {
        DemoScenePlacements.computeShelfFrame(
            staticAssetNames: staticAssetNames,
            staticHeroScale: staticHeroScale,
            staticRendererCount: staticRendererCount,
            skinnedAssetNames: skinnedAssetNames,
            skinnedRendererCount: skinnedRendererCount,
            hasFoxMeshFallback: hasFoxMeshFallback,
            config: shelfConfig
        )
    }

    func staticWorldModelMatrix(base: simd_float4x4, assetName: String, time: Float) -> simd_float4x4 {
        DemoScenePlacements.staticWorldModelMatrix(base: base, assetName: assetName, time: time)
    }

    func skinnedStyle(assetName: String) -> DemoScenePlacements.SkinnedSlotStyle {
        DemoScenePlacements.skinnedStyle(assetName: assetName, config: shelfConfig)
    }

    func foxInstancingGrid(origin: SIMD3<Float>) -> [SIMD3<Float>] {
        DemoScenePlacements.foxInstancingGrid(origin: origin)
    }

    func groundWorldMatrix(shelf: DemoScenePlacements.ShelfFrame) -> simd_float4x4 {
        DemoScenePlacements.groundWorldMatrix(shelf: shelf, config: shelfConfig)
    }

    func materialProbeWorldMatrix(shelf: DemoScenePlacements.ShelfFrame) -> simd_float4x4 {
        DemoScenePlacements.materialProbeWorldMatrix(shelf: shelf, config: shelfConfig)
    }
}
