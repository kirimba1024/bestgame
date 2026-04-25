import Metal
import MetalKit
import simd

/// Солнечный ореол: offscreen HDR-blob → mip pyramid → additive composite + вуаль при взгляде на солнце.
/// Mip-bloom: сумма сэмплов по LOD даёт широкое свечение без отдельного blur-pass (очень дёшево).
final class SunOcularGlarePass {
    private static let bloomWidth = 512

    private let device: MTLDevice
    private var bloomTexture: MTLTexture?
    private var bloomPixelHeight: Int = 0

    private var blobPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var linearSampler: MTLSamplerState?

    init(device: MTLDevice) {
        self.device = device
    }

    static func sunScreenUV(
        viewProjection: simd_float4x4,
        cameraPosition: SIMD3<Float>,
        sunDirectionWS: SIMD3<Float>
    ) -> SIMD2<Float> {
        let s = normalize(sunDirectionWS)
        let anchor = cameraPosition + s * 100_000
        let c = viewProjection * SIMD4<Float>(anchor.x, anchor.y, anchor.z, 1)
        guard abs(c.w) > 1e-4 else { return SIMD2<Float>(0.5, 0.5) }
        let ndc = SIMD3<Float>(c.x, c.y, c.z) / c.w
        let u = ndc.x * 0.5 + 0.5
        let v = -ndc.y * 0.5 + 0.5
        return SIMD2<Float>(u, v)
    }

    static func sunAlignment(cameraForward: SIMD3<Float>, sunDirectionWS: SIMD3<Float>) -> Float {
        max(0, simd_dot(normalize(cameraForward), normalize(sunDirectionWS)))
    }

    func buildIfNeeded(library: MTLLibrary, drawablePixelFormat: MTLPixelFormat) {
        if blobPipeline != nil, compositePipeline != nil, linearSampler != nil { return }

        let blobDesc = MTLRenderPipelineDescriptor()
        blobDesc.label = "SunBloomBlob"
        blobDesc.vertexFunction = library.makeFunction(name: "sun_glare_vertex")
        blobDesc.fragmentFunction = library.makeFunction(name: "sun_bloom_blob_fs")
        blobDesc.colorAttachments[0].pixelFormat = .rgba16Float
        blobDesc.depthAttachmentPixelFormat = .invalid
        blobPipeline = try! device.makeRenderPipelineState(descriptor: blobDesc)

        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.label = "SunGlareComposite"
        compDesc.vertexFunction = library.makeFunction(name: "sun_glare_vertex")
        compDesc.fragmentFunction = library.makeFunction(name: "sun_glare_composite_fs")
        compDesc.colorAttachments[0].pixelFormat = drawablePixelFormat
        compDesc.depthAttachmentPixelFormat = .invalid
        let ca = compDesc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .one
        ca.alphaBlendOperation = .add
        ca.sourceAlphaBlendFactor = .zero
        ca.destinationAlphaBlendFactor = .one
        compositePipeline = try! device.makeRenderPipelineState(descriptor: compDesc)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: sd)
    }

    private func ensureBloomTexture(drawableAspect: Float) {
        let h = max(
            128,
            min(1024, Int((Float(Self.bloomWidth) / max(0.25, drawableAspect)).rounded(.down)))
        )
        if bloomTexture != nil, bloomPixelHeight == h { return }

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Self.bloomWidth,
            height: h,
            mipmapped: true
        )
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        bloomTexture = device.makeTexture(descriptor: td)
        bloomPixelHeight = h
    }

    func encode(
        commandBuffer: MTLCommandBuffer,
        drawableTexture: MTLTexture,
        drawableAspect: Float,
        viewProjection: simd_float4x4,
        cameraPosition: SIMD3<Float>,
        sunDirectionWS: SIMD3<Float>,
        cameraForward: SIMD3<Float>
    ) {
        guard let blobPipeline, let compositePipeline, let linearSampler else { return }

        let align = Self.sunAlignment(cameraForward: cameraForward, sunDirectionWS: sunDirectionWS)
        if align < 0.012 {
            return
        }

        ensureBloomTexture(drawableAspect: drawableAspect)
        guard let bloomTexture else { return }

        let sunUV = Self.sunScreenUV(
            viewProjection: viewProjection,
            cameraPosition: cameraPosition,
            sunDirectionWS: sunDirectionWS
        )
        let texInvAspect = Float(bloomTexture.height) / Float(bloomTexture.width)

        struct SunBlobUniforms {
            var sunUV: SIMD2<Float>
            var texInvAspect: Float
            var sunAlign: Float
        }
        var blobU = SunBlobUniforms(sunUV: sunUV, texInvAspect: texInvAspect, sunAlign: align)

        let rpBlob = MTLRenderPassDescriptor()
        rpBlob.colorAttachments[0].texture = bloomTexture
        rpBlob.colorAttachments[0].loadAction = .clear
        rpBlob.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpBlob.colorAttachments[0].storeAction = .store

        guard let encBlob = commandBuffer.makeRenderCommandEncoder(descriptor: rpBlob) else { return }
        encBlob.label = "SunBloomBlob"
        encBlob.setRenderPipelineState(blobPipeline)
        encBlob.setFragmentBytes(&blobU, length: MemoryLayout<SunBlobUniforms>.stride, index: 0)
        encBlob.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encBlob.endEncoding()

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "SunBloomMipmaps"
        blit.generateMipmaps(for: bloomTexture)
        blit.endEncoding()

        struct SunCompositeUniforms {
            var sunAlign: Float
            var mipGlowStrength: Float
            var veilStrength: Float
            var centerDazzle: Float
        }
        // Без чрезмерной вуали: bloom — ореол, лёгкое ослепление только почти в точку на солнце.
        var compU = SunCompositeUniforms(
            sunAlign: align,
            mipGlowStrength: 0.028,
            veilStrength: 0.11,
            centerDazzle: 0.16
        )

        let rpComp = MTLRenderPassDescriptor()
        rpComp.colorAttachments[0].texture = drawableTexture
        rpComp.colorAttachments[0].loadAction = .load
        rpComp.colorAttachments[0].storeAction = .store

        guard let encComp = commandBuffer.makeRenderCommandEncoder(descriptor: rpComp) else { return }
        encComp.label = "SunGlareComposite"
        encComp.setRenderPipelineState(compositePipeline)
        encComp.setFragmentTexture(bloomTexture, index: 0)
        encComp.setFragmentSamplerState(linearSampler, index: 0)
        encComp.setFragmentBytes(&compU, length: MemoryLayout<SunCompositeUniforms>.stride, index: 0)
        encComp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encComp.endEncoding()
    }
}
