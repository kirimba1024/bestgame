import Metal
import MetalKit
import simd

final class WorldWaterSystem {
    let lakeConfig: LakeWaterRenderer.Config
    let puddlesConfig: DepressionWaterRenderer.Config
    let terrainConfig: TerrainRenderer.Config
    private let terrain: TerrainSampler

    private var puddles: DepressionWaterRenderer?
    private var lake: LakeWaterRenderer?

    init(lake: LakeWaterRenderer.Config, puddles: DepressionWaterRenderer.Config, terrain: TerrainSampler) {
        self.lakeConfig = lake
        self.puddlesConfig = puddles
        self.terrainConfig = terrain.config
        self.terrain = terrain
    }

    func buildIfNeeded(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        if puddles == nil {
            puddles = DepressionWaterRenderer(device: device, terrain: terrain, config: puddlesConfig)
        }
        puddles?.buildPipelineIfNeeded(device: device, library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat)

        if lake == nil {
            lake = LakeWaterRenderer(device: device, config: lakeConfig)
        }
        lake?.buildPipelineIfNeeded(device: device, library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat)
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        cameraPos: SIMD3<Float>,
        time: Float,
        keyLight: SceneLighting.KeyLightFrame,
        depthTexture: MTLTexture?,
        environment: EnvironmentMap,
        drawableSize: CGSize
    ) {
        guard let depthTexture else { return }
        let w = Float(drawableSize.width)
        let h = Float(drawableSize.height)
        let key = SceneLighting.KeyLightGPUBytes(keyLight)

        puddles?.draw(
            encoder: encoder,
            viewProj: viewProj,
            cameraPos: cameraPos,
            time: time,
            sunDirectionWS: keyLight.directionWS,
            viewportWidth: w,
            viewportHeight: h,
            depthTexture: depthTexture,
            environmentTexture: environment.texture,
            environmentSampler: environment.sampler,
            keyLightBytes: key
        )

        lake?.draw(
            encoder: encoder,
            viewProj: viewProj,
            cameraPos: cameraPos,
            time: time,
            sunDirectionWS: keyLight.directionWS,
            viewportWidth: w,
            viewportHeight: h,
            depthTexture: depthTexture,
            environmentTexture: environment.texture,
            environmentSampler: environment.sampler,
            keyLightBytes: key
        )
    }
}

