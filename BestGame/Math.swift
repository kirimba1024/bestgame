import simd

extension simd_float4x4 {
    static func identity() -> simd_float4x4 { matrix_identity_float4x4 }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(s.x, 0, 0, 0),
            SIMD4<Float>(0, s.y, 0, 0),
            SIMD4<Float>(0, 0, s.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func rotation(radians: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        let a = normalize(axis)
        let x = a.x, y = a.y, z = a.z
        let c = cos(radians)
        let s = sin(radians)
        let t = 1 - c

        return simd_float4x4(
            SIMD4<Float>(t*x*x + c,     t*x*y + s*z,   t*x*z - s*y,   0),
            SIMD4<Float>(t*x*y - s*z,   t*y*y + c,     t*y*z + s*x,   0),
            SIMD4<Float>(t*x*z + s*y,   t*y*z - s*x,   t*z*z + c,     0),
            SIMD4<Float>(0,             0,             0,             1)
        )
    }

    static func rotationYX(yaw: Float, pitch: Float) -> simd_float4x4 {
        let ry = simd_float4x4.rotation(radians: yaw, axis: [0, 1, 0])
        let rx = simd_float4x4.rotation(radians: pitch, axis: [1, 0, 0])
        return ry * rx
    }

    // Right-handed perspective, Metal depth 0..1
    static func perspectiveRH(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let y = 1 / tan(fovyRadians * 0.5)
        let x = y / aspect
        let z = farZ / (nearZ - farZ)

        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * nearZ, 0)
        )
    }

    static func lookAtRH(eye: SIMD3<Float>, forward: SIMD3<Float>, upHint: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> simd_float4x4 {
        let f = normalize(forward)
        let r = normalize(cross(f, upHint))
        let u = cross(r, f)

        // Column-major matrix:
        // [ r.x  u.x  -f.x  0 ]
        // [ r.y  u.y  -f.y  0 ]
        // [ r.z  u.z  -f.z  0 ]
        // [ -dot(r,eye) -dot(u,eye) dot(f,eye) 1 ]
        return simd_float4x4(
            SIMD4<Float>(r.x, u.x, -f.x, 0),
            SIMD4<Float>(r.y, u.y, -f.y, 0),
            SIMD4<Float>(r.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(r, eye), -dot(u, eye), dot(f, eye), 1)
        )
    }
}

