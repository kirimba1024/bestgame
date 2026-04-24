import simd

/// Расстановка демо-сцены: одни и те же матрицы для цветового прохода, теней и tight-fit frustum.
enum DemoScenePlacements {
    // MARK: - Config

    struct Config {
        var sceneDepthZ: Float = -5.5
        /// Расстояние между центрами слотов шлем / лиса.
        var sceneSpacingX: Float = 16.0
        var staticBaseScale: Float = 0.5
        var helmetAssetName: String = "DamagedHelmet"
        /// Было 5 — удвоено по запросу.
        var helmetScaleMultiplier: Float = 10
        /// Масштаб одного инстанса лисы (draw + shadow + AABB).
        var foxModelScale: Float = 0.045
        /// Высота опоры шлема (и базовая для лис) над полом Y=0.
        var heroRestHeightY: Float = 3.35
        /// Доп. подъём только сетки лис (нижние ряды уходят в −Y относительно центра).
        var foxGridExtraLiftY: Float = 0.85
        /// Доп. только для шлема (выше лис и пола).
        var helmetExtraLiftY: Float = 1.35
        var groundMarginX: Float = 20
        var groundHalfDepthZ: Float = 34
        var probeSpheresY: Float = 1.18
        /// Сферы ближе к камере, дальше от шлема/лис по глубине.
        var probeSpheresZBias: Float = 7.4
        /// Сдвиг сфер по X: отрицательный — в сторону от лис (слот лис обычно справа, +X).
        var probeSpheresOffsetX: Float = -14.5
        var probeSpheresUniformScale: Float = 1.22
    }

    // MARK: - Shelf frame

    struct ShelfFrame {
        /// Индекс совпадает с порядком героевских `StaticModelRenderer` (только glTF из слотов).
        var staticModelMatrices: [simd_float4x4]
        /// Центр слота «лиса» по X; `nil`, если слота нет.
        var foxSlotCenterX: Float?
        var hasFoxSlot: Bool { foxSlotCenterX != nil }
        /// Границы по X занятых слотов шлем+лиса (для пола и проб).
        var slotSpanMinX: Float
        var slotSpanMaxX: Float
    }

    static func computeShelfFrame(
        staticAssetNames: [String],
        staticRendererCount: Int,
        hasSkinnedFox: Bool,
        hasFoxMeshFallback: Bool,
        config: Config = .init()
    ) -> ShelfFrame {
        let hasFoxSlot = hasSkinnedFox || hasFoxMeshFallback
        let totalSlots = staticRendererCount + (hasFoxSlot ? 1 : 0)
        let xs = SceneLayout.xOffsets(count: max(1, totalSlots), spacing: config.sceneSpacingX)
        var slot = 0

        let rotY = simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])

        var staticMatrices: [simd_float4x4] = []
        staticMatrices.reserveCapacity(staticRendererCount)
        for i in 0..<staticRendererCount {
            let x = xs[slot]
            slot += 1
            let isHelmet = i < staticAssetNames.count && staticAssetNames[i] == config.helmetAssetName
            let scale = config.staticBaseScale * (isHelmet ? config.helmetScaleMultiplier : 1)
            let baseY = config.heroRestHeightY + (isHelmet ? config.helmetExtraLiftY : 0)
            let baseT = simd_float4x4.translation([0, baseY, config.sceneDepthZ])
            let modelM =
                baseT
                * simd_float4x4.translation([x, 0, 0])
                * rotY
                * simd_float4x4.scale([scale, scale, scale])
            staticMatrices.append(modelM)
        }

        let foxX: Float? = hasFoxSlot ? xs[slot] : nil

        let spanSlots = max(1, totalSlots)
        let slotSpanMinX = xs[0]
        let slotSpanMaxX = xs[spanSlots - 1]

        return ShelfFrame(
            staticModelMatrices: staticMatrices,
            foxSlotCenterX: foxX,
            slotSpanMinX: slotSpanMinX,
            slotSpanMaxX: slotSpanMaxX
        )
    }

    /// Матрица пола: центр по X между слотами, лежит в XZ.
    static func groundWorldMatrix(shelf: ShelfFrame, config: Config) -> simd_float4x4 {
        let cx = (shelf.slotSpanMinX + shelf.slotSpanMaxX) * 0.5
        let halfW = max(18, (shelf.slotSpanMaxX - shelf.slotSpanMinX) * 0.5 + config.groundMarginX)
        let dz = config.groundHalfDepthZ
        return simd_float4x4.translation(SIMD3(cx, 0, config.sceneDepthZ))
            * simd_float4x4.scale(SIMD3(halfW * 2, 1, dz * 2))
    }

    /// Три сферы по центру полки, чуть впереди по −Z.
    static func materialProbeWorldMatrix(shelf: ShelfFrame, config: Config) -> simd_float4x4 {
        let cx = (shelf.slotSpanMinX + shelf.slotSpanMaxX) * 0.5 + config.probeSpheresOffsetX
        let z = config.sceneDepthZ + config.probeSpheresZBias
        let s = config.probeSpheresUniformScale
        return simd_float4x4.translation(SIMD3(cx, config.probeSpheresY, z))
            * simd_float4x4.scale(SIMD3(repeating: s))
    }

    // MARK: - Fox instancing grid

    static func foxInstancingGrid(origin: SIMD3<Float>) -> [SIMD3<Float>] {
        let n = FoxInstancing.gridExtent
        let spacing = FoxInstancing.spacing
        let half = Float(n - 1) * 0.5

        var translations: [SIMD3<Float>] = []
        translations.reserveCapacity(n * n * n)

        for iz in 0..<n {
            for iy in 0..<n {
                for ix in 0..<n {
                    let offset = SIMD3<Float>(
                        (Float(ix) - half) * spacing.x,
                        (Float(iy) - half) * spacing.y,
                        (Float(iz) - half) * spacing.z
                    )
                    translations.append(origin + offset)
                }
            }
        }
        return translations
    }

    private enum FoxInstancing {
        static let gridExtent = 3
        static let spacing = SIMD3<Float>(4.4, 3.6, 6.0)
    }
}
