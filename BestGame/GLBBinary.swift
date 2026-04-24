import Foundation

enum GLBBinary {
    /// Centralized bounds check for all primitive reads from `Data`.
    static func ensureReadable(_ data: Data, offset: Int, byteCount: Int) throws {
        guard offset >= 0, byteCount >= 0, offset + byteCount <= data.count else {
            throw GLBLoaderError.invalidChunk
        }
    }

    // GLB header: magic 'glTF' (0x46546C67), version (u32), length (u32)
    static func parseContainer(_ data: Data) throws -> (gltfJSON: Data, bin: Data) {
        guard data.count >= 12 else { throw GLBLoaderError.invalidHeader }
        let magic = try readU32(data, 0)
        guard magic == 0x4654_6C67 else { throw GLBLoaderError.invalidHeader }
        let version = try readU32(data, 4)
        guard version == 2 else { throw GLBLoaderError.unsupported("Only GLB v2 is supported") }
        let totalLength = Int(try readU32(data, 8))
        guard totalLength <= data.count else { throw GLBLoaderError.invalidHeader }

        var offset = 12
        var jsonChunk: Data?
        var binChunk: Data?

        while offset + 8 <= totalLength {
            let chunkLength = Int(try readU32(data, offset))
            let chunkType = try readU32(data, offset + 4)
            offset += 8
            guard offset + chunkLength <= totalLength else { throw GLBLoaderError.invalidChunk }
            let chunkData = data.subdata(in: offset..<(offset + chunkLength))
            offset += chunkLength

            // JSON: 0x4E4F534A, BIN: 0x004E4942
            if chunkType == 0x4E4F_534A {
                jsonChunk = chunkData
            } else if chunkType == 0x004E_4942 {
                binChunk = chunkData
            }
        }

        guard let jsonChunk, let binChunk else {
            throw GLBLoaderError.missing("GLB must contain JSON and BIN chunks")
        }
        return (jsonChunk, binChunk)
    }

    static func readU16(_ data: Data, _ offset: Int) throws -> UInt16 {
        try ensureReadable(data, offset: offset, byteCount: 2)
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1]) << 8
        return b0 | b1
    }

    static func readU32(_ data: Data, _ offset: Int) throws -> UInt32 {
        try ensureReadable(data, offset: offset, byteCount: 4)
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    static func readF32(_ data: Data, _ offset: Int) throws -> Float {
        let u = try readU32(data, offset)
        return Float(bitPattern: u)
    }
}

