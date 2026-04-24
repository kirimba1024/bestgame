import Foundation
import MetalKit

/// Пороги времени кадра и HUD, вынесены из `Renderer+MTKView` для читаемости.
enum RendererFrameTiming {
    /// Ограничение dt при лагах (стабильность симуляции камеры).
    static let maxDeltaTimeSeconds: Float = 1.0 / 20.0
    static let hudRefreshIntervalSeconds: Float = 0.35
    static let verticalFieldOfViewRadians: Float = 60 * (.pi / 180)
    static let depthNear: Float = 0.1
    /// Сцена + свободный полёт камеры легко уходят дальше 100 m — иначе клип → «дыры» и небо сквозь меши.
    static let depthFar: Float = 600
    static let cubeRotationMultiplier: Float = 0.9
}

enum RendererHUDFormatting {
    static func formatHUDText(
        fps: Float,
        frameMs: Float,
        drawableSize: CGSize,
        modelLine: String?
    ) -> String {
        let w = drawableSize.width
        let h = drawableSize.height
        if let modelLine {
            return String(format: "FPS: %.1f  (%.2f ms)\nDrawable: %.0fx%.0f\n%@", fps, frameMs, w, h, modelLine)
        }
        return String(format: "FPS: %.1f  (%.2f ms)\nDrawable: %.0fx%.0f", fps, frameMs, w, h)
    }
}
