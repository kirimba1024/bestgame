import Foundation
import simd

struct GLBStaticMesh {
    var positions: [SIMD3<Float>]
    var indices: [UInt32]
}

struct GLBPBRMaterialMR {
    var baseColorFactor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var metallicFactor: Float = 1
    var roughnessFactor: Float = 1
    var baseColorImageData: Data?
    var metallicRoughnessImageData: Data?
}

struct GLBStaticVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
}

struct GLBStaticPrimitive {
    var vertices: [GLBStaticVertex]
    var indices: [UInt32]
    var material: GLBPBRMaterialMR
}

struct GLBStaticModel {
    var primitives: [GLBStaticPrimitive]
}

struct GLBSkinnedVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
    var joints: SIMD4<UInt16>
    var weights: SIMD4<Float>
}

struct GLBNodeTRS {
    var t: SIMD3<Float> = .zero
    var r: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var s: SIMD3<Float> = SIMD3<Float>(repeating: 1)
}

struct GLBAnimation {
    struct TrackVec3 {
        var times: [Float]
        var values: [SIMD3<Float>]
        /// `true` = glTF `STEP`, `false` = `LINEAR`.
        var step: Bool = false
    }
    struct TrackQuat {
        var times: [Float]
        var values: [simd_quatf]
        var step: Bool = false
    }

    // nodeIndex -> track
    var translations: [Int: TrackVec3] = [:]
    var scales: [Int: TrackVec3] = [:]
    var rotations: [Int: TrackQuat] = [:]
    var duration: Float
}

struct GLBSkinnedModel {
    // Asset data
    var vertices: [GLBSkinnedVertex]
    var indices: [UInt32]

    // Skin
    var jointNodes: [Int]
    var inverseBindMatrices: [simd_float4x4]

    // Scene graph
    var rootNode: Int
    var meshNodeIndex: Int
    var nodeLocalTRS: [GLBNodeTRS]
    var parentIndex: [Int?]

    /// Все распознанные клипы (пусто — только поза из glTF).
    var animations: [GLBAnimation]

    // Material (baseColor only MVP)
    var material: GLBPBRMaterialMR
}

