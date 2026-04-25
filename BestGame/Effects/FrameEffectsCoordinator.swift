import Metal
import MetalKit

/// Собирает эффекты в фиксированном порядке: рендерер только строит контекст и делегирует сюда.
final class FrameEffectsCoordinator {
    private let effects: [GPUFrameEffect]

    init(device: MTLDevice) {
        effects = [
            ParticleBurstPass(device: device),
            FireflyDriftPass(device: device),
        ]
    }

    func buildAllIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) {
        for e in effects {
            e.buildIfNeeded(
                device: device,
                library: library,
                colorPixelFormat: colorPixelFormat,
                depthPixelFormat: depthPixelFormat
            )
        }
    }

    func encodeAllCompute(into commandBuffer: MTLCommandBuffer, context: FrameEffectContext) {
        for e in effects {
            e.encodeCompute(into: commandBuffer, context: context)
        }
    }

    func encodeAllPostOpaqueDraws(encoder: MTLRenderCommandEncoder, context: FrameEffectContext) {
        for e in effects.sorted(by: { $0.compositeDrawOrder < $1.compositeDrawOrder }) {
            e.encodeDraw(encoder: encoder, context: context)
        }
    }
}
