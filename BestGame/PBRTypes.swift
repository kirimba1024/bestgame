import simd

/// Shared CPU-side types that must match `MetalShaders/ShaderShared.h` (`PBRUniforms` и др.).
/// Keep these structs centralized to avoid subtle layout drift.
enum PBRTypes {
    /// Must match `PBRUniforms` in `MetalShaders/ShaderShared.h` byte-for-byte.
    struct Uniforms {
        var mvp: simd_float4x4
        var model: simd_float4x4
        var normalMatrix: simd_float4x4
        var lightViewProj: simd_float4x4
        var cameraPosWS: SIMD3<Float>
        var jointCount: UInt32
        var baseColorFactor: SIMD4<Float>
        var metallicFactor: Float
        var roughnessFactor: Float
        var exposure: Float
        var debugMode: UInt32 = 0
        var _pad: SIMD3<Float> = .zero

        init(
            mvp: simd_float4x4,
            model: simd_float4x4,
            normalMatrix: simd_float4x4,
            lightViewProj: simd_float4x4,
            cameraPosWS: SIMD3<Float>,
            jointCount: UInt32,
            baseColorFactor: SIMD4<Float>,
            metallicFactor: Float,
            roughnessFactor: Float,
            exposure: Float = 1.0,
            debugMode: UInt32 = 0
        ) {
            self.mvp = mvp
            self.model = model
            self.normalMatrix = normalMatrix
            self.lightViewProj = lightViewProj
            self.cameraPosWS = cameraPosWS
            self.jointCount = jointCount
            self.baseColorFactor = baseColorFactor
            self.metallicFactor = metallicFactor
            self.roughnessFactor = roughnessFactor
            self.exposure = exposure
            self.debugMode = debugMode
        }
    }
}

