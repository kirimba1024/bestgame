import Metal
import MetalKit
import simd

final class WorldFoliageSystem {
    private let terrain: TerrainSampler
    let proceduralTreesEnabled: Bool
    let proceduralTreeMaxInstances: Int

    private var grass: GrassInstancedRenderer?
    private var trees: ProceduralTreeRenderer?
    private(set) var hudLine: String?

    init(terrain: TerrainSampler, proceduralTreesEnabled: Bool, proceduralTreeMaxInstances: Int) {
        self.terrain = terrain
        self.proceduralTreesEnabled = proceduralTreesEnabled
        self.proceduralTreeMaxInstances = proceduralTreeMaxInstances
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

        if proceduralTreesEnabled {
            if trees == nil {
                trees = ProceduralTreeRenderer(device: device)
            }
            trees?.buildIfNeeded(library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat)
            trees?.ensureInstancesOnTerrain(terrain: terrain, maxInstances: proceduralTreeMaxInstances)
            hudLine = "Trees: procedural (\(proceduralTreeMaxInstances))"
        } else {
            hudLine = "Trees: disabled"
        }
    }

    func shadowWorldBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        trees?.worldBounds
    }

    func drawShadowCasters(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4) {
        trees?.drawShadow(encoder: encoder, lightViewProj: lightViewProj)
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
        if let trees {
            trees.setLightViewProjForNextDraw(lightViewProj, encoder: encoder)
            trees.draw(
            encoder: encoder,
            viewProj: viewProj,
            cameraPos: cameraPos,
            time: time,
            keyLight: keyLight,
            shadowTexture: shadowTexture,
            shadowSampler: shadowSampler
            )
        }
    }
}

