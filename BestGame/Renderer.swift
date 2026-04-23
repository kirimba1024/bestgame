import Metal
import MetalKit
import simd

final class Renderer: NSObject, MTKViewDelegate {
    var clearColor: MTLClearColor

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private var pipelineState: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var depthTexture: MTLTexture?

    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var input = InputState()

    private let camera = FlyCamera()
    private let debugDraw: DebugDraw
    private var skinnedRenderer: SkinnedModelRenderer?
    private var pendingSkinnedModel: GLBSkinnedModel?
    /// Несколько статических PBR-моделей (шлем, сферы, …) — рисуем в ряд.
    private var pendingStaticPBRModels: [GLBStaticModel] = []
    /// Имя GLB в том же порядке, что и `pendingStaticPBRModels` / `staticPBRRenderers`.
    private var staticPBRAssetNames: [String] = []
    private var staticPBRRenderers: [StaticModelRenderer] = []
    private var modelDebugLine: String?

    private var hudAccum: Float = 0
    private var hudFrames: Int = 0

    /// Глубина «полки» с моделями (камера смотрит в −Z с позиции z ≈ 5).
    private let sceneDepthZ: Float = -5.5
    /// Расстояние по X между центрами слотов.
    private let sceneSpacingX: Float = 4.2

    private struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    private struct Uniforms {
        var mvp: simd_float4x4
    }

    private let vertices: [Vertex] = [
        // Front (+Z)
        .init(position: [-1, -1,  1], color: [1, 0, 0]),
        .init(position: [ 1, -1,  1], color: [0, 1, 0]),
        .init(position: [ 1,  1,  1], color: [0, 0, 1]),
        .init(position: [-1,  1,  1], color: [1, 1, 0]),
        // Back (-Z)
        .init(position: [-1, -1, -1], color: [1, 0, 1]),
        .init(position: [ 1, -1, -1], color: [0, 1, 1]),
        .init(position: [ 1,  1, -1], color: [1, 1, 1]),
        .init(position: [-1,  1, -1], color: [0.2, 0.2, 0.2]),
    ]

    private var glbMesh: GLBStaticMesh?
    private var glbVertexBuffer: MTLBuffer?
    private var glbIndexBuffer: MTLBuffer?
    private var glbIndexCount: Int = 0

    private let indices: [UInt16] = [
        // Front
        0, 1, 2,  2, 3, 0,
        // Right
        1, 5, 6,  6, 2, 1,
        // Back
        5, 4, 7,  7, 6, 5,
        // Left
        4, 0, 3,  3, 7, 4,
        // Top
        3, 2, 6,  6, 7, 3,
        // Bottom
        4, 5, 1,  1, 0, 4
    ]

    private lazy var vertexBuffer: MTLBuffer = {
        let length = vertices.count * MemoryLayout<Vertex>.stride
        guard let buffer = device.makeBuffer(bytes: vertices, length: length, options: [.storageModeShared]) else {
            fatalError("Failed to create vertex buffer.")
        }
        return buffer
    }()

    private lazy var indexBuffer: MTLBuffer = {
        let length = indices.count * MemoryLayout<UInt16>.stride
        guard let buffer = device.makeBuffer(bytes: indices, length: length, options: [.storageModeShared]) else {
            fatalError("Failed to create index buffer.")
        }
        return buffer
    }()

    init(clearColor: MTLClearColor) {
        self.clearColor = clearColor

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this machine.")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create MTLCommandQueue.")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.debugDraw = DebugDraw(device: device)
        super.init()

        if let m = try? GLBLoader.loadStaticModel(named: "DamagedHelmet") {
            pendingStaticPBRModels.append(m)
            staticPBRAssetNames.append("DamagedHelmet")
        }
        if let m = try? GLBLoader.loadStaticModel(named: "MetalRoughSpheres") {
            pendingStaticPBRModels.append(m)
            staticPBRAssetNames.append("MetalRoughSpheres")
        }

        if let model = try? GLBLoader.loadSkinnedModel(named: "Fox") {
            pendingSkinnedModel = model
        } else if let mesh = try? GLBLoader.loadStaticMesh(named: "Fox") {
            glbMesh = mesh
            buildGLBBuffersIfPossible(mesh)
        }

