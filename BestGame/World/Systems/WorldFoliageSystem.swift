import Metal
import MetalKit
import simd

final class WorldFoliageSystem {
    private let terrain: TerrainSampler
    let birchAssetName: String

    private var grass: GrassInstancedRenderer?
    private var birchModel: StaticModelRenderer?
    private var birchForest: BirchForestRenderer?

    init(terrain: TerrainSampler, birchAssetName: String) {
        self.terrain = terrain
        self.birchAssetName = birchAssetName
    }

    func buildIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        environment: EnvironmentMap
    ) {
        if grass == nil {
            grass = GrassInstancedRenderer(device: device)
        }
        grass?.buildPipelineIfNeeded(library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat)

        if birchModel == nil {
            if let birch = try? GLBLoader.loadStaticModel(named: birchAssetName) {
                birchModel = StaticModelRenderer(
                    device: device,
                    library: library,
                    colorPixelFormat: colorPixelFormat,
                    depthPixelFormat: depthPixelFormat,
                    model: birch,
                    environment: environment
                )
            }
        }

        if birchForest == nil {
            birchForest = BirchForestRenderer(device: device, terrain: terrain)
        }
    }

    func shadowWorldBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        birchForest?.worldBounds
    }

    func drawShadowCasters(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4) {
        guard let birchModel, let forest = birchForest else { return }
        birchModel.drawShadowInstances(
            encoder: encoder,
            lightViewProj: lightViewProj,
            instanceModels: forest.instanceBuffer,
            instanceCount: forest.instanceCount
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
        grass?.ensureInstancesOnTerrain(terrain: terrain)
        grass?.draw(encoder: encoder, viewProj: viewProj, cameraPos: cameraPos, time: time, sunDirectionWS: keyLight.directionWS)

        guard let birchModel, let forest = birchForest else { return }
        birchModel.drawInstances(
            encoder: encoder,
            viewProj: viewProj,
            cameraPosWS: cameraPos,
            lightViewProj: lightViewProj,
            keyLight: keyLight,
            shadowTexture: shadowTexture,
            shadowSampler: shadowSampler,
            instanceModels: forest.instanceBuffer,
            instanceCount: forest.instanceCount,
            debugMode: 0
        )
    }
}

