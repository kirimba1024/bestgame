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
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = clearColor
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.presentsWithTransaction = false

        view.delegate = context.coordinator
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

