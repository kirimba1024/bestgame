import Metal
import simd

/// Single-cascade directional shadow map renderer.
///
/// Best-practice defaults for games:
/// - depth-only pass into a depth texture
/// - slope-scaled depth bias in the shadow pass
/// - hardware PCF via `sample_compare` in the lighting shader
final class ShadowMapRenderer {
    struct Config {
        var size: Int = 2048
        var depthPixelFormat: MTLPixelFormat = .depth32Float
        var depthBias: Float = 0.001
        var slopeScale: Float = 2.0
        var clamp: Float = 0.01
    }

    private let device: MTLDevice
    private let config: Config

    private(set) var texture: MTLTexture?
    private(set) var compareSampler: MTLSamplerState?
    private var depthState: MTLDepthStencilState?

    var size: Int { config.size }

    init(device: MTLDevice, config: Config = .init()) {
        self.device = device
        self.config = config
        buildStateIfNeeded()
    }

    func ensureTexture() {
        let size = max(256, config.size)
        if let t = texture, t.width == size, t.height == size { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: config.depthPixelFormat,
            width: size,
            height: size,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        texture = device.makeTexture(descriptor: desc)
    }

    func render(into commandBuffer: MTLCommandBuffer, draw: (MTLRenderCommandEncoder) -> Void) {
        ensureTexture()
        guard let texture, let depthState else { return }

        let rp = MTLRenderPassDescriptor()
        rp.depthAttachment.texture = texture
        rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setDepthStencilState(depthState)
        enc.setViewport(
            MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(texture.width),
                height: Double(texture.height),
                znear: 0,
                zfar: 1
            )
        )
        enc.setDepthBias(config.depthBias, slopeScale: config.slopeScale, clamp: config.clamp)
        draw(enc)
        enc.endEncoding()
    }

    private func buildStateIfNeeded() {
        if compareSampler != nil, depthState != nil { return }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        // С flip V в шейдере обычно стабильнее `lessEqual` + небольшой bias.
        sd.compareFunction = .lessEqual
        compareSampler = device.makeSamplerState(descriptor: sd)

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)
    }
}

