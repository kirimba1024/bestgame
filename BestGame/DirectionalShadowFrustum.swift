import simd

/// Чистая математика directional shadow: AABB в мире → ortho `lightViewProj`.
/// Не знает о лисах/шлеме — только геометрия и разрешение карты.
enum DirectionalShadowFrustum {
    static func lightViewProjection(
        sunDir: SIMD3<Float>,
        worldMin: SIMD3<Float>,
        worldMax: SIMD3<Float>,
        shadowMapResolution: Int,
        marginXY: Float = 6.0,
        marginZ: Float = 28.0
    ) -> simd_float4x4 {
        let center = (worldMin + worldMax) * 0.5
        let extent = max(worldMax - worldMin, SIMD3<Float>(repeating: 1))
        let radius = simd_length(extent) * 0.6
        let eye = center + sunDir * max(25.0, radius * 2.0)
        let view = simd_float4x4.lookAtRH(eye: eye, forward: -sunDir, upHint: SIMD3<Float>(0, 1, 0))

        var lmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var lmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for c in worldAABB8Corners(min: worldMin, max: worldMax) {
            let p = transformWorldPoint(view, c)
            lmin = simd_min(lmin, p)
            lmax = simd_max(lmax, p)
        }

        var left = lmin.x - marginXY
        var right = lmax.x + marginXY
        var bottom = lmin.y - marginXY
        var top = lmax.y + marginXY

        let nearZ = max(0.1, -lmax.z - marginZ)
        let farZ = max(nearZ + 1.0, -lmin.z + marginZ)

        let res = max(1, shadowMapResolution)
        let texel = (right - left) / Float(res)
        if texel.isFinite && texel > 0 {
            let cx = (left + right) * 0.5
            let cy = (bottom + top) * 0.5
            let scx = floor(cx / texel) * texel
            let scy = floor(cy / texel) * texel
            let hx = (right - left) * 0.5
            let hy = (top - bottom) * 0.5
            left = scx - hx
            right = scx + hx
            bottom = scy - hy
            top = scy + hy
        }

        let proj = simd_float4x4.orthographicRH(left: left, right: right, bottom: bottom, top: top, nearZ: nearZ, farZ: farZ)
        return proj * view
    }

    static func fallbackLightViewProjection(sunDir: SIMD3<Float>, sceneCenter: SIMD3<Float>) -> simd_float4x4 {
        let eye = sceneCenter + sunDir * 35.0
        let view = simd_float4x4.lookAtRH(eye: eye, forward: -sunDir, upHint: SIMD3<Float>(0, 1, 0))
        let proj = simd_float4x4.orthographicRH(left: -10, right: 10, bottom: -10, top: 10, nearZ: 0.1, farZ: 120)
        return proj * view
    }

    // MARK: - Helpers (используются и `Renderer` при сборе caster bounds)

    static func transformWorldPoint(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(r.x, r.y, r.z) / max(1e-6, r.w)
    }

    static func worldAABB8Corners(min: SIMD3<Float>, max: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3(min.x, min.y, min.z),
            SIMD3(max.x, min.y, min.z),
            SIMD3(min.x, max.y, min.z),
            SIMD3(max.x, max.y, min.z),
            SIMD3(min.x, min.y, max.z),
            SIMD3(max.x, min.y, max.z),
            SIMD3(min.x, max.y, max.z),
            SIMD3(max.x, max.y, max.z),
        ]
    }
}
