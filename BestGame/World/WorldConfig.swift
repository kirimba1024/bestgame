import simd

/// Единый конфиг мира: все “магические числа” собраны тут.
struct WorldConfig {
    /// Идентификатор “мира” (папка ассетов карты в Application Support).
    var worldID: String = "default"
    /// Увеличь, чтобы принудительно сгенерить новый heightmap (новая папка, без удаления старой).
    var heightmapRevision: Int = 1

    var terrain = TerrainRenderer.Config()

    var lake = LakeWaterRenderer.Config(
        center: SIMD2(32, -18),
        surfaceY: -0.9,
        halfSize: 22
    )

    var puddles = DepressionWaterRenderer.Config(
        waterLevelY: -0.95,
        minDepth: 0.25
    )

    var foliage = FoliageConfig()

    struct FoliageConfig {
        var birchAssetName: String = "BirchTree"
        var grassWindEnabled: Bool = true
    }

    static let `default` = WorldConfig()
}

