import simd

protocol TerrainSampler: AnyObject {
    var config: TerrainRenderer.Config { get }
    func height(x: Float, z: Float) -> Float
    func normal(x: Float, z: Float, step: Float) -> SIMD3<Float>
}

