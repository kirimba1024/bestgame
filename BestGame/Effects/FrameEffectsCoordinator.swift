import Metal
import MetalKit

/// Собирает эффекты в фиксированном порядке: рендерер только строит контекст и делегирует сюда.
final class FrameEffectsCoordinator {
    private let effects: [GPUFrameEffect]
    private let effectsByDrawOrder: [GPUFrameEffect]

    init(device: MTLDevice) {
        effects = [
            ParticleBurstPass(device: device),
            FireflyDriftPass(device: device),
        ]
        effectsByDrawOrder = effects.sorted(by: { $0.compositeDrawOrder < $1.compositeDrawOrder })
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
        for e in effectsByDrawOrder {
            e.encodeDraw(encoder: encoder, context: context)
        }
    }
}
