import AppKit
import MetalKit

final class GameMTKView: MTKView {
    var inputChanged: ((InputState) -> Void)?
    private var input = InputState()
    private var trackingArea: NSTrackingArea?

    private lazy var hudLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.textColor = .white
        l.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        l.wantsLayer = true
        l.layer?.cornerRadius = 4
        l.maximumNumberOfLines = 6
        l.lineBreakMode = .byWordWrapping
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()

    private func makeAxisLegendLabel(_ letter: String, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: letter)
        t.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        t.textColor = color
        t.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        t.isBordered = false
        t.wantsLayer = true
        t.layer?.cornerRadius = 3
        t.alignment = .center
        t.translatesAutoresizingMaskIntoConstraints = true
        t.isHidden = true
        return t
    }

    private lazy var axisLabelX = makeAxisLegendLabel("X", color: NSColor(calibratedRed: 1, green: 0.28, blue: 0.28, alpha: 1))
    private lazy var axisLabelY = makeAxisLegendLabel("Y", color: NSColor(calibratedRed: 0.32, green: 0.95, blue: 0.32, alpha: 1))
    private lazy var axisLabelZ = makeAxisLegendLabel("Z", color: NSColor(calibratedRed: 0.35, green: 0.48, blue: 1, alpha: 1))

    private lazy var hudStack: NSStackView = {
        let s = NSStackView(views: [hudLabel])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 5
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private lazy var centerCrosshairOverlay = CenterCrosshairOverlayView()

    var isHUDEnabled: Bool = true {
        didSet {
            hudStack.isHidden = !isHUDEnabled
            axisLabelX.isHidden = !isHUDEnabled
            axisLabelY.isHidden = !isHUDEnabled
            axisLabelZ.isHidden = !isHUDEnabled
        }
    }

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var mouseMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?

    /// Скрытие стрелки над игровым видом (парный `unhide` при выходе / потере ключа окна).
    private var cursorHiddenForGameViewport = false
    private var windowKeyCursorObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installHUDIfNeeded()
            installEventMonitorsIfNeeded()
            installWindowCursorObserversIfNeeded()
            window?.acceptsMouseMovedEvents = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeFirstResponder(self)
                self.syncGameViewportCursorWithPointer()
            }
        } else {
            removeWindowCursorObservers()
            setGameViewportCursorHidden(false)
            removeEventMonitorsIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        let w = max(120, bounds.width - 20)
        hudLabel.preferredMaxLayoutWidth = w
    }

    deinit {
        removeWindowCursorObservers()
        setGameViewportCursorHidden(false)
        removeEventMonitorsIfNeeded()
    }

    private func setGameViewportCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHiddenForGameViewport else { return }
        if hidden {
            NSCursor.hide()
            cursorHiddenForGameViewport = true
        } else {
            NSCursor.unhide()
            cursorHiddenForGameViewport = false
        }
    }

    /// Курсор скрыт только когда указатель над видом и окно ключевое.
    private func syncGameViewportCursorWithPointer() {
        guard let w = window, w.isKeyWindow else {
            setGameViewportCursorHidden(false)
            return
        }
        let locView = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        setGameViewportCursorHidden(bounds.contains(locView))
    }

    private func installWindowCursorObserversIfNeeded() {
        guard let w = window, windowKeyCursorObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        let o1 = nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.syncGameViewportCursorWithPointer()
        }
        let o2 = nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.setGameViewportCursorHidden(false)
        }
        windowKeyCursorObservers = [o1, o2]
    }

    private func removeWindowCursorObservers() {
        let nc = NotificationCenter.default
        for o in windowKeyCursorObservers {
            nc.removeObserver(o)
        }
        windowKeyCursorObservers.removeAll()
    }

    private func installEventMonitorsIfNeeded() {
        guard keyDownMonitor == nil, keyUpMonitor == nil, mouseMonitor == nil else { return }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.handleKeyUp(event)
            return event
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event)
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.handleKeyUp(event)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .rightMouseDown,
            .rightMouseUp,
            .leftMouseDown,
            .leftMouseUp
        ]) { [weak self] event in
            self?.handleMouse(event)
            return event
        }
    }

    private func removeEventMonitorsIfNeeded() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let globalKeyUpMonitor {
            NSEvent.removeMonitor(globalKeyUpMonitor)
            self.globalKeyUpMonitor = nil
        }
    }

    private func installHUDIfNeeded() {
        guard hudStack.superview == nil else { return }
        addSubview(hudStack)
        addSubview(axisLabelZ)
        addSubview(axisLabelY)
        addSubview(axisLabelX)
        addSubview(centerCrosshairOverlay)
        hudStack.isHidden = !isHUDEnabled
        axisLabelX.isHidden = !isHUDEnabled
        axisLabelY.isHidden = !isHUDEnabled
        axisLabelZ.isHidden = !isHUDEnabled
        let g = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hudStack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 8),
            hudStack.topAnchor.constraint(equalTo: g.topAnchor, constant: 4),
            centerCrosshairOverlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerCrosshairOverlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerCrosshairOverlay.widthAnchor.constraint(equalToConstant: CenterCrosshairOverlayView.sideLength),
            centerCrosshairOverlay.heightAnchor.constraint(equalToConstant: CenterCrosshairOverlayView.sideLength),
        ])
    }

    private static let axisLabelSide: CGFloat = 18

    private func viewPointFromClipNDC(_ ndc: (Float, Float)) -> CGPoint {
        let nx = CGFloat(ndc.0)
        let ny = CGFloat(ndc.1)
        let w = bounds.width
        let h = bounds.height
        let x = (nx * 0.5 + 0.5) * w
        let y = (ny * 0.5 + 0.5) * h
        return CGPoint(x: x, y: y)
    }

    private func layoutAxisLabel(_ label: NSTextField, ndc: (Float, Float)?) {
        guard isHUDEnabled, let ndc else {
            label.isHidden = true
            return
        }
        label.isHidden = false
        let p = viewPointFromClipNDC(ndc)
        let s = Self.axisLabelSide
        label.frame = CGRect(x: p.x - s * 0.5, y: p.y - s * 0.5, width: s, height: s)
    }

    func updateAxisLegendNDCPositions(x: (Float, Float)?, y: (Float, Float)?, z: (Float, Float)?) {
        let apply = { [weak self] in
            guard let self else { return }
            guard self.isHUDEnabled else {
                self.axisLabelX.isHidden = true
                self.axisLabelY.isHidden = true
                self.axisLabelZ.isHidden = true
                return
            }
            self.layoutAxisLabel(self.axisLabelX, ndc: x)
            self.layoutAxisLabel(self.axisLabelY, ndc: y)
            self.layoutAxisLabel(self.axisLabelZ, ndc: z)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func setHUDText(_ text: String) {
        guard isHUDEnabled else { return }
        if Thread.isMainThread {
            hudLabel.stringValue = text
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.hudLabel.stringValue = text
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea {
            removeTrackingArea(ta)
        }
        let opts: NSTrackingArea.Options = [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func keyDown(with event: NSEvent) {
        handleKeyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        handleKeyUp(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        syncGameViewportCursorWithPointer()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setGameViewportCursorHidden(false)
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouse(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouse(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleMouse(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouse(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouse(event)
    }

    override func mouseDown(with event: NSEvent) {
        handleMouse(event)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouse(event)
    }

    func flushPerFrameDeltas() {
        input.endFrame()
        inputChanged?(input)
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard window != nil else { return }

        if event.keyCode == 53 {
            NSApp.terminate(nil)
            return
        }

        input.pressedKeyCodes.insert(event.keyCode)
        inputChanged?(input)
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard window != nil else { return }
        input.pressedKeyCodes.remove(event.keyCode)
        inputChanged?(input)
    }

    private func handleMouse(_ event: NSEvent) {
        guard window != nil else { return }

        switch event.type {
        case .rightMouseDown:
            input.isRightMouseDown = true
            window?.makeFirstResponder(self)
        case .rightMouseUp:
            input.isRightMouseDown = false
        case .leftMouseDown:
            input.isLeftMouseDown = true
            window?.makeFirstResponder(self)
        case .leftMouseUp:
            input.isLeftMouseDown = false
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            input.mouseDelta.x += event.deltaX
            input.mouseDelta.y += event.deltaY
        default:
            break
        }

        inputChanged?(input)
    }
}

// MARK: - Прицел по центру (не перехватывает мышь)

private final class CenterCrosshairOverlayView: NSView {
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
