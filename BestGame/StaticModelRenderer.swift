import Metal
import MetalKit
import simd

/// Статический glTF mesh с PBR и отдельным depth-only проходом для карты теней.
final class StaticModelRenderer {
    enum DebugOptions {
        /// When enabled, expands indexed triangles into a non-indexed buffer and uses `drawPrimitives`.
        /// This is slower, but useful for isolating index-related issues.
        static let useNonIndexedDraw = false
    }

    struct DrawParams {
        var proj: simd_float4x4
        var view: simd_float4x4
        var cameraPosWS: SIMD3<Float>
        var model: simd_float4x4
        var lightViewProj: simd_float4x4
        var keyLight: SceneLighting.KeyLightFrame
        var shadowTexture: MTLTexture?
        var shadowSampler: MTLSamplerState?
        var exposure: Float = 1.0
        var debugMode: UInt32 = 0
    }

    private let pipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let instancedPipeline: MTLRenderPipelineState
    private let instancedShadowPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let environment: EnvironmentMap
    let localBounds: (min: SIMD3<Float>, max: SIMD3<Float>)

    private struct Submesh {
        var vertexBuffer: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
        var nonIndexedVertexBuffer: MTLBuffer
        var nonIndexedVertexCount: Int
        var baseColorFactor: SIMD4<Float>
        var metallicFactor: Float
        var roughnessFactor: Float
        var baseColorTex: MTLTexture?
        var metallicRoughnessTex: MTLTexture?
    }

    private let submeshes: [Submesh]

    // MARK: - Life cycle

    init(
        device: MTLDevice,
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat,
        model: GLBStaticModel,
        environment: EnvironmentMap
    ) {
        self.environment = environment
        guard let vs = library.makeFunction(name: "vertex_static_pbr"),
              let vsInst = library.makeFunction(name: "vertex_static_pbr_instanced"),
              let fs = library.makeFunction(name: "fragment_pbr_mr")
        else { fatalError("Missing PBR shaders.") }

        // NOTE: Swift pads `SIMD3<Float>` to 16 bytes, which easily breaks manual stride math.
        // Use `SIMD4<Float>` for predictable 16-byte slots and describe the first 3/2 components.
        struct GPUVertex {
            var position: SIMD4<Float> // xyz used
            var normal: SIMD4<Float>   // xyz used
            var uv: SIMD4<Float>       // xy used
        }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = MemoryLayout<GPUVertex>.offset(of: \.position) ?? 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = MemoryLayout<GPUVertex>.offset(of: \.normal) ?? 0
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2
        vd.attributes[2].offset = MemoryLayout<GPUVertex>.offset(of: \.uv) ?? 0
        vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<GPUVertex>.stride

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = colorPixelFormat
        pd.depthAttachmentPixelFormat = depthPixelFormat

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            fatalError("Failed to create PBR pipeline: \(error)")
        }

        do {
            let ipd = MTLRenderPipelineDescriptor()
            ipd.vertexFunction = vsInst
            ipd.fragmentFunction = fs
            ipd.vertexDescriptor = vd
            ipd.colorAttachments[0].pixelFormat = colorPixelFormat
            ipd.depthAttachmentPixelFormat = depthPixelFormat
            instancedPipeline = try device.makeRenderPipelineState(descriptor: ipd)
        } catch {
            fatalError("Failed to create instanced PBR pipeline: \(error)")
        }

        // Depth-only shadow pipeline (directional shadow map).
        do {
            let spd = MTLRenderPipelineDescriptor()
            spd.vertexFunction = library.makeFunction(name: "vertex_shadow_static")
            spd.fragmentFunction = nil
            spd.vertexDescriptor = vd
            spd.depthAttachmentPixelFormat = .depth32Float
            shadowPipeline = try device.makeRenderPipelineState(descriptor: spd)
        } catch {
            fatalError("Failed to create static shadow pipeline: \(error)")
        }

