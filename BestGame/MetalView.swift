import SwiftUI
import MetalKit

struct MetalView: NSViewRepresentable {
    typealias NSViewType = GameMTKView

    let clearColor: MTLClearColor

    func makeCoordinator() -> Renderer {
        Renderer(clearColor: clearColor)
    }

    func makeNSView(context: Context) -> GameMTKView {
        let view = GameMTKView()

        guard let device = MTLCreateSystemDefaultDevice() else {
            assertionFailure("Metal is not supported on this machine.")
            return view
        }

        view.device = device
        // Render in linear, present in sRGB for correct display.
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = clearColor
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.presentsWithTransaction = false

        view.delegate = context.coordinator
        context.coordinator.hudSink = view
        view.inputChanged = { input in
            context.coordinator.updateInput(input)
        }
        return view
    }

    func updateNSView(_ nsView: GameMTKView, context: Context) {
        nsView.clearColor = clearColor
        context.coordinator.clearColor = clearColor
    }
}

