import Metal
import simd

/// Minimal image-based lighting source for the PBR shader.
///
/// We generate a small equirectangular environment (sky/ground + sun) at runtime,
/// then rely on mipmaps as a cheap roughness prefilter approximation.
final class EnvironmentMap {
    let texture: MTLTexture
    let sampler: MTLSamplerState
    /// Умножение albedo × 1, если у материала нет baseColor-текстуры (иначе в Metal «залипает» предыдущий bind).
    let neutralBaseColor1x1: MTLTexture
    /// roughness *= G, metallic *= B → (1,1,1) не меняет факторы.
    let neutralMetallicRoughness1x1: MTLTexture

    /// Creates an RGBA16F equirect texture with mipmaps.
    /// Call once and reuse across frames.
    init(device: MTLDevice, commandQueue: MTLCommandQueue, width: Int = 512, height: Int = 256) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: max(4, width),
            height: max(4, height),
            mipmapped: true
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create environment texture.")
        }
        self.texture = tex

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .repeat
        sd.tAddressMode = .clampToEdge
        sd.maxAnisotropy = 1
        guard let s = device.makeSamplerState(descriptor: sd) else {
            fatalError("Failed to create environment sampler.")
        }
        self.sampler = s

        neutralBaseColor1x1 = Self.makeRGBA8Texture(device: device, bytes: [255, 255, 255, 255])
        neutralMetallicRoughness1x1 = Self.makeRGBA8Texture(device: device, bytes: [255, 255, 255, 255])

        fillBaseLevel()
        generateMipmaps(device: device, commandQueue: commandQueue)
    }

    private static func makeRGBA8Texture(device: MTLDevice, bytes: [UInt8]) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create 1x1 texture.")
        }
        var copy = bytes
        copy.withUnsafeMutableBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: 4
            )
        }
        return tex
    }

    private func fillBaseLevel() {
        let w = texture.width
        let h = texture.height

        // RGBA16F -> 4 * UInt16 (half-floats)
        var pixels = Array(repeating: UInt16(0), count: w * h * 4)

        func halfBits(_ v: Float) -> UInt16 {
            Float16(max(0, v)).bitPattern
        }
        func write(_ x: Int, _ y: Int, _ rgb: SIMD3<Float>) {
            let i = (y * w + x) * 4
            pixels[i + 0] = halfBits(rgb.x)
            pixels[i + 1] = halfBits(rgb.y)
            pixels[i + 2] = halfBits(rgb.z)
            pixels[i + 3] = halfBits(1)
        }

        // Только небо/земля: без «солнца» в текстуре. Иначе на гладком металле второй блик
        // от IBL (фиксированное направление) не совпадает с вращающимся ключевым светом.
        let skyTop = SIMD3<Float>(0.50, 0.60, 0.78)
        let skyHorizon = SIMD3<Float>(0.20, 0.25, 0.32)
        let groundHorizon = SIMD3<Float>(0.06, 0.06, 0.07)
        let groundBottom = SIMD3<Float>(0.01, 0.01, 0.012)

        for y in 0..<h {
            let v = (Float(y) + 0.5) / Float(h) // 0..1
            let theta = v * .pi // 0..pi
            let sinT = sin(theta)
            let cosT = cos(theta)

            for x in 0..<w {
                let u = (Float(x) + 0.5) / Float(w) // 0..1
                let phi = (u * 2.0 * .pi) - .pi // -pi..pi
                let sinP = sin(phi)
                let cosP = cos(phi)

                // y-up world
                let dir = SIMD3<Float>(sinT * sinP, cosT, sinT * cosP)

                let tSky = simd_smoothstep(0.0, 1.0, dir.y * 0.5 + 0.5)
                let sky = skyHorizon + (skyTop - skyHorizon) * tSky

                let tGround = simd_smoothstep(0.0, 1.0, (-dir.y) * 0.5 + 0.5)
                let ground = groundHorizon + (groundBottom - groundHorizon) * tGround

                // Плавный горизонт: жёсткое (dir.y >= 0) давало скачок цвета при IBL по N
                // (на сфере — видимая горизонтальная линия на «экваторе»).
                let tHorizon = simd_smoothstep(-0.26, 0.26, dir.y)
                let col = ground + (sky - ground) * tHorizon

                write(x, y, col)
            }
        }

        let region = MTLRegionMake2D(0, 0, w, h)
        pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: w * 4 * MemoryLayout<UInt16>.stride
            )
        }
    }

    private func generateMipmaps(device: MTLDevice, commandQueue: MTLCommandQueue) {
        guard texture.mipmapLevelCount > 1 else { return }
        guard let cb = commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder()
        else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}