        modelDebugLine = Self.makeSceneHUDLine(
            staticModels: pendingStaticPBRModels,
            hasSkinnedFox: pendingSkinnedModel != nil,
            hasFoxMesh: glbIndexCount > 0
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildDepthTextureIfNeeded(for: view, size: size)
    }

    func draw(in view: MTKView) {
        if pipelineState == nil || depthState == nil {
            buildPipelineIfNeeded(for: view)
            rebuildDepthTextureIfNeeded(for: view, size: view.drawableSize)
        }

        let now = CACurrentMediaTime()
        let dt = Float(min(1.0 / 20.0, max(0.0, now - lastFrameTime)))
        lastFrameTime = now
        camera.update(dt: dt, input: input)

        hudAccum += dt
        hudFrames += 1
        if hudAccum >= 0.35, let gv = view as? GameMTKView {
            let fps = Float(hudFrames) / max(1e-6, hudAccum)
            let ms = (hudAccum / Float(hudFrames)) * 1000.0
            let size = view.drawableSize
            if let modelDebugLine {
                gv.setHUDText(String(format: "FPS: %.1f  (%.2f ms)\nDrawable: %.0fx%.0f\n%@", fps, ms, size.width, size.height, modelDebugLine))
            } else {
                gv.setHUDText(String(format: "FPS: %.1f  (%.2f ms)\nDrawable: %.0fx%.0f", fps, ms, size.width, size.height))
            }
            hudAccum = 0
            hudFrames = 0
        }

        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        if let depthTexture {
            renderPassDescriptor.depthAttachment.texture = depthTexture
            renderPassDescriptor.depthAttachment.clearDepth = 1.0
            renderPassDescriptor.depthAttachment.loadAction = .clear
            renderPassDescriptor.depthAttachment.storeAction = .dontCare
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        encoder.setDepthStencilState(depthState)

        let time = Float(now - startTime)
        let angle = time * 0.9

        let aspect = max(0.001, Float(view.drawableSize.width / view.drawableSize.height))
        let proj = simd_float4x4.perspectiveRH(fovyRadians: 60 * (.pi / 180), aspect: aspect, nearZ: 0.1, farZ: 100)
        let viewM = camera.viewMatrix()

        let hasScene =
            !staticPBRRenderers.isEmpty || skinnedRenderer != nil
            || (glbVertexBuffer != nil && glbIndexCount > 0)

        if hasScene {
            let baseT = simd_float4x4.translation([0, 0, sceneDepthZ])
            let rotY = simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])
            let staticBaseScale: Float = 0.5
            let helmetScaleMul: Float = 5

            let hasFoxSlot = (skinnedRenderer != nil) || (glbVertexBuffer != nil && glbIndexCount > 0)
            let totalSlots = staticPBRRenderers.count + (hasFoxSlot ? 1 : 0)
            let xs = Self.layoutOffsetsX(count: max(1, totalSlots), spacing: sceneSpacingX)
            var slot = 0

            for (i, r) in staticPBRRenderers.enumerated() {
                let x = xs[slot]
                slot += 1
                let isHelmet = i < staticPBRAssetNames.count && staticPBRAssetNames[i] == "DamagedHelmet"
                let s = staticBaseScale * (isHelmet ? helmetScaleMul : 1)
                let modelM = baseT * simd_float4x4.translation([x, 0, 0]) * rotY * simd_float4x4.scale([s, s, s])
                r.draw(
                    encoder: encoder,
                    params: .init(proj: proj, view: viewM, cameraPosWS: camera.position, model: modelM)
                )
            }

            if let skinned = skinnedRenderer {
                let x = xs[slot]
                slot += 1
                skinned.draw(
                    encoder: encoder,
                    params: .init(
                        proj: proj,
                        view: viewM,
                        cameraPosWS: camera.position,
                        time: time,
                        modelTranslation: SIMD3(x, 0, sceneDepthZ),
                        modelScale: 0.045
                    )
                )
            }

            if let glbVertexBuffer, let glbIndexBuffer, glbIndexCount > 0, skinnedRenderer == nil {
                let x = xs[slot]
                slot += 1
                encoder.setRenderPipelineState(pipelineState!)

                let model =
                    baseT
                    * simd_float4x4.translation([x, 0, 0])
                    * simd_float4x4.scale([4, 4, 4])
                    * simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])
                let mvp = proj * viewM * model
                var uniforms = Uniforms(mvp: mvp)
                encoder.setVertexBuffer(glbVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: glbIndexCount,
                    indexType: .uint32,
                    indexBuffer: glbIndexBuffer,
                    indexBufferOffset: 0
                )
            }
        } else {
            encoder.setRenderPipelineState(pipelineState!)

            // Fallback: cube.
            let model = simd_float4x4.rotation(radians: angle, axis: [0.3, 1.0, 0.2])
            let mvp = proj * viewM * model

            var uniforms = Uniforms(mvp: mvp)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indices.count,
                indexType: .uint16,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        }

        // Axes gizmo (XYZ)
        if let pipelineState {
            debugDraw.drawAxes(encoder: encoder, pipeline: pipelineState, viewProj: proj * viewM)
        }

        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if let gameView = view as? GameMTKView {
            gameView.flushPerFrameDeltas()
        }
    }

    func updateInput(_ input: InputState) {
        self.input = input
    }

    private func buildPipelineIfNeeded(for view: MTKView) {
        if pipelineState != nil, depthState != nil { return }

        guard let library = device.makeDefaultLibrary() else {
            fatalError("Failed to load default Metal library. Ensure Shaders.metal is in the target.")
        }
        guard let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main")
        else { fatalError("Failed to find Metal shader functions.") }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }

        if staticPBRRenderers.isEmpty {
            for m in pendingStaticPBRModels {
                staticPBRRenderers.append(
                    StaticModelRenderer(
                        device: device,
                        library: library,
                        colorPixelFormat: view.colorPixelFormat,
                        depthPixelFormat: view.depthStencilPixelFormat,
                        model: m
                    )
                )
            }
        }

        if skinnedRenderer == nil, let model = pendingSkinnedModel {
            skinnedRenderer = SkinnedModelRenderer(
                device: device,
                library: library,
                colorPixelFormat: view.colorPixelFormat,
                depthPixelFormat: view.depthStencilPixelFormat,
                model: model
            )
        }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDesc)
    }

    private func rebuildDepthTextureIfNeeded(for view: MTKView, size: CGSize) {
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
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        depthTexture = device.makeTexture(descriptor: desc)
    }

    private func buildGLBBuffersIfPossible(_ mesh: GLBStaticMesh) {
        // Build a simple colored vertex buffer from positions only.
        let verts: [Vertex] = mesh.positions.map { p in
            // Simple pseudo-color from position (debug-friendly).
            let c = SIMD3<Float>(
                (p.x * 0.5 + 0.5),
                (p.y * 0.5 + 0.5),
                (p.z * 0.5 + 0.5)
            )
            return Vertex(position: p * 0.02, color: simd_clamp(c, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)))
        }

        let vbLen = verts.count * MemoryLayout<Vertex>.stride
        glbVertexBuffer = device.makeBuffer(bytes: verts, length: vbLen, options: [.storageModeShared])

        let ibLen = mesh.indices.count * MemoryLayout<UInt32>.stride
        glbIndexBuffer = device.makeBuffer(bytes: mesh.indices, length: ibLen, options: [.storageModeShared])
        glbIndexCount = mesh.indices.count
    }

    // Skinning/debug moved to SkinnedModelRenderer / DebugDraw.

    private static func layoutOffsetsX(count: Int, spacing: Float) -> [Float] {
        guard count > 0 else { return [] }
        if count == 1 { return [0] }
        let half = Float(count - 1) * 0.5 * spacing
        return (0..<count).map { -half + Float($0) * spacing }
    }

    private static func makeSceneHUDLine(
        staticModels: [GLBStaticModel],
        hasSkinnedFox: Bool,
        hasFoxMesh: Bool
    ) -> String {
        var parts: [String] = []
        if !staticModels.isEmpty {
            parts.append("\(staticModels.count)× PBR static (glTF)")
        }
        if hasSkinnedFox {
            parts.append("Fox skinned")
        } else if hasFoxMesh {
            parts.append("Fox mesh (debug)")
        }
        return parts.joined(separator: " · ")
    }
}

