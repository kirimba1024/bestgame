import Metal
import MetalKit

extension Renderer {
    // MARK: - Pipelines & attachments

    func buildPipelineIfNeeded(for view: MTKView) {
        if solidPass.simpleColorPipeline != nil, depthState != nil { return }

        guard let library = device.makeDefaultLibrary() else {
            fatalError("Failed to load default Metal library. Ensure MetalShaders/*.metal is in the target.")
        }

        solidPass.buildSimpleColorPipelineIfNeeded(
            library: library,
            colorPixelFormat: view.colorPixelFormat,
            depthPixelFormat: view.depthStencilPixelFormat
        )

        scene.buildIfNeeded(
            device: device,
            library: library,
            colorPixelFormat: view.colorPixelFormat,
            depthPixelFormat: view.depthStencilPixelFormat,
            environment: environmentMap
        )

        if skyRenderer == nil {
            skyRenderer = SkyRenderer(
                device: device,
                library: library,
                colorPixelFormat: view.colorPixelFormat,
                depthPixelFormat: view.depthStencilPixelFormat
            )
        }

        frameEffects.buildAllIfNeeded(
            device: device,
            library: library,
            colorPixelFormat: view.colorPixelFormat,
            depthPixelFormat: view.depthStencilPixelFormat
        )

        sunOcularGlare.buildIfNeeded(library: library, drawablePixelFormat: view.colorPixelFormat)

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDesc)

        let skyDepthDesc = MTLDepthStencilDescriptor()
        skyDepthDesc.depthCompareFunction = .always
        skyDepthDesc.isDepthWriteEnabled = false
        skyDepthState = device.makeDepthStencilState(descriptor: skyDepthDesc)
    }

    func rebuildDepthTextureIfNeeded(for view: MTKView, size: CGSize) {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))

        if let depthTexture, depthTexture.width == width, depthTexture.height == height {
            return
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: view.depthStencilPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        depthTexture = device.makeTexture(descriptor: desc)
    }
}
