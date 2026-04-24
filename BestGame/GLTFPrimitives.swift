import Foundation
import simd

enum GLTFPrimitives {
    struct StaticPrimitiveData {
        var vertices: [GLBStaticVertex]
        var indices: [UInt32]
        var material: GLBPBRMaterialMR
    }

    static func decodeStaticPrimitive(gltf: GLTF, prim: GLTF.Primitive, bin: Data) throws -> StaticPrimitiveData {
        // TRIANGLES only (default is TRIANGLES when omitted).
        if let mode = prim.mode, mode != 4 {
            throw GLBLoaderError.unsupported("Primitive mode \(mode) not supported (only TRIANGLES=4)")
        }
        guard let posAcc = prim.attributes["POSITION"] else {
            throw GLBLoaderError.missing("POSITION attribute not found")
        }

        let positions = try GLTFAccessors.readVec3Float(gltf: gltf, accessorIndex: posAcc, bin: bin)
        guard !positions.isEmpty else {
            throw GLBLoaderError.missing("POSITION accessor is empty")
        }

        let normals: [SIMD3<Float>]
        if let norAcc = prim.attributes["NORMAL"] {
            normals = try GLTFAccessors.readVec3Normalized(gltf: gltf, accessorIndex: norAcc, bin: bin)
            guard normals.count == positions.count else {
                throw GLBLoaderError.invalidChunk
            }
        } else {
            normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: positions.count)
        }

        let uvs: [SIMD2<Float>]
        if let uvAcc = prim.attributes["TEXCOORD_0"] {
            uvs = try GLTFAccessors.readVec2Float(gltf: gltf, accessorIndex: uvAcc, bin: bin)
            guard uvs.count == positions.count else {
                throw GLBLoaderError.invalidChunk
            }
        } else {
            uvs = Array(repeating: SIMD2<Float>(0, 0), count: positions.count)
        }

        let indices: [UInt32]
        if let idxAccessorIndex = prim.indices {
            indices = try GLTFAccessors.readIndices(gltf: gltf, accessorIndex: idxAccessorIndex, bin: bin)
            guard indices.count % 3 == 0 else { throw GLBLoaderError.invalidChunk }
            if let maxIdx = indices.max(), maxIdx >= UInt32(positions.count) { throw GLBLoaderError.invalidChunk }
        } else {
            indices = (0..<positions.count).map { UInt32($0) }
        }

        var verts: [GLBStaticVertex] = []
        verts.reserveCapacity(positions.count)
        for i in 0..<positions.count {
            verts.append(.init(position: positions[i], normal: normals[i], uv: uvs[i]))
        }

        let mat = try GLTFMaterials.extractPBRMaterialMR(gltf: gltf, primitive: prim, bin: bin, bundle: .main)
        return StaticPrimitiveData(vertices: verts, indices: indices, material: mat)
    }
}

