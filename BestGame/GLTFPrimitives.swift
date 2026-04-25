import Foundation
import simd

enum GLTFPrimitives {
    struct StaticPrimitiveData {
        var vertices: [GLBStaticVertex]
        var indices: [UInt32]
        var material: GLBPBRMaterialMR
        var sanitizeReport: GLTFSanitize.Report
    }

    static func decodeStaticPrimitive(gltf: GLTF, prim: GLTF.Primitive, bin: Data) throws -> StaticPrimitiveData {
        // TRIANGLES only (default is TRIANGLES when omitted).
        if let mode = prim.mode, mode != 4 {
            throw GLBLoaderError.unsupported("Primitive mode \(mode) not supported (only TRIANGLES=4)")
        }
        guard let posAcc = prim.attributes["POSITION"] else {
            throw GLBLoaderError.missing("POSITION attribute not found")
        }

        var report = GLTFSanitize.Report()
        let positionsRaw = try GLTFAccessors.readVec3Float(gltf: gltf, accessorIndex: posAcc, bin: bin)
        let positions = GLTFSanitize.sanitizePositions(positionsRaw, report: &report)
        guard !positions.isEmpty else {
            throw GLBLoaderError.missing("POSITION accessor is empty")
        }

        var normals: [SIMD3<Float>]
        if let norAcc = prim.attributes["NORMAL"] {
            let nRaw = try GLTFAccessors.readVec3Normalized(gltf: gltf, accessorIndex: norAcc, bin: bin)
            guard nRaw.count == positions.count else {
                throw GLBLoaderError.invalidChunk
            }
            normals = GLTFSanitize.sanitizeNormals(nRaw, report: &report)
        } else {
            normals = Array(repeating: SIMD3<Float>(0, 0, 0), count: positions.count)
        }

        var uvs: [SIMD2<Float>]
        if let uvAcc = prim.attributes["TEXCOORD_0"] {
            let uvRaw = try GLTFAccessors.readVec2Float(gltf: gltf, accessorIndex: uvAcc, bin: bin)
            guard uvRaw.count == positions.count else {
                throw GLBLoaderError.invalidChunk
            }
            uvs = GLTFSanitize.sanitizeUVs(uvRaw, report: &report)
        } else {
            uvs = Array(repeating: SIMD2<Float>(0, 0), count: positions.count)
        }

        var indices: [UInt32]
        if let idxAccessorIndex = prim.indices {
            indices = try GLTFAccessors.readIndices(gltf: gltf, accessorIndex: idxAccessorIndex, bin: bin)
        } else {
            indices = (0..<positions.count).map { UInt32($0) }
        }
        indices = GLTFSanitize.sanitizeTriangleIndices(indices, vertexCount: positions.count, report: &report)
        indices = GLTFSanitize.dropDegenerateTriangles(indices, positions: positions, report: &report)
        guard !indices.isEmpty else { throw GLBLoaderError.invalidChunk }

        if prim.attributes["NORMAL"] == nil {
            normals = GLTFSanitize.computeNormals(positions: positions, indices: indices)
        }

        var verts: [GLBStaticVertex] = []
        verts.reserveCapacity(positions.count)
        for i in 0..<positions.count {
            verts.append(.init(position: positions[i], normal: normals[i], uv: uvs[i]))
        }

        let mat = try GLTFMaterials.extractPBRMaterialMR(gltf: gltf, primitive: prim, bin: bin, bundle: .main)
        return StaticPrimitiveData(vertices: verts, indices: indices, material: mat, sanitizeReport: report)
    }
}

