import Metal
import MetalKit
import simd

final class WorldTerrainSystem {
    let worldID: String
    let heightmapRevision: Int
    let config: TerrainRenderer.Config
    private(set) var terrain: TerrainRenderer?
    private(set) var sampler: TerrainSampler?

    init(worldID: String, heightmapRevision: Int, config: TerrainRenderer.Config) {
        self.worldID = worldID
        self.heightmapRevision = heightmapRevision
        self.config = config
    }

    func buildIfNeeded(device: MTLDevice, library: MTLLibrary, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        if terrain == nil {
            let map = WorldHeightmapAsset.loadOrGenerate(
                worldID: "\(worldID)-v\(heightmapRevision)",
                config: config,
                generator: { x, z, cfg in ProceduralTerrainGenerator.height(x: x, z: z, cfg: cfg) }
            )
            let s = HeightmapTerrainSampler(config: config, map: map)
            self.sampler = s
            terrain = TerrainRenderer(device: device, config: config, sampler: s)
        }
        terrain?.buildIfNeeded(library: library, colorPixelFormat: colorPixelFormat, depthPixelFormat: depthPixelFormat)
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        cameraPos: SIMD3<Float>,
        lightViewProj: simd_float4x4,
        keyLight: SceneLighting.KeyLightFrame,
        shadowTexture: MTLTexture?,
        shadowSampler: MTLSamplerState?,
        time: Float
    ) {
        terrain?.draw(
            encoder: encoder,
            viewProj: viewProj,
            cameraPosWS: cameraPos,
            lightViewProj: lightViewProj,
            keyLight: keyLight,
            shadowTexture: shadowTexture,
            shadowSampler: shadowSampler,
            time: time
        )
    }
}

