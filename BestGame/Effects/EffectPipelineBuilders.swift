import Metal

enum EffectPipelineBuilders {
    static func configureAdditiveBlending(_ ca: MTLRenderPipelineColorAttachmentDescriptor) {
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .one
        ca.alphaBlendOperation = .add
        ca.sourceAlphaBlendFactor = .zero
        ca.destinationAlphaBlendFactor = .one
    }

    static func makeAdditiveBillboardRenderPSO(
        device: MTLDevice,
        library: MTLLibrary,
        label: String,
        vertex: String,
        fragment: String,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.vertexDescriptor = nil
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = depthPixelFormat
        if let ca = desc.colorAttachments[0] {
            configureAdditiveBlending(ca)
        }
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    static func makeDepthState(
        device: MTLDevice,
        compare: MTLCompareFunction,
        writeEnabled: Bool
    ) -> MTLDepthStencilState? {
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = compare
        ds.isDepthWriteEnabled = writeEnabled
        return device.makeDepthStencilState(descriptor: ds)
    }
}

