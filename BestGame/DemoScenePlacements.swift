import simd

/// Расстановка демо-сцены: одни и те же матрицы для цветового прохода, теней и tight-fit frustum.
enum DemoScenePlacements {
    // MARK: - Config

    struct Config {
        var sceneDepthZ: Float = -5.5
        /// Расстояние между центрами слотов на полке.
        var sceneSpacingX: Float = 14.0
        var staticBaseScale: Float = 0.5
        /// Множитель масштаба для слотов с `staticHeroScale[i] == true` (крупный PBR-герой).
        var heroScaleMultiplier: Float = 10
        /// Масштаб одного инстанса лисы (draw + shadow + AABB).
        var foxModelScale: Float = 0.045
        /// Высота опоры шлема (и базовая для лис) над полом Y=0.
        var heroRestHeightY: Float = 3.35
        /// Доп. подъём только сетки лис (нижние ряды уходят в −Y относительно центра).
        var foxGridExtraLiftY: Float = 0.85
        /// Доп. подъём только для «геройских» статических слотов (шлем выше полки).
        var heroExtraLiftY: Float = 3.38
        var groundMarginX: Float = 36
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
        /// Центры по X для каждого скиннутого ассета (тот же порядок, что `skinnedRenderers`).
        var skinnedSlotCentersX: [Float]
        /// Базовый Z для каждого скиннутого слота (`sceneDepthZ` + сдвиг из `skinnedStyle`).
        var skinnedSlotBaseZ: [Float]
        /// Слот для отладочного меша лисы, если скин не загрузился, а геометрия есть.
        var foxMeshDebugSlotCenterX: Float?
        var slotSpanMinX: Float
        var slotSpanMaxX: Float
    }

    /// Размещение скиннутого ассета: сетка инстансов (только Fox) или один экземпляр.
    struct SkinnedSlotStyle {
        var useInstancingGrid: Bool
        var modelScale: Float
        var extraLiftY: Float
        /// Сдвиг по Z относительно `config.sceneDepthZ` (+ — ближе к типичной камере с +Z).
        var depthBiasZ: Float
        var modelBasisRotation: simd_float4x4
    }

    static func skinnedStyle(assetName: String, config: Config) -> SkinnedSlotStyle {
        switch assetName {
        case "Fox":
            return .init(
                useInstancingGrid: true,
                modelScale: config.foxModelScale,
                extraLiftY: config.foxGridExtraLiftY,
                depthBiasZ: 0,
                modelBasisRotation: matrix_identity_float4x4
            )
        case "CesiumMan":
            /// +π/2 по X давал «кверх ногами» — используем −π/2 (ориентация после общего R_y(π)).
            let pitch = simd_float4x4.rotation(radians: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            return .init(
                useInstancingGrid: false,
                modelScale: 5.5,
                extraLiftY: 0.35,
                depthBiasZ: 2.35,
                modelBasisRotation: pitch
            )
        case "RiggedSimple":
            let rx180 = simd_float4x4.rotation(radians: .pi, axis: SIMD3<Float>(1, 0, 0))
            let rx90 = simd_float4x4.rotation(radians: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
            let stand = rx180 * rx90
            return .init(
                useInstancingGrid: false,
                modelScale: 1.55,
                extraLiftY: 0,
                depthBiasZ: 2.35,
                modelBasisRotation: stand
            )
        default:
            return .init(
                useInstancingGrid: false,
                modelScale: config.foxModelScale,
                extraLiftY: 0,
                depthBiasZ: 0,
                modelBasisRotation: matrix_identity_float4x4
            )
        }
    }

    /// Доп. множитель к `staticBaseScale` / геройскому масштабу (локальные единицы Khronos сильно различаются).
    static func staticSizeMultiplier(assetName: String) -> Float {
        switch assetName {
        case "Box":
            return 6.2
        case "BoomBox":
            return 0.32
        default:
            return 1.0
        }
    }

    static func computeShelfFrame(
        staticAssetNames: [String],
        staticHeroScale: [Bool],
        staticRendererCount: Int,
        skinnedAssetNames: [String],
        skinnedRendererCount: Int,
        hasFoxMeshFallback: Bool,
        config: Config = .init()
    ) -> ShelfFrame {
        let needsDebugFoxSlot = hasFoxMeshFallback && skinnedRendererCount == 0
        let totalSlots = staticRendererCount + skinnedRendererCount + (needsDebugFoxSlot ? 1 : 0)
        let xs = SceneLayout.xOffsets(count: max(1, totalSlots), spacing: config.sceneSpacingX)
        var slot = 0

        let rotY = simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])

        var staticMatrices: [simd_float4x4] = []
        staticMatrices.reserveCapacity(staticRendererCount)
        for i in 0..<staticRendererCount {
            let x = xs[slot]
            slot += 1
            let isHero = i < staticHeroScale.count && staticHeroScale[i]
            let assetName = i < staticAssetNames.count ? staticAssetNames[i] : ""
            let slotMul = staticSizeMultiplier(assetName: assetName)
            let scale =
                config.staticBaseScale
                * (isHero ? config.heroScaleMultiplier : 1)
                * slotMul
            let baseY = config.heroRestHeightY + (isHero ? config.heroExtraLiftY : 0)
            let baseT = simd_float4x4.translation([0, baseY, config.sceneDepthZ])
            let modelM =
                baseT
                * simd_float4x4.translation([x, 0, 0])
                * rotY
                * simd_float4x4.scale([scale, scale, scale])
            staticMatrices.append(modelM)
        }

        var skinnedCenters: [Float] = []
        var skinnedBaseZ: [Float] = []
        skinnedCenters.reserveCapacity(skinnedRendererCount)
        skinnedBaseZ.reserveCapacity(skinnedRendererCount)
        for j in 0..<skinnedRendererCount {
            skinnedCenters.append(xs[slot])
            let nm = j < skinnedAssetNames.count ? skinnedAssetNames[j] : ""
            let st = skinnedStyle(assetName: nm, config: config)
            skinnedBaseZ.append(config.sceneDepthZ + st.depthBiasZ)
            slot += 1
        }

        let debugFoxX: Float? = needsDebugFoxSlot ? xs[slot] : nil

        let spanSlots = max(1, totalSlots)
        let slotSpanMinX = xs[0]
        let slotSpanMaxX = xs[spanSlots - 1]

        return ShelfFrame(
            staticModelMatrices: staticMatrices,
            skinnedSlotCentersX: skinnedCenters,
            skinnedSlotBaseZ: skinnedBaseZ,
            foxMeshDebugSlotCenterX: debugFoxX,
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

    // MARK: - Статика: вращение вокруг вертикали через проекцию центра на пол (XZ)

    private static func worldYawAtFootprint(base: simd_float4x4, time: Float, speed: Float) -> simd_float4x4 {
        let px = base.columns.3.x
        let pz = base.columns.3.z
        let p = SIMD3<Float>(px, 0, pz)
        let r = simd_float4x4.rotation(radians: time * speed, axis: SIMD3<Float>(0, 1, 0))
        return simd_float4x4.translation(p) * r * simd_float4x4.translation(-p)
    }

    static func staticWorldModelMatrix(base: simd_float4x4, assetName: String, time: Float) -> simd_float4x4 {
        switch assetName {
        case "Box":
            return worldYawAtFootprint(base: base, time: time, speed: 0.9) * base
        case "DamagedHelmet":
            return worldYawAtFootprint(base: base, time: time, speed: 0.38) * base
        default:
            return base
        }
    }
}
