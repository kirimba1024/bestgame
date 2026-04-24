import simd

/// Вспомогательные раскладки по осям для демо-сцены.
enum SceneLayout {
    /// Симметричные смещения по X: `count` точек с шагом `spacing`, центр в нуле.
    static func xOffsets(count: Int, spacing: Float) -> [Float] {
        guard count > 0 else { return [] }
        if count == 1 { return [0] }
        let half = Float(count - 1) * 0.5 * spacing
        return (0..<count).map { -half + Float($0) * spacing }
    }
}
