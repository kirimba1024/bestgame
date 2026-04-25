import Foundation
import simd

enum GLBLoaderError: Error {
    case invalidHeader
    case invalidChunk
    case unsupported(String)
    case missing(String)
}

final class GLBLoader {
    static func staticMeshCount(named resourceName: String, in bundle: Bundle = .main) throws -> Int {
        let url =
            bundle.url(forResource: resourceName, withExtension: "glb")
            ?? bundle.url(forResource: resourceName, withExtension: nil)
        guard let url else {
            throw GLBLoaderError.missing("Bundle resource \(resourceName)(.glb) not found")
        }
        let data = try Data(contentsOf: url)
        let (jsonChunk, _) = try GLBBinary.parseContainer(data)
        let gltf = try JSONDecoder().decode(GLTF.self, from: jsonChunk)
        return gltf.meshes.count
    }
    static func loadStaticMesh(named resourceName: String, in bundle: Bundle = .main) throws -> GLBStaticMesh {
        // Xcode can import the file as "Fox" (no extension) depending on settings.
        let url =
            bundle.url(forResource: resourceName, withExtension: "glb")
            ?? bundle.url(forResource: resourceName, withExtension: nil)

        guard let url else {
            throw GLBLoaderError.missing("Bundle resource \(resourceName)(.glb) not found")
        }
        let data = try Data(contentsOf: url)
        return try parseGLB(data: data)
    }

    static func loadSkinnedModel(named resourceName: String, in bundle: Bundle = .main) throws -> GLBSkinnedModel {
        let url =
            bundle.url(forResource: resourceName, withExtension: "glb")
            ?? bundle.url(forResource: resourceName, withExtension: nil)

        guard let url else {
            throw GLBLoaderError.missing("Bundle resource \(resourceName)(.glb) not found")
        }
        let data = try Data(contentsOf: url)
        return try parseGLBSkinned(data: data)
    }

    // MARK: - GLB parsing

    private static func parseGLB(data: Data) throws -> GLBStaticMesh {
        let (jsonChunk, binChunk) = try GLBBinary.parseContainer(data)
        let gltf = try JSONDecoder().decode(GLTF.self, from: jsonChunk)
        // For MVP: take first mesh / first primitive.
        guard let mesh0 = gltf.meshes.first, let prim0 = mesh0.primitives.first else {
            throw GLBLoaderError.missing("No meshes/primitives found")
        }
        guard let posAccessorIndex = prim0.attributes["POSITION"] else {
            throw GLBLoaderError.missing("POSITION attribute not found")
        }
        let positions = try GLTFAccessors.readVec3Float(gltf: gltf, accessorIndex: posAccessorIndex, bin: binChunk)

        let indices: [UInt32]
        if let idxAccessorIndex = prim0.indices {
            indices = try GLTFAccessors.readIndices(gltf: gltf, accessorIndex: idxAccessorIndex, bin: binChunk)
        } else {
            // Non-indexed primitive: generate 0..count-1
            indices = (0..<positions.count).map { UInt32($0) }
        }

        return GLBStaticMesh(positions: positions, indices: indices)
    }

    static func loadStaticModel(named resourceName: String, in bundle: Bundle = .main) throws -> GLBStaticModel {
        return try loadStaticModel(named: resourceName, meshIndex: 0, in: bundle)
    }

    static func loadStaticModel(named resourceName: String, meshIndex: Int, in bundle: Bundle = .main) throws -> GLBStaticModel {
        let (m, _) = try loadStaticModelWithReport(named: resourceName, meshIndex: meshIndex, in: bundle)
        return m
    }

    static func loadStaticModelWithReport(named resourceName: String, meshIndex: Int, in bundle: Bundle = .main) throws -> (model: GLBStaticModel, report: GLTFSanitize.Report) {
        let url =
            bundle.url(forResource: resourceName, withExtension: "glb")
            ?? bundle.url(forResource: resourceName, withExtension: nil)

        guard let url else {
            throw GLBLoaderError.missing("Bundle resource \(resourceName)(.glb) not found")
        }
        let data = try Data(contentsOf: url)
        return try parseGLBStaticModelWithReport(data: data, meshIndex: meshIndex)
    }

