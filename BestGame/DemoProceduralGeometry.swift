import simd

/// Процедурная геометрия демо-сцены (пол + сферы-пробы), без GLB в бандле.
enum DemoProceduralGeometry {
    /// Большой четырёхугольник в XZ, нормаль +Y; масштаб и позиция — снаружи матрицей модели.
    static func groundPlaneModel() -> GLBStaticModel {
        let y: Float = 0
        let verts: [GLBStaticVertex] = [
            .init(position: SIMD3(-0.5, y, -0.5), normal: SIMD3(0, 1, 0), uv: SIMD2(0, 0)),
            .init(position: SIMD3(0.5, y, -0.5), normal: SIMD3(0, 1, 0), uv: SIMD2(1, 0)),
            .init(position: SIMD3(0.5, y, 0.5), normal: SIMD3(0, 1, 0), uv: SIMD2(1, 1)),
            .init(position: SIMD3(-0.5, y, 0.5), normal: SIMD3(0, 1, 0), uv: SIMD2(0, 1)),
        ]
        let idx: [UInt32] = [0, 1, 2, 2, 3, 0]
        let mat = GLBPBRMaterialMR(
            baseColorFactor: SIMD4(0.14, 0.15, 0.16, 1),
            metallicFactor: 0.08,
            roughnessFactor: 0.92,
            baseColorImageData: nil,
            metallicRoughnessImageData: nil
        )
        return GLBStaticModel(primitives: [.init(vertices: verts, indices: idx, material: mat)])
    }

    /// Три низкополигональные сферы с разными MR — смотреть материал и тени.
    static func materialProbeSpheresModel() -> GLBStaticModel {
        let centers: [SIMD3<Float>] = [
            SIMD3(-2.25, 0.44, 0),
            SIMD3(0, 0.44, 0),
            SIMD3(2.25, 0.44, 0),
        ]
        let materials: [GLBPBRMaterialMR] = [
            .init(baseColorFactor: SIMD4(0.92, 0.93, 0.95, 1), metallicFactor: 0.95, roughnessFactor: 0.12, baseColorImageData: nil, metallicRoughnessImageData: nil),
            .init(baseColorFactor: SIMD4(0.85, 0.22, 0.18, 1), metallicFactor: 0.05, roughnessFactor: 0.88, baseColorImageData: nil, metallicRoughnessImageData: nil),
            .init(baseColorFactor: SIMD4(0.95, 0.72, 0.28, 1), metallicFactor: 0.9, roughnessFactor: 0.35, baseColorImageData: nil, metallicRoughnessImageData: nil),
        ]
        var prims: [GLBStaticPrimitive] = []
        prims.reserveCapacity(3)
        for i in 0..<3 {
            prims.append(uvSpherePrimitive(center: centers[i], radius: 0.78, stacks: 11, slices: 20, material: materials[i]))
        }
        return GLBStaticModel(primitives: prims)
    }

    private static func uvSpherePrimitive(
        center: SIMD3<Float>,
        radius: Float,
        stacks: Int,
        slices: Int,
        material: GLBPBRMaterialMR
    ) -> GLBStaticPrimitive {
        var vertices: [GLBStaticVertex] = []
        vertices.reserveCapacity((stacks + 1) * (slices + 1))
        for iy in 0...stacks {
            let v = Float(iy) / Float(stacks)
            let phi = v * .pi
            let sp = sin(phi)
            let cp = cos(phi)
            for ix in 0...slices {
                let u = Float(ix) / Float(slices)
                let theta = u * 2 * .pi
                let dir = SIMD3<Float>(cos(theta) * sp, cp, sin(theta) * sp)
                let p = center + dir * radius
                vertices.append(.init(position: p, normal: normalize(dir), uv: SIMD2(u, v)))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(stacks * slices * 6)
        let row = slices + 1
        for iy in 0..<stacks {
            for ix in 0..<slices {
                let a = UInt32(iy * row + ix)
                let b = UInt32(iy * row + ix + 1)
                let c = UInt32((iy + 1) * row + ix)
                let d = UInt32((iy + 1) * row + ix + 1)
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return GLBStaticPrimitive(vertices: vertices, indices: indices, material: material)
    }
}
