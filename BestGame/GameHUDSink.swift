import Foundation

/// Абстракция оверлея кадра: HUD и сброс дельт ввода после `present`.
protocol GameHUDSink: AnyObject {
    func setHUDText(_ text: String)
    func flushPerFrameInputEnd()
    /// NDC x,y в [-1, 1] из той же проекции, что и сцена; `nil` — спрятать букву.
    func updateAxisLegendNDCPositions(x: (Float, Float)?, y: (Float, Float)?, z: (Float, Float)?)
}

extension GameMTKView: GameHUDSink {
    func flushPerFrameInputEnd() {
        flushPerFrameDeltas()
    }
}
