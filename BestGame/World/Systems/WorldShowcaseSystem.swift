import Metal
import MetalKit
import simd

/// Мини‑витрина демо‑ассетов (шлем/лиса/бокс/сферы) поверх WorldScene, без старого demo‑пайплайна.
final class WorldShowcaseSystem {
    private let terrain: TerrainSampler

    private var staticModels: [StaticModelRenderer] = []
    private var staticNames: [String] = []
    private var skinnedModels: [SkinnedModelRenderer] = []
    private var skinnedNames: [String] = []
    private var probeSpheres: StaticModelRenderer?
    private var staticModelMatrices: [simd_float4x4] = []
    private var heroTranslation: SIMD3<Float> = .zero
    private var heroYaw: Float = .pi
    private var heroBasisRotation: simd_float4x4 = matrix_identity_float4x4
    private var rigTranslation: SIMD3<Float> = .zero
    private var rigYaw: Float = 0
    private var rigBasisRotation: simd_float4x4 = matrix_identity_float4x4
    private var rigTranslations: [SIMD3<Float>] = []
    private var foxTranslations: [SIMD3<Float>] = []
    private var probeMatrix: simd_float4x4 = matrix_identity_float4x4

    private(set) var hudLine: String?

    init(terrain: TerrainSampler) {
        self.terrain = terrain
    }

