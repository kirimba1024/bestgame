import Foundation

enum GLTFMaterials {
    static func extractPBRMaterialMR(gltf: GLTF, primitive: GLTF.Primitive, bin: Data) throws -> GLBPBRMaterialMR {
        guard
            let matIndex = primitive.material,
            let materials = gltf.materials,
            matIndex < materials.count
        else { return GLBPBRMaterialMR() }

        let pbr = materials[matIndex].pbrMetallicRoughness
        var out = GLBPBRMaterialMR()

        if let f = pbr?.baseColorFactor, f.count == 4 {
            out.baseColorFactor = SIMD4<Float>(f[0], f[1], f[2], f[3])
        }
        out.metallicFactor = pbr?.metallicFactor ?? 1
        out.roughnessFactor = pbr?.roughnessFactor ?? 1

        out.baseColorImageData = try imageDataForTextureIndex(gltf: gltf, textureIndex: pbr?.baseColorTexture?.index, bin: bin)
        out.metallicRoughnessImageData = try imageDataForTextureIndex(gltf: gltf, textureIndex: pbr?.metallicRoughnessTexture?.index, bin: bin)

        return out
    }

    private static func imageDataForTextureIndex(gltf: GLTF, textureIndex: Int?, bin: Data) throws -> Data? {
        guard
            let textureIndex,
            let textures = gltf.textures,
            textureIndex >= 0, textureIndex < textures.count
        else { return nil }

        guard
            let imgIndex = textures[textureIndex].source,
            let images = gltf.images,
            imgIndex >= 0, imgIndex < images.count
        else { return nil }

        let img = images[imgIndex]
        if let bvIndex = img.bufferView {
            return try GLTFAccessors.bufferViewData(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        }
        return nil
    }
}

