import simd

enum GLTFSanitize {
    struct Report {
        var nonFinitePositions: Int = 0
        var nonFiniteNormals: Int = 0
        var nonFiniteUVs: Int = 0
        var droppedTriangles: Int = 0
        var droppedDegenerateTriangles: Int = 0
        var truncatedIndexRemainder: Int = 0

        mutating func add(_ other: Report) {
            nonFinitePositions += other.nonFinitePositions
            nonFiniteNormals += other.nonFiniteNormals
            nonFiniteUVs += other.nonFiniteUVs
            droppedTriangles += other.droppedTriangles
            droppedDegenerateTriangles += other.droppedDegenerateTriangles
            truncatedIndexRemainder += other.truncatedIndexRemainder
        }

        var hasIssues: Bool {
            nonFinitePositions > 0
                || nonFiniteNormals > 0
                || nonFiniteUVs > 0
                || droppedTriangles > 0
                || droppedDegenerateTriangles > 0
                || truncatedIndexRemainder > 0
        }
    }

    @inline(__always)
    static func finiteOrZero(_ v: SIMD3<Float>, report: inout Report, counter: inout Int) -> SIMD3<Float> {
        if v.x.isFinite, v.y.isFinite, v.z.isFinite { return v }
        counter += 1
        return .zero
    }

    @inline(__always)
    static func finiteOrZero(_ v: SIMD2<Float>, report: inout Report, counter: inout Int) -> SIMD2<Float> {
        if v.x.isFinite, v.y.isFinite { return v }
        counter += 1
        return .zero
    }

    static func sanitizePositions(_ positions: [SIMD3<Float>], report: inout Report) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(positions.count)
        for p in positions {
            var c = report.nonFinitePositions
            let pp = finiteOrZero(p, report: &report, counter: &c)
            report.nonFinitePositions = c
            out.append(pp)
        }
        return out
    }

    static func sanitizeNormals(_ normals: [SIMD3<Float>], report: inout Report) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(normals.count)
        for n in normals {
            var c = report.nonFiniteNormals
            let nn = finiteOrZero(n, report: &report, counter: &c)
            report.nonFiniteNormals = c
            out.append(nn)
        }
        return out
    }

    static func sanitizeUVs(_ uvs: [SIMD2<Float>], report: inout Report) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(uvs.count)
        for uv in uvs {
            var c = report.nonFiniteUVs
            let u = finiteOrZero(uv, report: &report, counter: &c)
            report.nonFiniteUVs = c
            out.append(u)
        }
        return out
    }

    static func sanitizeTriangleIndices(_ indices: [UInt32], vertexCount: Int, report: inout Report) -> [UInt32] {
        if indices.isEmpty || vertexCount <= 0 { return [] }
        var idx = indices
        let rem = idx.count % 3
        if rem != 0 {
            report.truncatedIndexRemainder += rem
            idx.removeLast(rem)
        }

        var clean: [UInt32] = []
        clean.reserveCapacity(idx.count)

        let vc = UInt32(max(0, vertexCount))
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = idx[t]
            let b = idx[t + 1]
            let c = idx[t + 2]
            if a >= vc || b >= vc || c >= vc {
                report.droppedTriangles += 1
                continue
            }
            clean.append(a); clean.append(b); clean.append(c)
        }
        return clean
    }

    static func dropDegenerateTriangles(_ indices: [UInt32], positions: [SIMD3<Float>], report: inout Report) -> [UInt32] {
        guard !indices.isEmpty else { return [] }
        var clean: [UInt32] = []
        clean.reserveCapacity(indices.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let ia = Int(indices[t])
            let ib = Int(indices[t + 1])
            let ic = Int(indices[t + 2])
            if ia < 0 || ib < 0 || ic < 0 || ia >= positions.count || ib >= positions.count || ic >= positions.count {
                report.droppedTriangles += 1
                continue
            }
            let a = positions[ia]
            let b = positions[ib]
            let c = positions[ic]
            let ab = b - a
            let ac = c - a
            let n = cross(ab, ac)
            if simd_length_squared(n) < 1e-12 {
                report.droppedDegenerateTriangles += 1
                continue
            }
            clean.append(indices[t]); clean.append(indices[t + 1]); clean.append(indices[t + 2])
        }
        return clean
    }

    static func computeNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var acc = Array(repeating: SIMD3<Float>(0, 0, 0), count: positions.count)
        if indices.count >= 3 {
            for t in stride(from: 0, to: indices.count, by: 3) {
                let ia = Int(indices[t])
                let ib = Int(indices[t + 1])
                let ic = Int(indices[t + 2])
                if ia < 0 || ib < 0 || ic < 0 || ia >= positions.count || ib >= positions.count || ic >= positions.count { continue }
                let a = positions[ia]
                let b = positions[ib]
                let c = positions[ic]
                let n = cross(b - a, c - a)
                acc[ia] += n
                acc[ib] += n
                acc[ic] += n
            }
        }
        for i in 0..<acc.count {
            let l2 = simd_length_squared(acc[i])
            if l2.isFinite, l2 > 1e-10 {
                acc[i] /= sqrt(l2)
            } else {
                acc[i] = SIMD3<Float>(0, 1, 0)
            }
        }
        return acc
    }
}

