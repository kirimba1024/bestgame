import MetalKit

final class GameMTKView: MTKView {
    var inputChanged: ((InputState) -> Void)?
    private var input = InputState()
    private var trackingArea: NSTrackingArea?
    private lazy var hudLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        l.textColor = .white
        l.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        l.wantsLayer = true
        l.layer?.cornerRadius = 4
        l.maximumNumberOfLines = 3
        l.lineBreakMode = .byWordWrapping
        return l
    }()
    var isHUDEnabled: Bool = true {
        didSet { hudLabel.isHidden = !isHUDEnabled }
    }

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var mouseMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installHUDIfNeeded()
            installEventMonitorsIfNeeded()
            window?.acceptsMouseMovedEvents = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeFirstResponder(self)
            }
        } else {
            removeEventMonitorsIfNeeded()
        }
    }

    deinit {
        removeEventMonitorsIfNeeded()
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
        // Fallback: some SwiftUI hosting setups swallow key events before they reach responders.
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
        guard hudLabel.superview == nil else { return }
        addSubview(hudLabel)
        hudLabel.isHidden = !isHUDEnabled
        NSLayoutConstraint.activate([
            hudLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hudLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    func setHUDText(_ text: String) {
        guard isHUDEnabled else { return }
        // Can be called from the render thread; marshal to main for AppKit.
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
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let opts: NSTrackingArea.Options = [.activeInKeyWindow, .inVisibleRect, .mouseMoved]
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
        // Only when this view is in a window (and ideally visible).
        guard window != nil else { return }

        // Esc => quit game
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

