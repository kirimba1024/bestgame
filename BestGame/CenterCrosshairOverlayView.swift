import AppKit

/// Прицел по центру (не перехватывает мышь).
final class CenterCrosshairOverlayView: NSView {
    static let sideLength: CGFloat = 26

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let gap: CGFloat = 3
        let arm: CGFloat = 6

        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
        ring.lineWidth = 1
        ring.stroke()

        NSColor(calibratedWhite: 1, alpha: 0.38).setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1.15
        cross.lineCapStyle = .round
        cross.move(to: NSPoint(x: c.x - arm, y: c.y))
        cross.line(to: NSPoint(x: c.x - gap, y: c.y))
        cross.move(to: NSPoint(x: c.x + gap, y: c.y))
        cross.line(to: NSPoint(x: c.x + arm, y: c.y))
        cross.move(to: NSPoint(x: c.x, y: c.y - arm))
        cross.line(to: NSPoint(x: c.x, y: c.y - gap))
        cross.move(to: NSPoint(x: c.x, y: c.y + gap))
        cross.line(to: NSPoint(x: c.x, y: c.y + arm))
        cross.stroke()

        NSColor(calibratedWhite: 1, alpha: 0.52).setFill()
        let dotR: CGFloat = 1.35
        NSBezierPath(ovalIn: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }
}
