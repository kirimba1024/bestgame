import Foundation

/// Абстракция оверлея кадра: HUD и сброс дельт ввода после `present`.
protocol GameHUDSink: AnyObject {
    func setHUDText(_ text: String)
    func flushPerFrameInputEnd()
}

extension GameMTKView: GameHUDSink {
    func flushPerFrameInputEnd() {
        flushPerFrameDeltas()
    }
}