        do {
            let ispd = MTLRenderPipelineDescriptor()
            ispd.vertexFunction = library.makeFunction(name: "vertex_shadow_static_instanced")
            ispd.fragmentFunction = nil
            ispd.vertexDescriptor = vd
            ispd.depthAttachmentPixelFormat = .depth32Float
            instancedShadowPipeline = try device.makeRenderPipelineState(descriptor: ispd)
        } catch {
            fatalError("Failed to create instanced shadow pipeline: \(error)")
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .repeat
        sd.tAddressMode = .repeat
        sd.maxAnisotropy = 4
        guard let s = device.makeSamplerState(descriptor: sd) else { fatalError("Failed to create sampler.") }
        sampler = s

        let loader = MTKTextureLoader(device: device)
        var built: [Submesh] = []
        built.reserveCapacity(model.primitives.count)
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for prim in model.primitives {
            for v in prim.vertices {
                bmin = simd_min(bmin, v.position)
                bmax = simd_max(bmax, v.position)
            }
            let verts: [GPUVertex] = prim.vertices.map {
                GPUVertex(
                    position: SIMD4<Float>($0.position.x, $0.position.y, $0.position.z, 1),
                    normal: SIMD4<Float>($0.normal.x, $0.normal.y, $0.normal.z, 0),
                    uv: SIMD4<Float>($0.uv.x, $0.uv.y, 0, 0)
                )
            }
            let indexCount = prim.indices.count
            guard
                let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<GPUVertex>.stride, options: [.storageModeShared]),
                let ib = device.makeBuffer(bytes: prim.indices, length: prim.indices.count * MemoryLayout<UInt32>.stride, options: [.storageModeShared])
            else { continue }

            var expanded: [GPUVertex] = []
            expanded.reserveCapacity(prim.indices.count)
            for idx in prim.indices {
                let i = Int(idx)
                if i >= 0 && i < verts.count {
                    expanded.append(verts[i])
                }
            }
            guard let nvb = device.makeBuffer(bytes: expanded, length: expanded.count * MemoryLayout<GPUVertex>.stride, options: [.storageModeShared]) else {
                continue
            }

            let bcData = prim.material.baseColorImageData
            var baseTex: MTLTexture?
            if let d = bcData, !d.isEmpty {
                baseTex = try? loader.newTexture(data: d, options: [MTKTextureLoader.Option.SRGB: true])
                if baseTex == nil {
                    baseTex = try? loader.newTexture(data: d, options: [MTKTextureLoader.Option.SRGB: false])
                }
            }
            let mrTex = (prim.material.metallicRoughnessImageData != nil)
                ? try? loader.newTexture(data: prim.material.metallicRoughnessImageData!, options: [MTKTextureLoader.Option.SRGB: false])
                : nil

            built.append(Submesh(
                vertexBuffer: vb,
                indexBuffer: ib,
                indexCount: indexCount,
                nonIndexedVertexBuffer: nvb,
                nonIndexedVertexCount: expanded.count,
                baseColorFactor: prim.material.baseColorFactor,
                metallicFactor: prim.material.metallicFactor,
                roughnessFactor: prim.material.roughnessFactor,
                baseColorTex: baseTex,
                metallicRoughnessTex: mrTex
            ))
        }
        self.submeshes = built
        self.localBounds = (min: bmin, max: bmax)
    }

    // MARK: - Drawing

    func draw(encoder: MTLRenderCommandEncoder, params: DrawParams) {
        let mvp = params.proj * params.view * params.model
        let normalMatrix = params.model.inverse.transpose
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)

        for sm in submeshes {
            var u = PBRTypes.Uniforms(
                mvp: mvp,
                model: params.model,
                normalMatrix: normalMatrix,
                lightViewProj: params.lightViewProj,
                cameraPosWS: params.cameraPosWS,
                jointCount: 0,
                baseColorFactor: sm.baseColorFactor,
                metallicFactor: sm.metallicFactor,
                roughnessFactor: sm.roughnessFactor,
                exposure: params.exposure,
                debugMode: params.debugMode
            )

            if DebugOptions.useNonIndexedDraw {
                encoder.setVertexBuffer(sm.nonIndexedVertexBuffer, offset: 0, index: 0)
            } else {
                encoder.setVertexBuffer(sm.vertexBuffer, offset: 0, index: 0)
            }
            encoder.setVertexBytes(&u, length: MemoryLayout<PBRTypes.Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<PBRTypes.Uniforms>.stride, index: 0)
            var keyL = SceneLighting.KeyLightGPUBytes(params.keyLight)
            encoder.setFragmentBytes(&keyL, length: MemoryLayout<SceneLighting.KeyLightGPUBytes>.stride, index: 4)

            encoder.setFragmentTexture(sm.baseColorTex ?? environment.neutralBaseColor1x1, index: 0)
            encoder.setFragmentTexture(sm.metallicRoughnessTex ?? environment.neutralMetallicRoughness1x1, index: 1)
            encoder.setFragmentTexture(environment.texture, index: 2)
            encoder.setFragmentSamplerState(environment.sampler, index: 1)
            if let st = params.shadowTexture { encoder.setFragmentTexture(st, index: 3) }
            if let ss = params.shadowSampler { encoder.setFragmentSamplerState(ss, index: 2) }

            if DebugOptions.useNonIndexedDraw {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: sm.nonIndexedVertexCount)
            } else {
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: sm.indexCount,
                    indexType: .uint32,
                    indexBuffer: sm.indexBuffer,
                    indexBufferOffset: 0
                )
            }
        }
    }

    func drawShadow(
        encoder: MTLRenderCommandEncoder,
        lightViewProj: simd_float4x4,
        model: simd_float4x4
    ) {
        struct ShadowUniforms {
            var lightViewProj: simd_float4x4
            var model: simd_float4x4
            var jointCount: UInt32 = 0
            var _pad0: SIMD3<Float> = .zero
        }

        encoder.setRenderPipelineState(shadowPipeline)
        var u = ShadowUniforms(lightViewProj: lightViewProj, model: model)
        encoder.setVertexBytes(&u, length: MemoryLayout<ShadowUniforms>.stride, index: 1)

        for sm in submeshes {
            encoder.setVertexBuffer(sm.vertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: sm.indexCount,
                indexType: .uint32,
                indexBuffer: sm.indexBuffer,
                indexBufferOffset: 0
            )
        }
    }

    func drawInstances(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        cameraPosWS: SIMD3<Float>,
        lightViewProj: simd_float4x4,
        keyLight: SceneLighting.KeyLightFrame,
        shadowTexture: MTLTexture?,
        shadowSampler: MTLSamplerState?,
        instanceModels: MTLBuffer,
        instanceCount: Int,
        debugMode: UInt32 = 0
    ) {
        guard instanceCount > 0 else { return }

        encoder.setRenderPipelineState(instancedPipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setVertexBuffer(instanceModels, offset: 0, index: 2)

        for sm in submeshes {
            var u = PBRTypes.InstancedUniforms(
                viewProj: viewProj,
                lightViewProj: lightViewProj,
                cameraPosWS: cameraPosWS,
                baseColorFactor: sm.baseColorFactor,
                metallicFactor: sm.metallicFactor,
                roughnessFactor: sm.roughnessFactor,
                exposure: 1.0,
                debugMode: debugMode
            )

            encoder.setVertexBuffer(sm.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<PBRTypes.InstancedUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<PBRTypes.InstancedUniforms>.stride, index: 0)
            var keyL = SceneLighting.KeyLightGPUBytes(keyLight)
            encoder.setFragmentBytes(&keyL, length: MemoryLayout<SceneLighting.KeyLightGPUBytes>.stride, index: 4)

            encoder.setFragmentTexture(sm.baseColorTex ?? environment.neutralBaseColor1x1, index: 0)
            encoder.setFragmentTexture(sm.metallicRoughnessTex ?? environment.neutralMetallicRoughness1x1, index: 1)
            encoder.setFragmentTexture(environment.texture, index: 2)
            encoder.setFragmentSamplerState(environment.sampler, index: 1)
            if let st = shadowTexture { encoder.setFragmentTexture(st, index: 3) }
            if let ss = shadowSampler { encoder.setFragmentSamplerState(ss, index: 2) }

            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: sm.indexCount,
                indexType: .uint32,
                indexBuffer: sm.indexBuffer,
                indexBufferOffset: 0,
                instanceCount: instanceCount
            )
        }
    }

    func drawShadowInstances(
        encoder: MTLRenderCommandEncoder,
        lightViewProj: simd_float4x4,
        instanceModels: MTLBuffer,
        instanceCount: Int
    ) {
        guard instanceCount > 0 else { return }

        struct ShadowU {
            var lightViewProj: simd_float4x4
        }

        encoder.setRenderPipelineState(instancedShadowPipeline)
        var u = ShadowU(lightViewProj: lightViewProj)
        encoder.setVertexBytes(&u, length: MemoryLayout<ShadowU>.stride, index: 1)
        encoder.setVertexBuffer(instanceModels, offset: 0, index: 2)

        for sm in submeshes {
            encoder.setVertexBuffer(sm.vertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: sm.indexCount,
                indexType: .uint32,
                indexBuffer: sm.indexBuffer,
                indexBufferOffset: 0,
                instanceCount: instanceCount
            )
        }
    }
}