    private static func parseGLBStaticModelWithReport(data: Data, meshIndex: Int) throws -> (model: GLBStaticModel, report: GLTFSanitize.Report) {
        let (jsonChunk, binChunk) = try GLBBinary.parseContainer(data)
        let gltf = try JSONDecoder().decode(GLTF.self, from: jsonChunk)

        // Load all suitable TRIANGLES primitives from the selected mesh.
        // glTF commonly splits a mesh into multiple primitives (materials, attribute sets).
        guard !gltf.meshes.isEmpty else {
            throw GLBLoaderError.missing("No meshes found")
        }
        let mi = max(0, min(meshIndex, gltf.meshes.count - 1))
        let mesh0 = gltf.meshes[mi]

        var prims: [GLBStaticPrimitive] = []
        prims.reserveCapacity(mesh0.primitives.count)
        var total = GLTFSanitize.Report()

        for prim in mesh0.primitives {
            // If any primitive decode fails, skip it (we're building a best-effort static model).
            guard let decoded = try? GLTFPrimitives.decodeStaticPrimitive(gltf: gltf, prim: prim, bin: binChunk) else { continue }
            prims.append(GLBStaticPrimitive(vertices: decoded.vertices, indices: decoded.indices, material: decoded.material))
            total.add(decoded.sanitizeReport)
        }

        if prims.isEmpty {
            throw GLBLoaderError.missing("No suitable primitives found for static model")
        }

        return (GLBStaticModel(primitives: prims), total)
    }

