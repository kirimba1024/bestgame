import simd

/// Мини-оси в углу экрана: только расчёт MVP для overlay.
enum WorldAxesGizmo {
    static func modelViewProj(proj: simd_float4x4, view: simd_float4x4) -> simd_float4x4 {
        let inv = view.inverse
        let cam = SIMD3<Float>(inv.columns.3.x, inv.columns.3.y, inv.columns.3.z)
        let right = SIMD3<Float>(inv.columns.0.x, inv.columns.0.y, inv.columns.0.z)
        let up = SIMD3<Float>(inv.columns.1.x, inv.columns.1.y, inv.columns.1.z)
        let back = SIMD3<Float>(inv.columns.2.x, inv.columns.2.y, inv.columns.2.z)
        let forward = normalize(-back)
        let anchor =
            cam
            + forward * Layout.forwardOffset
            - normalize(right) * Layout.rightOffset
            - normalize(up) * Layout.upOffset
        let scale = Layout.gizmoScale
        let model = simd_float4x4.translation(anchor) * simd_float4x4.scale([scale, scale, scale])
        return proj * view * model
    }

    private enum Layout {
        static let forwardOffset: Float = 2.35
        static let rightOffset: Float = 0.92
        static let upOffset: Float = 0.7
        static let gizmoScale: Float = 0.32
    }
}