    func buildIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        environment: EnvironmentMap
    ) {
        if !staticModels.isEmpty || !skinnedModels.isEmpty { return }

        let loaded = DemoAssetsLoader.loadDefaultScene()
        hudLine = loaded.modelDebugLine

        staticNames = loaded.staticPBRAssetNames
        for model in loaded.pendingStaticPBRModels {
            let r = StaticModelRenderer(
                device: device,
                library: library,
                colorPixelFormat: colorPixelFormat,
                depthPixelFormat: depthPixelFormat,
                model: model,
                environment: environment
            )
            staticModels.append(r)
        }

        skinnedNames = loaded.skinnedPBRAssetNames
        for model in loaded.pendingSkinnedModels {
            let r = SkinnedModelRenderer(
                device: device,
                library: library,
                colorPixelFormat: colorPixelFormat,
                depthPixelFormat: depthPixelFormat,
                model: model,
                environment: environment
            )
            skinnedModels.append(r)
        }

        let probesModel = DemoProceduralGeometry.materialProbeSpheresModelExtended()
        probeSpheres = StaticModelRenderer(
            device: device,
            library: library,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat,
            model: probesModel,
            environment: environment
        )
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        cameraPos: SIMD3<Float>,
        lightViewProj: simd_float4x4,
        time: Float,
        keyLight: SceneLighting.KeyLightFrame,
        shadowTexture: MTLTexture?,
        shadowSampler: MTLSamplerState?
    ) {
        guard !staticModels.isEmpty || !skinnedModels.isEmpty else { return }

        rebuildPlacement(time: time)

        for i in 0..<min(staticModels.count, staticModelMatrices.count) {
            let name = (i < staticNames.count) ? staticNames[i] : ""
            let p = StaticModelRenderer.DrawParams(
                proj: paramsProj(viewProj: viewProj),
                view: paramsView(viewProj: viewProj),
                cameraPosWS: cameraPos,
                model: staticModelMatrices[i],
                lightViewProj: lightViewProj,
                keyLight: keyLight,
                shadowTexture: shadowTexture,
                shadowSampler: shadowSampler,
                exposure: (name == "DamagedHelmet") ? 1.6 : 1.0,
                debugMode: 0
            )
            staticModels[i].draw(encoder: encoder, params: p)
        }

        // Hero (CesiumMan if present)
        if let heroIdx = skinnedNames.firstIndex(where: { $0 == "CesiumMan" }) ?? skinnedNames.indices.first {
            let hero = skinnedModels[heroIdx]
            let p = SkinnedModelRenderer.DrawParams(
                proj: paramsProj(viewProj: viewProj),
                view: paramsView(viewProj: viewProj),
                cameraPosWS: cameraPos,
                time: time,
                modelTranslation: heroTranslation,
                modelScale: 9.9,
                modelBasisRotation: simd_float4x4.rotation(radians: heroYaw, axis: SIMD3<Float>(0, 1, 0)) * heroBasisRotation,
                lightViewProj: lightViewProj,
                keyLight: keyLight,
                shadowTexture: shadowTexture,
                shadowSampler: shadowSampler,
                debugMode: 0
            )
            hero.draw(encoder: encoder, params: p)
        }

        // RiggedSimple “green stick” (if present)
        if let rigIdx = skinnedNames.firstIndex(where: { $0 == "RiggedSimple" }) {
            let rig = skinnedModels[rigIdx]
            let base = SkinnedModelRenderer.DrawParams(
                proj: paramsProj(viewProj: viewProj),
                view: paramsView(viewProj: viewProj),
                cameraPosWS: cameraPos,
                time: time,
                modelTranslation: .zero,
                modelScale: 1.07,
                modelBasisRotation: simd_float4x4.rotation(radians: rigYaw, axis: SIMD3<Float>(0, 1, 0)) * rigBasisRotation,
                lightViewProj: lightViewProj,
                keyLight: keyLight,
                shadowTexture: shadowTexture,
                shadowSampler: shadowSampler,
                debugMode: 0
            )
            rig.drawInstances(encoder: encoder, baseParams: base, translations: rigTranslations)
        }

        // Fox instancing grid 3×3×3 (если есть Fox)
        if let foxIdx = skinnedNames.firstIndex(where: { $0 == "Fox" }), !foxTranslations.isEmpty {
            let fox = skinnedModels[foxIdx]
            let base = SkinnedModelRenderer.DrawParams(
                proj: paramsProj(viewProj: viewProj),
                view: paramsView(viewProj: viewProj),
                cameraPosWS: cameraPos,
                time: time,
                modelTranslation: .zero,
                modelScale: 0.045,
                modelBasisRotation: matrix_identity_float4x4,
                lightViewProj: lightViewProj,
                keyLight: keyLight,
                shadowTexture: shadowTexture,
                shadowSampler: shadowSampler,
                debugMode: 0
            )
            fox.drawInstances(encoder: encoder, baseParams: base, translations: foxTranslations)
        }

        if let probeSpheres {
            // Probes should be double-sided for debugging (avoid “seeing backfaces”).
            encoder.setCullMode(.none)
            let p = StaticModelRenderer.DrawParams(
                proj: paramsProj(viewProj: viewProj),
                view: paramsView(viewProj: viewProj),
                cameraPosWS: cameraPos,
                model: probeMatrix,
                lightViewProj: lightViewProj,
                keyLight: keyLight,
                shadowTexture: shadowTexture,
                shadowSampler: shadowSampler,
                debugMode: 0
            )
            probeSpheres.draw(encoder: encoder, params: p)
            encoder.setCullMode(.back)
        }
    }

    func drawShadowCasters(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4, time: Float) {
        guard !staticModels.isEmpty || !skinnedModels.isEmpty else { return }
        rebuildPlacement(time: time)

        // Static demo models
        for i in 0..<min(staticModels.count, staticModelMatrices.count) {
            staticModels[i].drawShadow(encoder: encoder, lightViewProj: lightViewProj, model: staticModelMatrices[i])
        }

        // Hero (CesiumMan) shadow
        if let heroIdx = skinnedNames.firstIndex(where: { $0 == "CesiumMan" }) ?? skinnedNames.indices.first {
            skinnedModels[heroIdx].drawShadow(
                encoder: encoder,
                lightViewProj: lightViewProj,
                time: time,
                modelTranslation: heroTranslation,
                modelScale: 9.9,
                modelBasisRotation: simd_float4x4.rotation(radians: heroYaw, axis: SIMD3<Float>(0, 1, 0)) * heroBasisRotation
            )
        }

        // RiggedSimple shadow
        if let rigIdx = skinnedNames.firstIndex(where: { $0 == "RiggedSimple" }) {
            skinnedModels[rigIdx].drawShadowInstances(
                encoder: encoder,
                lightViewProj: lightViewProj,
                time: time,
                translations: rigTranslations,
                modelScale: 1.07,
                modelBasisRotation: simd_float4x4.rotation(radians: rigYaw, axis: SIMD3<Float>(0, 1, 0)) * rigBasisRotation
            )
        }

        // Fox grid shadows
        if let foxIdx = skinnedNames.firstIndex(where: { $0 == "Fox" }), !foxTranslations.isEmpty {
            skinnedModels[foxIdx].drawShadowInstances(
                encoder: encoder,
                lightViewProj: lightViewProj,
                time: time,
                translations: foxTranslations,
                modelScale: 0.045,
                modelBasisRotation: matrix_identity_float4x4
            )
        }

        // Probe spheres shadows
        if let probeSpheres {
            probeSpheres.drawShadow(encoder: encoder, lightViewProj: lightViewProj, model: probeMatrix)
        }
    }

    // MARK: - Placement

    private func rebuildPlacement(time: Float) {
        staticModelMatrices.removeAll(keepingCapacity: true)
        foxTranslations.removeAll(keepingCapacity: true)
        rigTranslations.removeAll(keepingCapacity: true)

        // “Полка” около спавна: чуть впереди камеры и над землей.
        let baseXZ = SIMD2<Float>(0, -8)
        let baseY = terrain.height(x: baseXZ.x, z: baseXZ.y)
        let base = SIMD3<Float>(baseXZ.x, max(0.0, baseY) + 1.2, baseXZ.y)

        // Static: шлем/бумбокс/бокс — ряд по X.
        if !staticModels.isEmpty {
            let spacing: Float = 4.2
            let startX = base.x - spacing * Float(max(0, staticModels.count - 1)) * 0.5
            for i in 0..<staticModels.count {
                let x = startX + Float(i) * spacing
                let bob = 0.08 * sin(time * 0.9 + Float(i) * 1.7)
                let name = (i < staticNames.count) ? staticNames[i] : ""

                // Default transforms
                var extraX: Float = 0
                var extraY: Float = 0
                var extraZ: Float = 0
                var scale: Float = 1.0

                // Move DamagedHelmet away from fox grid, scale it up 4×, and lift it much higher.
                if name == "DamagedHelmet" {
                    // Opposite side from Box.
                    extraX = -18.0
                    extraZ = -6.0
                    extraY = 7.5
                    scale = 6.0
                }

                // Red box: make it bigger and move it far away from fox grid.
                if name == "Box" {
                    extraX = 18.0
                    extraZ = -14.0
                    extraY = 1.8
                    scale = 3.0
                }

                let yawSpeed: Float = {
                    switch name {
                    case "Box": return 1.0      // ~4× faster than before
                    case "DamagedHelmet": return 0.55 // a bit faster
                    default: return 0.25
                    }
                }()
                let M =
                    simd_float4x4.translation(SIMD3<Float>(x + extraX, base.y + bob + 1.0 + extraY, base.z + extraZ))
                    * simd_float4x4.rotation(radians: time * yawSpeed + Float(i) * 0.2, axis: SIMD3<Float>(0, 1, 0))
                    * simd_float4x4.scale(SIMD3<Float>(repeating: scale))
                staticModelMatrices.append(M)
            }
        }

        // Hero placement (walking guy): higher and closer to center.
        heroTranslation = SIMD3<Float>(base.x + 20.0, base.y + 0.15, base.z - 18.0)
        heroYaw = .pi + 0.25 * sin(time * 0.45)
        // Restore CesiumMan basis rotation exactly like old demo scene.
        heroBasisRotation = DemoScenePlacements.skinnedStyle(assetName: "CesiumMan", config: .init()).modelBasisRotation

        // RiggedSimple: place near hero, make it very visible.
        rigTranslation = SIMD3<Float>(base.x + 30.0, base.y + 0.45, base.z + 12.0)
        rigYaw = 0.15 * sin(time * 0.35)
        rigBasisRotation = DemoScenePlacements.skinnedStyle(assetName: "RiggedSimple", config: .init()).modelBasisRotation

        // RiggedSimple grid 3x3 in XZ, moved by +Z away from foxes.
        let grid: Float = 6.0
        for iz in 0..<3 {
            for ix in 0..<3 {
                let p = rigTranslation + SIMD3<Float>((Float(ix) - 1) * grid, 0, (Float(iz) - 1) * grid)
                rigTranslations.append(p)
            }
        }

        // Fox 3×3×3
        let foxOrigin = SIMD3<Float>(base.x, base.y + 4.2, base.z - 3.0)
        foxTranslations = DemoScenePlacements.foxInstancingGrid(origin: foxOrigin)

        // Material probe spheres: closer to center, bigger and clearly above ground.
        probeMatrix =
            simd_float4x4.translation(SIMD3<Float>(base.x - 2.0, base.y + 15.0, base.z - 10.0))
            * simd_float4x4.scale(SIMD3<Float>(repeating: 1.9))
    }

    // MARK: - View/proj helpers

    // We already get `viewProj` from renderer, but Static/Skinned renderers expect `proj` and `view` separately.
    // For showcase we only need correct MVP, so use identity view and feed viewProj as "proj".
    private func paramsProj(viewProj: simd_float4x4) -> simd_float4x4 { viewProj }
    private func paramsView(viewProj: simd_float4x4) -> simd_float4x4 { matrix_identity_float4x4 }
}