    private static func parseGLBSkinned(data: Data) throws -> GLBSkinnedModel {
        let (gltf, bin) = try parseGLBContainer(data: data)

        guard let nodes = gltf.nodes, let sceneIndex = (gltf.scene ?? 0) as Int?, let scenes = gltf.scenes, sceneIndex < scenes.count else {
            throw GLBLoaderError.missing("Missing scene/nodes")
        }
        let rootNode = scenes[sceneIndex].nodes?.first ?? 0

        // Build parent array from hierarchy.
        var parent: [Int?] = Array(repeating: nil, count: nodes.count)
        for (i, n) in nodes.enumerated() {
            for c in (n.children ?? []) {
                if c >= 0 && c < parent.count { parent[c] = i }
            }
        }

        // Build default local TRS.
        let nodeTRS: [GLBNodeTRS] = nodes.map { n in
            var trs = GLBNodeTRS()
            if let t = n.translation, t.count == 3 {
                trs.t = SIMD3<Float>(t[0], t[1], t[2])
            }
            if let s = n.scale, s.count == 3 {
                trs.s = SIMD3<Float>(s[0], s[1], s[2])
            }
            if let r = n.rotation, r.count == 4 {
                // glTF quat is [x,y,z,w]
                trs.r = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            }
            // If matrix is present we ignore for MVP (Fox uses TRS).
            return trs
        }

        // Find a node that references a mesh.
        var meshNodeIndex: Int?
        for (i, n) in nodes.enumerated() {
            if n.mesh != nil {
                meshNodeIndex = i
                break
            }
        }
        guard let meshNodeIndex else { throw GLBLoaderError.missing("No mesh node found") }
        let meshIndex = nodes[meshNodeIndex].mesh!
        guard meshIndex < gltf.meshes.count else { throw GLBLoaderError.invalidChunk }
        guard let prim0 = gltf.meshes[meshIndex].primitives.first else { throw GLBLoaderError.missing("No primitives") }

        // Attributes we need.
        guard let posAcc = prim0.attributes["POSITION"] else { throw GLBLoaderError.missing("POSITION missing") }
        let norAcc = prim0.attributes["NORMAL"]
        let uvAcc = prim0.attributes["TEXCOORD_0"]
        let jointsAcc = prim0.attributes["JOINTS_0"]
        let weightsAcc = prim0.attributes["WEIGHTS_0"]

        let positions = try GLTFAccessors.readVec3Float(gltf: gltf, accessorIndex: posAcc, bin: bin)
        let normals = try (norAcc != nil ? GLTFAccessors.readVec3Normalized(gltf: gltf, accessorIndex: norAcc!, bin: bin) : Array(repeating: SIMD3<Float>(0, 1, 0), count: positions.count))
        let uvs = try (uvAcc != nil ? GLTFAccessors.readVec2Float(gltf: gltf, accessorIndex: uvAcc!, bin: bin) : Array(repeating: SIMD2<Float>(0, 0), count: positions.count))
        let joints = try (jointsAcc != nil ? GLTFAccessors.readVec4U16(gltf: gltf, accessorIndex: jointsAcc!, bin: bin) : Array(repeating: SIMD4<UInt16>(0, 0, 0, 0), count: positions.count))
        var weights = try (weightsAcc != nil ? GLTFAccessors.readVec4Float(gltf: gltf, accessorIndex: weightsAcc!, bin: bin) : Array(repeating: SIMD4<Float>(1, 0, 0, 0), count: positions.count))
        // Defensive: all vertex attribute arrays must match vertex count.
        guard
            !positions.isEmpty,
            normals.count == positions.count,
            uvs.count == positions.count,
            joints.count == positions.count,
            weights.count == positions.count
        else {
            throw GLBLoaderError.invalidChunk
        }
        // Ensure weights are normalized (defensive; glTF expects normalized weights).
        weights = weights.map { w in
            let s = max(1e-8, w.x + w.y + w.z + w.w)
            return w / s
        }

        let vertexCount = positions.count
        var verts: [GLBSkinnedVertex] = []
        verts.reserveCapacity(vertexCount)
        for i in 0..<vertexCount {
            verts.append(.init(position: positions[i], normal: normals[i], uv: uvs[i], joints: joints[i], weights: weights[i]))
        }

        // Indices
        let indices: [UInt32]
        if let idxAccessorIndex = prim0.indices {
            indices = try GLTFAccessors.readIndices(gltf: gltf, accessorIndex: idxAccessorIndex, bin: bin)
        } else {
            indices = (0..<vertexCount).map { UInt32($0) }
        }

        // Skin
        guard let skins = gltf.skins, !skins.isEmpty else {
            throw GLBLoaderError.missing("No skins in model")
        }
        let skinIndex = nodes[meshNodeIndex].skin ?? 0
        guard skinIndex < skins.count else { throw GLBLoaderError.invalidChunk }
        let skin = skins[skinIndex]
        let jointNodes = skin.joints
        // Defensive: joint indices must be valid node indices.
        guard jointNodes.allSatisfy({ $0 >= 0 && $0 < nodes.count }) else { throw GLBLoaderError.invalidChunk }
        let invBind: [simd_float4x4]
        if let invAcc = skin.inverseBindMatrices {
            invBind = try GLTFAccessors.readMat4Float(gltf: gltf, accessorIndex: invAcc, bin: bin)
        } else {
            invBind = Array(repeating: matrix_identity_float4x4, count: jointNodes.count)
        }
        guard invBind.count == jointNodes.count else { throw GLBLoaderError.invalidChunk }

        // Vertex joint indices must refer to palette entries [0, jointCount).
        let jointPalette = jointNodes.count
        guard jointPalette > 0 else { throw GLBLoaderError.invalidChunk }
        for jw in joints {
            if Int(jw.x) >= jointPalette || Int(jw.y) >= jointPalette || Int(jw.z) >= jointPalette || Int(jw.w) >= jointPalette {
                throw GLBLoaderError.invalidChunk
            }
        }

        var animations = (try? GLTFAnimationParser.parseAllAnimations(gltf: gltf, bin: bin)) ?? []
        if animations.isEmpty, let one = try? GLTFAnimationParser.parseFirstAnimation(gltf: gltf, bin: bin) {
            animations = [one]
        }

        let material = try GLTFMaterials.extractPBRMaterialMR(gltf: gltf, primitive: prim0, bin: bin, bundle: .main)

        return GLBSkinnedModel(
            vertices: verts,
            indices: indices,
            jointNodes: jointNodes,
            inverseBindMatrices: invBind,
            rootNode: rootNode,
            meshNodeIndex: meshNodeIndex,
            nodeLocalTRS: nodeTRS,
            parentIndex: parent,
            animations: animations,
            material: material
        )
    }

    private static func parseGLBContainer(data: Data) throws -> (GLTF, Data) {
        let (jsonChunk, binChunk) = try GLBBinary.parseContainer(data)
        let gltf = try JSONDecoder().decode(GLTF.self, from: jsonChunk)
        return (gltf, binChunk)
    }

    // Animation/material parsing moved to GLTFAnimation.swift / GLTFMaterials.swift

    // Accessor readers moved to GLTFAccessors.swift

    // Binary helpers moved to GLBBinary.swift
}

