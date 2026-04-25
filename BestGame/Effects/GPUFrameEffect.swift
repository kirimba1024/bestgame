import Metal
import MetalKit

/// Слой пост-эффектов: симуляция (compute) до основного pass, рисование после непрозрачной сцены.
/// `compositeDrawOrder`: меньше — раньше (α → затем additive).
protocol GPUFrameEffect: AnyObject {
    var compositeDrawOrder: Int { get }

    func buildIfNeeded(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    )

    func encodeCompute(into commandBuffer: MTLCommandBuffer, context: FrameEffectContext)
    func encodeDraw(encoder: MTLRenderCommandEncoder, context: FrameEffectContext)
}
