import simd

/// Мини-оси у камеры: якорь в view-space (под HUD слева), мировые X/Y/Z из якоря; подписи — проекция концов в NDC.
enum WorldAxesGizmo {
    /// Длина полуоси в **локальном** пространстве гизмо (совпадает с `DebugDraw`).
    /// Должно совпадать с полуосью в `DebugDraw` (вершины осей).
    private static let axisHalfLengthLocal: Float = 0.22

    private enum Layout {
        static let gizmoScale: Float = 0.46
        /// Точка в **пространстве камеры** (`view * world` даёт эти координаты):
        /// −x влево на экране, −y ниже центра (под блок FPS), −z вперёд по взгляду (RH).
        static let viewSpaceAnchor = SIMD3<Float>(-0.88, 0.24, -1.02)
    }

    private static func anchorAndScale(view: simd_float4x4) -> (anchor: SIMD3<Float>, scale: Float) {
        let inv = view.inverse
        let p = inv * SIMD4<Float>(Layout.viewSpaceAnchor.x, Layout.viewSpaceAnchor.y, Layout.viewSpaceAnchor.z, 1)
        guard abs(p.w) > 1e-5 else { return (.zero, Layout.gizmoScale) }
        let anchor = SIMD3<Float>(p.x / p.w, p.y / p.w, p.z / p.w)
        return (anchor, Layout.gizmoScale)
    }

    static func modelViewProj(proj: simd_float4x4, view: simd_float4x4) -> simd_float4x4 {
        let (anchor, scale) = anchorAndScale(view: view)
        let model = simd_float4x4.translation(anchor) * simd_float4x4.scale(SIMD3<Float>(repeating: scale))
        return proj * view * model
    }

    /// NDC (x,y) в [-1,1] для подписей чуть дальше конца каждой оси; `nil` если за камерой/клип.
    static func axisLabelNDCs(proj: simd_float4x4, view: simd_float4x4) -> (x: (Float, Float)?, y: (Float, Float)?, z: (Float, Float)?) {
        let (anchor, scale) = anchorAndScale(view: view)
        let h = axisHalfLengthLocal * scale
        /// Чуть дальше конца палочки — буквы ближе к осям.
        let past: Float = 1.04
        let px = anchor + SIMD3<Float>(h * past, 0, 0)
        let py = anchor + SIMD3<Float>(0, h * past, 0)
        let pz = anchor + SIMD3<Float>(0, 0, h * past)

        func ndc(_ p: SIMD3<Float>) -> (Float, Float)? {
            let c = proj * view * SIMD4<Float>(p.x, p.y, p.z, 1)
            guard c.w > 0.02 else { return nil }
            let nx = c.x / c.w
            let ny = c.y / c.w
            guard nx.isFinite, ny.isFinite, abs(nx) < 4, abs(ny) < 4 else { return nil }
            return (nx, ny)
        }
        return (ndc(px), ndc(py), ndc(pz))
    }
}
