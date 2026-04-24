import simd

// MARK: - Единая конфигурация сцены: солнце (направление + яркости). Без второго key light.

/// Всё, что должно согласованно меняться при настройке «одного солнца»: направление, PBR, небо, env-текстура.
enum SceneLighting {
    // MARK: Направление (world, к солнцу)

    static let sunBaseDirection = normalize(SIMD3<Float>(0.38, 0.92, 0.28))
    static let sunRotationRadiansPerSecond: Float = 0.22

    static func sunDirection(atTime t: Float) -> SIMD3<Float> {
        let a = t * sunRotationRadiansPerSecond
        let c = cos(a), s = sin(a)
        let d = sunBaseDirection
        return normalize(SIMD3<Float>(d.x * c - d.z * s, d.y, d.x * s + d.z * c))
    }

    // MARK: Яркости (linear RGB)

    /// Ключевой направленный свет в PBR (после него идёт только тень; IBL/ambient отдельно).
    static let directSunRadiance = SIMD3<Float>(1.12, 1.08, 1.02)

    /// HDR для диска солнца в небе и кругляша в equirect env (один источник правды для «солнечного блика»).
    static let hdrSunRadiance = SIMD3<Float>(6.0, 5.7, 5.1)

    // MARK: Кадр для GPU (одним блоком в шейдеры)

    /// Всё для buffer(4) в `fragment_pbr_mr`: ключевой свет + HDR для тумана/согласованности с небом.
    struct KeyLightFrame: Sendable {
        var directionWS: SIMD3<Float>
        var radianceLinear: SIMD3<Float>
        var skyDiskRadianceHDR: SIMD3<Float>
    }

    static func keyLight(atTime t: Float) -> KeyLightFrame {
        KeyLightFrame(
            directionWS: sunDirection(atTime: t),
            radianceLinear: directSunRadiance,
            skyDiskRadianceHDR: hdrSunRadiance
        )
    }

    /// Совпадает с `KeyLightUniforms` в Metal (`fragment_pbr_mr`, buffer 4).
    struct KeyLightGPUBytes {
        var dirWS: SIMD3<Float>
        var _p0: Float = 0
        var radianceLinear: SIMD3<Float>
        var _p1: Float = 0
        var skyDiskRadianceHDR: SIMD3<Float>
        var _p2: Float = 0

        init(_ frame: KeyLightFrame) {
            dirWS = frame.directionWS
            radianceLinear = frame.radianceLinear
            skyDiskRadianceHDR = frame.skyDiskRadianceHDR
        }
    }
}
