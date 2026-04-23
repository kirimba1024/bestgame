import simd

/// Shared CPU-side types that must match `Shaders.metal`.
/// Keep these structs centralized to avoid subtle layout drift.
enum PBRTypes {
    /// Must match `PBRUniforms` in `Shaders.metal` byte-for-byte.
    struct Uniforms {
        var mvp: simd_float4x4
        var model: simd_float4x4
        var cameraPosWS: SIMD3<Float>
        var jointCount: UInt32
        var baseColorFactor: SIMD4<Float>
        var metallicFactor: Float
        var roughnessFactor: Float
        var _pad: SIMD2<Float> = .zero

        init(
            mvp: simd_float4x4,
            model: simd_float4x4,
            cameraPosWS: SIMD3<Float>,
            jointCount: UInt32,
            baseColorFactor: SIMD4<Float>,
            metallicFactor: Float,
            roughnessFactor: Float
        ) {
            self.mvp = mvp
            self.model = model
            self.cameraPosWS = cameraPosWS
            self.jointCount = jointCount
            self.baseColorFactor = baseColorFactor
            self.metallicFactor = metallicFactor
            self.roughnessFactor = roughnessFactor
        }
    }
}

