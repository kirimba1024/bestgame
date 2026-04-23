import Foundation
import CoreGraphics

struct InputState {
    var pressedKeyCodes: Set<UInt16> = []
    var mouseDelta: CGPoint = .zero
    var isRightMouseDown: Bool = false
    var isLeftMouseDown: Bool = false

    mutating func endFrame() {
        mouseDelta = .zero
    }

    func isPressed(_ keyCode: UInt16) -> Bool {
        pressedKeyCodes.contains(keyCode)
    }
}

enum KeyCode {
    // macOS hardware key codes (ANSI)
    static let w: UInt16 = 13
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let q: UInt16 = 12
    static let e: UInt16 = 14
    static let shift: UInt16 = 56
    static let space: UInt16 = 49
}

