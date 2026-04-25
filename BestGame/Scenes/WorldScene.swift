import Metal
import MetalKit
import simd

/// WorldScene: террейн + трава + вода + берёзовый лес. Без зависимостей от demo-полки.
final class WorldScene: RenderScene {
    let config: WorldConfig

    private(set) var hudLine: String?

    private let terrainSystem: WorldTerrainSystem
    private var waterSystem: WorldWaterSystem?
    private var foliageSystem: WorldFoliageSystem?
    private var showcaseSystem: WorldShowcaseSystem?

    private var opaqueDepthState: MTLDepthStencilState?

    init(config: WorldConfig = .default) {
        self.config = config
        terrainSystem = WorldTerrainSystem(worldID: config.worldID, heightmapRevision: config.heightmapRevision, config: config.terrain)
        self.hudLine = "World: terrain + birch forest + water"
    }

    func buildIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        environment: EnvironmentMap
    ) {
        if opaqueDepthState == nil {
            let ds = MTLDepthStencilDescriptor()
            ds.depthCompareFunction = .less
            ds.isDepthWriteEnabled = true
            opaqueDepthState = device.makeDepthStencilState(descriptor: ds)
        }

        terrainSystem.buildIfNeeded(device: device, library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat)
        guard let terrainSampler = terrainSystem.sampler else { return }
        if waterSystem == nil {
            waterSystem = WorldWaterSystem(lake: config.lake, puddles: config.puddles, terrain: terrainSampler)
        }
        if foliageSystem == nil {
            foliageSystem = WorldFoliageSystem(terrain: terrainSampler, birchAssetName: config.foliage.birchAssetName)
        }
        if showcaseSystem == nil {
            showcaseSystem = WorldShowcaseSystem(terrain: terrainSampler)
        }
        waterSystem?.buildIfNeeded(device: device, library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat)
        foliageSystem?.buildIfNeeded(device: device, library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat, environment: environment)
        showcaseSystem?.buildIfNeeded(device: device, library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat, environment: environment)

        if let line = showcaseSystem?.hudLine {
            self.hudLine = "World: terrain + birch forest + water · \(line)"
        }
    }

    func shadowWorldBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let t = terrainSystem.terrain else { return nil }
        var wmin = t.worldBounds.min
        var wmax = t.worldBounds.max
        if let b = foliageSystem?.shadowWorldBounds() {
            wmin = simd_min(wmin, b.min)
            wmax = simd_max(wmax, b.max)
        }
        return (min: wmin, max: wmax)
    }

    func drawShadowCasters(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4, time: Float) {
        foliageSystem?.drawShadowCasters(encoder: encoder, lightViewProj: lightViewProj)
        showcaseSystem?.drawShadowCasters(encoder: encoder, lightViewProj: lightViewProj, time: time)
    }

    func effectsAnchor(time: Float) -> (showcaseFocal: SIMD3<Float>, effectsAnchor: SIMD3<Float>) {
        let y0 = terrainSystem.sampler?.height(x: 6, z: -8) ?? 0
        // Move effects farther by +Z so they don't overlap foxes / showcase rigs.
        let showcase = SIMD3<Float>(0, max(1.5, y0 + 2.2), 34)
        let anchor = SIMD3<Float>(10, max(2.0, y0 + 6.5), 28)
        return (showcase, anchor)
    }

    func draw(
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
        depthTexture: MTLTexture?,
        drawableSize: CGSize
    ) {
        terrainSystem.draw(
            encoder: encoder,
            viewProj: viewProj,
            cameraPos: cameraPos,
            lightViewProj: lightViewProj,
            keyLight: keyLight,
            shadowTexture: shadowTexture,
            shadowSampler: shadowSampler,
            time: time
        )

        waterSystem?.draw(
            encoder: encoder,
            viewProj: viewProj,
            cameraPos: cameraPos,
            time: time,
            keyLight: keyLight,
            depthTexture: depthTexture,
            environment: environment,
            drawableSize: drawableSize
        )

        // Water is blended and disables depth writes. Restore opaque depth + raster state before drawing opaque meshes.
        if let ods = opaqueDepthState {
            encoder.setDepthStencilState(ods)
        }
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        foliageSystem?.draw(
            encoder: encoder,
            viewProj: viewProj,
            cameraPos: cameraPos,
            lightViewProj: lightViewProj,
            time: time,
            keyLight: keyLight,
            shadowTexture: shadowTexture,
            shadowSampler: shadowSampler
        )

        if let ods = opaqueDepthState {
            encoder.setDepthStencilState(ods)
        }
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        showcaseSystem?.draw(
            encoder: encoder,
            viewProj: viewProj,
            cameraPos: cameraPos,
            lightViewProj: lightViewProj,
            time: time,
            keyLight: keyLight,
            shadowTexture: shadowTexture,
            shadowSampler: shadowSampler
        )
    }
}

