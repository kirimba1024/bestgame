import Foundation
import simd

// Accessor readers: typed views over the BIN chunk.
// Keep pure and testable: no Metal here.
enum GLTFAccessors {
    @inline(__always)
    private static func rejectSparseIfPresent(_ acc: GLTF.Accessor) throws {
        // Sparse accessors are valid glTF, but we currently don't implement them.
        // Without this check we may silently read wrong data.
        if acc.sparse != nil {
            throw GLBLoaderError.unsupported("Sparse accessors are not supported")
        }
    }

    static func componentByteSize(_ componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1 // (u)byte
        case 5122, 5123: return 2 // (u)short
        case 5125, 5126: return 4 // uint / float
        default: return 0
        }
    }

    static func bufferViewSlice(gltf: GLTF, bufferViewIndex: Int, bin: Data) throws -> (base: Int, length: Int, stride: Int?) {
        guard bufferViewIndex >= 0 && bufferViewIndex < gltf.bufferViews.count else { throw GLBLoaderError.invalidChunk }
        let bv = gltf.bufferViews[bufferViewIndex]
        guard bv.buffer == 0 else { throw GLBLoaderError.unsupported("Only BIN buffer 0 supported") }
        let base = (bv.byteOffset ?? 0)
        guard base + bv.byteLength <= bin.count else { throw GLBLoaderError.invalidChunk }
        return (base, bv.byteLength, bv.byteStride)
    }

    static func bufferViewData(gltf: GLTF, bufferViewIndex: Int, bin: Data) throws -> Data {
        guard bufferViewIndex >= 0 && bufferViewIndex < gltf.bufferViews.count else { throw GLBLoaderError.invalidChunk }
        let bv = gltf.bufferViews[bufferViewIndex]
        guard bv.buffer == 0 else { throw GLBLoaderError.unsupported("Only BIN buffer 0 supported") }
        let base = (bv.byteOffset ?? 0)
        guard base + bv.byteLength <= bin.count else { throw GLBLoaderError.invalidChunk }
        return bin.subdata(in: base..<(base + bv.byteLength))
    }

    private static func readComponentAsFloat(_ bin: Data, _ offset: Int, componentType: Int, normalized: Bool) throws -> Float {
        switch componentType {
        case 5126: // FLOAT
            return try GLBBinary.readF32(bin, offset)
        case 5121: // UBYTE
            try GLBBinary.ensureReadable(bin, offset: offset, byteCount: 1)
            let v = Float(bin[offset])
            return normalized ? (v / 255.0) : v
        case 5123: // USHORT
            let v = Float(try GLBBinary.readU16(bin, offset))
            return normalized ? (v / 65535.0) : v
        case 5120: // BYTE (signed)
            try GLBBinary.ensureReadable(bin, offset: offset, byteCount: 1)
            let raw = Int8(bitPattern: bin[offset])
            let v = Float(raw)
            if !normalized { return v }
            // glTF normalized signed byte maps to [-1,1]
            return max(-1.0, v / 127.0)
        case 5122: // SHORT (signed)
            let raw = Int16(bitPattern: try GLBBinary.readU16(bin, offset))
            let v = Float(raw)
            if !normalized { return v }
            return max(-1.0, v / 32767.0)
        default:
            throw GLBLoaderError.unsupported("Unsupported componentType \(componentType)")
        }
    }

    static func readVec3Float(gltf: GLTF, accessorIndex: Int, bin: Data) throws -> [SIMD3<Float>] {
        guard accessorIndex >= 0 && accessorIndex < gltf.accessors.count else { throw GLBLoaderError.invalidChunk }
        let acc = gltf.accessors[accessorIndex]
        try rejectSparseIfPresent(acc)
        guard acc.type == "VEC3" else { throw GLBLoaderError.unsupported("Accessor type \(acc.type) for VEC3") }
        guard acc.componentType == 5126 else { throw GLBLoaderError.unsupported("VEC3 must be float32") }
        guard let bvIndex = acc.bufferView else { throw GLBLoaderError.missing("Accessor.bufferView missing") }
        let (base, bvLen, stride) = try bufferViewSlice(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        let byteOffset = (acc.byteOffset ?? 0)
        let elementStride = stride ?? (MemoryLayout<Float>.stride * 3)
        let elementSize = MemoryLayout<Float>.stride * 3
        if let stride, stride < elementSize { throw GLBLoaderError.invalidChunk }
        if acc.count > 0 {
            let last = byteOffset + (acc.count - 1) * elementStride + elementSize
            if last > bvLen { throw GLBLoaderError.invalidChunk }
        }

        var out: [SIMD3<Float>] = []
        out.reserveCapacity(acc.count)
        for i in 0..<acc.count {
            let o = base + byteOffset + i * elementStride
            let x = try GLBBinary.readF32(bin, o)
            let y = try GLBBinary.readF32(bin, o + 4)
            let z = try GLBBinary.readF32(bin, o + 8)
            out.append(SIMD3<Float>(x, y, z))
        }
        return out
    }

    /// Reads VEC3 as float. Supports FLOAT and normalized integer formats (common for NORMAL).
    static func readVec3Normalized(gltf: GLTF, accessorIndex: Int, bin: Data) throws -> [SIMD3<Float>] {
        guard accessorIndex >= 0 && accessorIndex < gltf.accessors.count else { throw GLBLoaderError.invalidChunk }
        let acc = gltf.accessors[accessorIndex]
        try rejectSparseIfPresent(acc)
        guard acc.type == "VEC3" else { throw GLBLoaderError.unsupported("Accessor type \(acc.type) for VEC3") }
        guard let bvIndex = acc.bufferView else { throw GLBLoaderError.missing("Accessor.bufferView missing") }
        let (base, bvLen, stride) = try bufferViewSlice(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        let byteOffset = (acc.byteOffset ?? 0)
        let elementStride = stride ?? (componentByteSize(acc.componentType) * 3)
        let elementSize = componentByteSize(acc.componentType) * 3
        if let stride, stride < elementSize { throw GLBLoaderError.invalidChunk }
        if acc.count > 0 {
            let last = byteOffset + (acc.count - 1) * elementStride + elementSize
            if last > bvLen { throw GLBLoaderError.invalidChunk }
        }

        let norm = (acc.normalized ?? false)
        let step = componentByteSize(acc.componentType)

        var out: [SIMD3<Float>] = []
        out.reserveCapacity(acc.count)
        for i in 0..<acc.count {
            let o = base + byteOffset + i * elementStride
            let x = try readComponentAsFloat(bin, o, componentType: acc.componentType, normalized: norm)
            let y = try readComponentAsFloat(bin, o + step, componentType: acc.componentType, normalized: norm)
            let z = try readComponentAsFloat(bin, o + step * 2, componentType: acc.componentType, normalized: norm)
            out.append(SIMD3<Float>(x, y, z))
        }
        return out
    }

    static func readVec2Float(gltf: GLTF, accessorIndex: Int, bin: Data) throws -> [SIMD2<Float>] {
        guard accessorIndex >= 0 && accessorIndex < gltf.accessors.count else { throw GLBLoaderError.invalidChunk }
        let acc = gltf.accessors[accessorIndex]
        try rejectSparseIfPresent(acc)
        guard acc.type == "VEC2" else { throw GLBLoaderError.unsupported("Accessor type \(acc.type) for VEC2") }
        guard let bvIndex = acc.bufferView else { throw GLBLoaderError.missing("Accessor.bufferView missing") }
        let (base, bvLen, stride) = try bufferViewSlice(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        let byteOffset = (acc.byteOffset ?? 0)
        let elementStride = stride ?? (componentByteSize(acc.componentType) * 2)
        let elementSize = componentByteSize(acc.componentType) * 2
        if let stride, stride < elementSize { throw GLBLoaderError.invalidChunk }
        if acc.count > 0 {
            let last = byteOffset + (acc.count - 1) * elementStride + elementSize
            if last > bvLen { throw GLBLoaderError.invalidChunk }
        }

        var out: [SIMD2<Float>] = []
        out.reserveCapacity(acc.count)
        for i in 0..<acc.count {
            let o = base + byteOffset + i * elementStride
            let norm = (acc.normalized ?? false)
            let step = componentByteSize(acc.componentType)
            let x = try readComponentAsFloat(bin, o, componentType: acc.componentType, normalized: norm)
            let y = try readComponentAsFloat(bin, o + step, componentType: acc.componentType, normalized: norm)
            out.append(SIMD2<Float>(x, y))
        }
        return out
    }

    static func readVec4Float(gltf: GLTF, accessorIndex: Int, bin: Data) throws -> [SIMD4<Float>] {
        guard accessorIndex >= 0 && accessorIndex < gltf.accessors.count else { throw GLBLoaderError.invalidChunk }
        let acc = gltf.accessors[accessorIndex]
        try rejectSparseIfPresent(acc)
        guard acc.type == "VEC4" else { throw GLBLoaderError.unsupported("Accessor type \(acc.type) for VEC4") }
        guard let bvIndex = acc.bufferView else { throw GLBLoaderError.missing("Accessor.bufferView missing") }
        let (base, bvLen, stride) = try bufferViewSlice(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        let byteOffset = (acc.byteOffset ?? 0)
        let elementStride = stride ?? (componentByteSize(acc.componentType) * 4)
        let elementSize = componentByteSize(acc.componentType) * 4
        if let stride, stride < elementSize { throw GLBLoaderError.invalidChunk }
        if acc.count > 0 {
            let last = byteOffset + (acc.count - 1) * elementStride + elementSize
            if last > bvLen { throw GLBLoaderError.invalidChunk }
        }

        var out: [SIMD4<Float>] = []
        out.reserveCapacity(acc.count)
        for i in 0..<acc.count {
            let o = base + byteOffset + i * elementStride
            let norm = (acc.normalized ?? false)
            let step = componentByteSize(acc.componentType)
            let x = try readComponentAsFloat(bin, o, componentType: acc.componentType, normalized: norm)
            let y = try readComponentAsFloat(bin, o + step, componentType: acc.componentType, normalized: norm)
            let z = try readComponentAsFloat(bin, o + step * 2, componentType: acc.componentType, normalized: norm)
            let w = try readComponentAsFloat(bin, o + step * 3, componentType: acc.componentType, normalized: norm)
            out.append(SIMD4<Float>(x, y, z, w))
        }
        return out
    }

    static func readVec4U16(gltf: GLTF, accessorIndex: Int, bin: Data) throws -> [SIMD4<UInt16>] {
        guard accessorIndex >= 0 && accessorIndex < gltf.accessors.count else { throw GLBLoaderError.invalidChunk }
        let acc = gltf.accessors[accessorIndex]
        try rejectSparseIfPresent(acc)
        guard acc.type == "VEC4" else { throw GLBLoaderError.unsupported("Accessor type \(acc.type) for VEC4 U16") }
        guard let bvIndex = acc.bufferView else { throw GLBLoaderError.missing("Accessor.bufferView missing") }
        let (base, bvLen, stride) = try bufferViewSlice(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        let byteOffset = (acc.byteOffset ?? 0)
        let elementStride = stride ?? (componentByteSize(acc.componentType) * 4)
        let elementSize = componentByteSize(acc.componentType) * 4
        if let stride, stride < elementSize { throw GLBLoaderError.invalidChunk }
        if acc.count > 0 {
            let last = byteOffset + (acc.count - 1) * elementStride + elementSize
            if last > bvLen { throw GLBLoaderError.invalidChunk }
        }

        var out: [SIMD4<UInt16>] = []
        out.reserveCapacity(acc.count)
        for i in 0..<acc.count {
            let o = base + byteOffset + i * elementStride
            switch acc.componentType {
            case 5123: // USHORT
                out.append(SIMD4<UInt16>(
                    try GLBBinary.readU16(bin, o),
                    try GLBBinary.readU16(bin, o + 2),
                    try GLBBinary.readU16(bin, o + 4),
                    try GLBBinary.readU16(bin, o + 6)
                ))
            case 5121: // UBYTE
                try GLBBinary.ensureReadable(bin, offset: o, byteCount: 4)
                out.append(SIMD4<UInt16>(
                    UInt16(bin[o]),
                    UInt16(bin[o + 1]),
                    UInt16(bin[o + 2]),
                    UInt16(bin[o + 3])
                ))
            default:
                throw GLBLoaderError.unsupported("Unsupported JOINTS_0 componentType \(acc.componentType)")
            }
        }
        return out
    }

    static func readScalarFloat(gltf: GLTF, accessorIndex: Int, bin: Data) throws -> [Float] {
        guard accessorIndex >= 0 && accessorIndex < gltf.accessors.count else { throw GLBLoaderError.invalidChunk }
        let acc = gltf.accessors[accessorIndex]
        try rejectSparseIfPresent(acc)
        guard acc.type == "SCALAR" else { throw GLBLoaderError.unsupported("Accessor type \(acc.type) for scalar float") }
        guard acc.componentType == 5126 else { throw GLBLoaderError.unsupported("Scalar must be float32") }
        guard let bvIndex = acc.bufferView else { throw GLBLoaderError.missing("Accessor.bufferView missing") }
        let (base, bvLen, stride) = try bufferViewSlice(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        let byteOffset = (acc.byteOffset ?? 0)
        let elementStride = stride ?? MemoryLayout<Float>.stride
        let elementSize = MemoryLayout<Float>.stride
        if let stride, stride < elementSize { throw GLBLoaderError.invalidChunk }
        if acc.count > 0 {
            let last = byteOffset + (acc.count - 1) * elementStride + elementSize
            if last > bvLen { throw GLBLoaderError.invalidChunk }
        }

        var out: [Float] = []
        out.reserveCapacity(acc.count)
        for i in 0..<acc.count {
            let o = base + byteOffset + i * elementStride
            out.append(try GLBBinary.readF32(bin, o))
        }
        return out
    }

    static func readMat4Float(gltf: GLTF, accessorIndex: Int, bin: Data) throws -> [simd_float4x4] {
        guard accessorIndex >= 0 && accessorIndex < gltf.accessors.count else { throw GLBLoaderError.invalidChunk }
        let acc = gltf.accessors[accessorIndex]
        try rejectSparseIfPresent(acc)
        guard acc.type == "MAT4" else { throw GLBLoaderError.unsupported("Accessor type \(acc.type) for MAT4") }
        guard acc.componentType == 5126 else { throw GLBLoaderError.unsupported("MAT4 must be float32") }
        guard let bvIndex = acc.bufferView else { throw GLBLoaderError.missing("Accessor.bufferView missing") }
        let (base, bvLen, stride) = try bufferViewSlice(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        let byteOffset = (acc.byteOffset ?? 0)
        let elementStride = stride ?? (MemoryLayout<Float>.stride * 16)
        let elementSize = MemoryLayout<Float>.stride * 16
        if let stride, stride < elementSize { throw GLBLoaderError.invalidChunk }
        if acc.count > 0 {
            let last = byteOffset + (acc.count - 1) * elementStride + elementSize
            if last > bvLen { throw GLBLoaderError.invalidChunk }
        }

        var out: [simd_float4x4] = []
        out.reserveCapacity(acc.count)
        for i in 0..<acc.count {
            let o = base + byteOffset + i * elementStride
            let c0 = SIMD4<Float>(try GLBBinary.readF32(bin, o), try GLBBinary.readF32(bin, o + 4), try GLBBinary.readF32(bin, o + 8), try GLBBinary.readF32(bin, o + 12))
            let c1 = SIMD4<Float>(try GLBBinary.readF32(bin, o + 16), try GLBBinary.readF32(bin, o + 20), try GLBBinary.readF32(bin, o + 24), try GLBBinary.readF32(bin, o + 28))
            let c2 = SIMD4<Float>(try GLBBinary.readF32(bin, o + 32), try GLBBinary.readF32(bin, o + 36), try GLBBinary.readF32(bin, o + 40), try GLBBinary.readF32(bin, o + 44))
            let c3 = SIMD4<Float>(try GLBBinary.readF32(bin, o + 48), try GLBBinary.readF32(bin, o + 52), try GLBBinary.readF32(bin, o + 56), try GLBBinary.readF32(bin, o + 60))
            out.append(simd_float4x4(c0, c1, c2, c3))
        }
        return out
    }

    static func readIndices(gltf: GLTF, accessorIndex: Int, bin: Data) throws -> [UInt32] {
        guard accessorIndex >= 0 && accessorIndex < gltf.accessors.count else { throw GLBLoaderError.invalidChunk }
        let acc = gltf.accessors[accessorIndex]
        try rejectSparseIfPresent(acc)
        guard acc.type == "SCALAR" else { throw GLBLoaderError.unsupported("Indices accessor type must be SCALAR") }
        guard let bvIndex = acc.bufferView else { throw GLBLoaderError.missing("Indices accessor.bufferView missing") }
        let (base, bvLen, _) = try bufferViewSlice(gltf: gltf, bufferViewIndex: bvIndex, bin: bin)
        let byteOffset = (acc.byteOffset ?? 0)
        // Indices are tightly packed; bufferView.byteStride should be ignored here.
        let elementStride = componentByteSize(acc.componentType)
        let elementSize = elementStride
        if acc.count > 0 {
            let last = byteOffset + (acc.count - 1) * elementStride + elementSize
            if last > bvLen { throw GLBLoaderError.invalidChunk }
        }

        var out: [UInt32] = []
        out.reserveCapacity(acc.count)
        for i in 0..<acc.count {
            let o = base + byteOffset + i * elementStride
            switch acc.componentType {
            case 5121:
                try GLBBinary.ensureReadable(bin, offset: o, byteCount: 1)
                out.append(UInt32(bin[o])) // UBYTE
            case 5123: out.append(UInt32(try GLBBinary.readU16(bin, o))) // USHORT
            case 5125: out.append(try GLBBinary.readU32(bin, o)) // UINT
            default: throw GLBLoaderError.unsupported("Unsupported index componentType \(acc.componentType)")
            }
        }
        return out
    }
}

