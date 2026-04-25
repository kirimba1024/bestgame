import simd

enum ProceduralTerrainGenerator {
    static func height(x: Float, z: Float, cfg: TerrainRenderer.Config) -> Float {
        // Stable “MMO terrain” recipe: low-frequency shapes + ridges + plateaus.
        let p = SIMD2<Float>(x, z)
        let n0 = fbm(p * 0.008, octaves: 4)
        let n1 = ridge(p * 0.018, octaves: 3)
        let n2 = fbm(p * 0.045, octaves: 2)

        var h = (0.62 * n0 + 0.28 * n1 + 0.10 * n2)
        // Plateau quantization (soft).
        let terraces: Float = 7.0
        let q = floor(h * terraces) / terraces
        h = h + (q - h) * 0.18
        var y = cfg.baseHeight + h * cfg.heightScale

        // A visible lake near spawn (but not on the flat pad): carve a smooth bowl.
        // Center chosen so it's immediately visible after spawn/camera move.
        let lakeC = SIMD2<Float>(32, -18)
        let lakeR: Float = 26.0
        let d = length(p - lakeC)
        if d < lakeR {
            let t = 1.0 - saturate(d / max(1e-3, lakeR))
            let bowl = t * t * (3 - 2 * t)
            // Deeper carve so lake water isn't hidden under the terrain.
            y -= bowl * 11.5
        }

        // Flat spawn pad around (0,0,0): exactly Y=0 with a smooth blend.
        let r = length(p)
        let flatRadius: Float = 22.0
        let blendWidth: Float = 28.0
        if r <= flatRadius {
            y = 0.0
        } else if r <= flatRadius + blendWidth {
            let t = saturate((r - flatRadius) / max(1e-3, blendWidth))
            let s = t * t * (3 - 2 * t) // smoothstep
            y = (0.0 + (y - 0.0) * s)
        }

        return y
    }

    static func normal(x: Float, z: Float, cfg: TerrainRenderer.Config, step: Float) -> SIMD3<Float> {
        let e = max(0.25, step)
        let hL = height(x: x - e, z: z, cfg: cfg)
        let hR = height(x: x + e, z: z, cfg: cfg)
        let hD = height(x: x, z: z - e, cfg: cfg)
        let hU = height(x: x, z: z + e, cfg: cfg)
        let dx = (hR - hL) / (2 * e)
        let dz = (hU - hD) / (2 * e)
        let n = SIMD3<Float>(-dx, 1.0, -dz)
        let l2 = simd_length_squared(n)
        if !l2.isFinite || l2 < 1e-8 { return SIMD3<Float>(0, 1, 0) }
        return n / sqrt(l2)
    }

    // MARK: - Noise (tiny, deterministic, no allocations)

    private static func hash(_ p: SIMD2<Float>) -> Float {
        let x = sin(dot(p, SIMD2(127.1, 311.7))) * 43758.5453123
        return x - floor(x)
    }

    private static func valueNoise(_ p: SIMD2<Float>) -> Float {
        let i = floor(p)
        let f = p - i
        let a = hash(i + SIMD2(0, 0))
        let b = hash(i + SIMD2(1, 0))
        let c = hash(i + SIMD2(0, 1))
        let d = hash(i + SIMD2(1, 1))
        let u = f * f * (SIMD2<Float>(3, 3) - 2 * f)
        let lerpX1 = a + (b - a) * u.x
        let lerpX2 = c + (d - c) * u.x
        return lerpX1 + (lerpX2 - lerpX1) * u.y
    }

    private static func fbm(_ p: SIMD2<Float>, octaves: Int) -> Float {
        var f: Float = 0
        var amp: Float = 0.5
        var pp = p
        for _ in 0..<max(1, octaves) {
            f += amp * valueNoise(pp)
            pp *= 2.02
            amp *= 0.5
        }
        return f
    }

    private static func ridge(_ p: SIMD2<Float>, octaves: Int) -> Float {
        var f: Float = 0
        var amp: Float = 0.55
        var pp = p
        for _ in 0..<max(1, octaves) {
            let n = valueNoise(pp)
            let r = 1.0 - abs(2.0 * n - 1.0)
            f += amp * r
            pp *= 2.01
            amp *= 0.5
        }
        return f
    }

    private static func saturate(_ x: Float) -> Float { min(1, max(0, x)) }
}

