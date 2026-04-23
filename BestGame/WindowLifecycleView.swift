import SwiftUI

final class QuitOnCloseWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

struct WindowLifecycleView: NSViewRepresentable {
    func makeCoordinator() -> QuitOnCloseWindowDelegate {
        QuitOnCloseWindowDelegate()
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        v.postsFrameChangedNotifications = false
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Assign once when window becomes available.
        if let w = nsView.window, w.delegate !== context.coordinator {
            w.delegate = context.coordinator
        }
    }
}

