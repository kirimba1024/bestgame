import Foundation

enum GLTFMaterials {
    static func extractPBRMaterialMR(gltf: GLTF, primitive: GLTF.Primitive, bin: Data, bundle: Bundle = .main) throws -> GLBPBRMaterialMR {
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

        out.baseColorImageData = try imageDataForTextureIndex(gltf: gltf, textureIndex: pbr?.baseColorTexture?.index, bin: bin, bundle: bundle)
        out.metallicRoughnessImageData = try imageDataForTextureIndex(gltf: gltf, textureIndex: pbr?.metallicRoughnessTexture?.index, bin: bin, bundle: bundle)

        return out
    }

    private static func imageDataForTextureIndex(gltf: GLTF, textureIndex: Int?, bin: Data, bundle: Bundle) throws -> Data? {
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
        if let uri = img.uri, !uri.isEmpty {
            if let data = decodeDataURI(uri) { return data }
            if let data = loadBundledURI(uri, bundle: bundle) { return data }
        }
        return nil
    }

    private static func decodeDataURI(_ uri: String) -> Data? {
        // Example: data:image/png;base64,AAAA...
        guard uri.hasPrefix("data:") else { return nil }
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let meta = String(uri[..<comma])
        let payload = String(uri[uri.index(after: comma)...])
        let isBase64 = meta.lowercased().contains(";base64")
        guard isBase64 else {
            // Percent-encoded raw data. Rare for images; skip for now.
            return nil
        }
        return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }

    private static func loadBundledURI(_ uri: String, bundle: Bundle) -> Data? {
        // Common case: "textures/Albedo.png" or "Albedo.png".
        let path = uri.split(separator: "?").first.map(String.init) ?? uri
        let filename = (path as NSString).lastPathComponent
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        let url = ext.isEmpty
            ? bundle.url(forResource: filename, withExtension: nil) ?? bundle.url(forResource: name, withExtension: nil)
            : bundle.url(forResource: name, withExtension: ext)

        guard let url else { return nil }
        return try? Data(contentsOf: url)
    }
}

