import Foundation

// Decodable glTF 2.0 JSON schema (minimal subset for our runtime).
// Keep this file "dumb": only data shapes, no parsing logic.
struct GLTF: Decodable {
    struct Buffer: Decodable { var byteLength: Int }

    struct BufferView: Decodable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
    }

    struct Accessor: Decodable {
        struct Sparse: Decodable {
            struct Indices: Decodable {
                var bufferView: Int
                var byteOffset: Int?
                var componentType: Int
            }
            struct Values: Decodable {
                var bufferView: Int
                var byteOffset: Int?
            }
            var count: Int
            var indices: Indices
            var values: Values
        }

        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var count: Int
        var type: String
        var normalized: Bool?
        var sparse: Sparse?
    }

    struct Primitive: Decodable {
        var attributes: [String: Int]
        var indices: Int?
        var material: Int?
        var mode: Int?
    }

    struct Mesh: Decodable {
        var primitives: [Primitive]
    }

    struct Node: Decodable {
        var mesh: Int?
        var skin: Int?
        var children: [Int]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
        var matrix: [Float]?
    }

    struct Scene: Decodable {
        var nodes: [Int]?
    }

    struct Skin: Decodable {
        var inverseBindMatrices: Int?
        var joints: [Int]
        var skeleton: Int?
    }

    struct Animation: Decodable {
        var name: String?
        struct Sampler: Decodable {
            var input: Int
            var output: Int
            var interpolation: String?
        }
        struct Channel: Decodable {
            struct Target: Decodable {
                var node: Int?
                var path: String
            }
            var sampler: Int
            var target: Target
        }
        var samplers: [Sampler]
        var channels: [Channel]
    }

    struct Texture: Decodable {
        var sampler: Int?
        var source: Int?
    }

    struct Image: Decodable {
        var uri: String?
        var bufferView: Int?
        var mimeType: String?
    }

    struct Material: Decodable {
        struct PBR: Decodable {
            struct TextureInfo: Decodable { var index: Int }
            var baseColorTexture: TextureInfo?
            var metallicRoughnessTexture: TextureInfo?
            var baseColorFactor: [Float]?
            var metallicFactor: Float?
            var roughnessFactor: Float?
        }
        var pbrMetallicRoughness: PBR?
    }

    var buffers: [Buffer]
    var bufferViews: [BufferView]
    var accessors: [Accessor]
    var meshes: [Mesh]
    var nodes: [Node]?
    var scenes: [Scene]?
    var scene: Int?
    var skins: [Skin]?
    var animations: [Animation]?
    var textures: [Texture]?
    var images: [Image]?
    var materials: [Material]?
}

