import simd

final class HeightmapTerrainSampler: TerrainSampler {
    let config: TerrainRenderer.Config
    private let map: WorldHeightmapAsset

    init(config: TerrainRenderer.Config, map: WorldHeightmapAsset) {
        self.config = config
        self.map = map
    }

    func height(x: Float, z: Float) -> Float {
        map.heightBilinear(x: x, z: z, config: config)
    }

    func normal(x: Float, z: Float, step: Float) -> SIMD3<Float> {
        let e = max(0.25, step)
        let hL = height(x: x - e, z: z)
        let hR = height(x: x + e, z: z)
        let hD = height(x: x, z: z - e)
        let hU = height(x: x, z: z + e)
        let dx = (hR - hL) / (2 * e)
        let dz = (hU - hD) / (2 * e)
        let n = SIMD3<Float>(-dx, 1.0, -dz)
        let l2 = simd_length_squared(n)
        if !l2.isFinite || l2 < 1e-8 { return SIMD3<Float>(0, 1, 0) }
        return n / sqrt(l2)
    }
}

