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
        guard uri.hasPrefix("data:") else { return nil }
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let meta = String(uri[..<comma])
        let payload = String(uri[uri.index(after: comma)...])
        let isBase64 = meta.lowercased().contains(";base64")
        guard isBase64 else {
            return nil
        }
        return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }

    /// Ищет файл текстуры в бандле: корень, `Models/`, `Assets/Models/` и варианты расширения.
    private static func loadBundledURI(_ uri: String, bundle: Bundle) -> Data? {
        let path = uri.split(separator: "?").first.map(String.init) ?? uri
        let filename = (path as NSString).lastPathComponent
        let baseName = (filename as NSString).deletingPathExtension
        let extFromFile = ((filename as NSString).pathExtension).lowercased()

        let extCandidates: [String]
        if extFromFile.isEmpty {
            extCandidates = ["png", "jpg", "jpeg", "webp"]
        } else {
            extCandidates = [extFromFile]
        }

        let subdirs: [String?] = [nil, "Models", "Assets/Models"]

        for sub in subdirs {
            for ext in extCandidates {
                if let url = bundle.url(forResource: baseName, withExtension: ext, subdirectory: sub),
                   let data = try? Data(contentsOf: url), !data.isEmpty {
                    return data
                }
            }
        }

        if !extFromFile.isEmpty, let url = bundle.url(forResource: filename, withExtension: nil),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            return data
        }

        if let resourcePath = bundle.resourcePath {
            for sub in ["", "Models", "Assets/Models"] {
                let dir = sub.isEmpty ? resourcePath : (resourcePath as NSString).appendingPathComponent(sub)
                for ext in extCandidates {
                    let full = (dir as NSString).appendingPathComponent("\(baseName).\(ext)")
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: full)), !data.isEmpty {
                        return data
                    }
                }
            }
        }

        return nil
    }
}
