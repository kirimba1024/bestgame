import Metal
import simd

/// Куб-заглушка и цветной debug-mesh: vertex layout для `vertex_main` / `fragment_main`.
final class SolidColorMeshPass {
    // MARK: - Types

    struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
    }

    struct Uniforms {
        var mvp: simd_float4x4
    }

    // MARK: - Storage

    private let device: MTLDevice

    private let vertices: [Vertex] = [
        .init(position: [-1, -1,  1], color: [1, 0, 0]),
        .init(position: [ 1, -1,  1], color: [0, 1, 0]),
        .init(position: [ 1,  1,  1], color: [0, 0, 1]),
        .init(position: [-1,  1,  1], color: [1, 1, 0]),
        .init(position: [-1, -1, -1], color: [1, 0, 1]),
        .init(position: [ 1, -1, -1], color: [0, 1, 1]),
        .init(position: [ 1,  1, -1], color: [1, 1, 1]),
        .init(position: [-1,  1, -1], color: [0.2, 0.2, 0.2]),
    ]

    private let indices: [UInt16] = [
        0, 1, 2,  2, 3, 0,
        1, 5, 6,  6, 2, 1,
        5, 4, 7,  7, 6, 5,
        4, 0, 3,  3, 7, 4,
        3, 2, 6,  6, 7, 3,
        4, 5, 1,  1, 0, 4,
    ]

    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let cubeIndexCount: Int

    private(set) var glbVertexBuffer: MTLBuffer?
    private(set) var glbIndexBuffer: MTLBuffer?
    private(set) var glbIndexCount: Int = 0

    private(set) var simpleColorPipeline: MTLRenderPipelineState?

    // MARK: - Life cycle

    init(device: MTLDevice) {
        self.device = device
        let vLen = vertices.count * MemoryLayout<Vertex>.stride
        guard let vb = device.makeBuffer(bytes: vertices, length: vLen, options: [.storageModeShared]) else {
            fatalError("Failed to create cube vertex buffer.")
        }
        self.vertexBuffer = vb
        let iLen = indices.count * MemoryLayout<UInt16>.stride
        guard let ib = device.makeBuffer(bytes: indices, length: iLen, options: [.storageModeShared]) else {
            fatalError("Failed to create cube index buffer.")
        }
        self.indexBuffer = ib
        self.cubeIndexCount = indices.count
    }

    // MARK: - Pipeline

    func buildSimpleColorPipelineIfNeeded(
        library: MTLLibrary,
        colorPixelFormat: MTLPixelFormat,
        depthPixelFormat: MTLPixelFormat
    ) {
        if simpleColorPipeline != nil { return }

        guard let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main")
        else { fatalError("Failed to find Metal shader functions.") }

        let vertexDescriptor = Self.makeVertexDescriptor()

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthPixelFormat

        do {
            simpleColorPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }
    }

    // MARK: - Debug mesh

    func uploadFoxDebugMesh(_ mesh: GLBStaticMesh) {
        let verts: [Vertex] = mesh.positions.map { p in
            let c = SIMD3<Float>(
                (p.x * 0.5 + 0.5),
                (p.y * 0.5 + 0.5),
                (p.z * 0.5 + 0.5)
            )
            return Vertex(
                position: p * 0.02,
                color: simd_clamp(c, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            )
        }

        let vbLen = verts.count * MemoryLayout<Vertex>.stride
        glbVertexBuffer = device.makeBuffer(bytes: verts, length: vbLen, options: [.storageModeShared])

        let ibLen = mesh.indices.count * MemoryLayout<UInt32>.stride
        glbIndexBuffer = device.makeBuffer(bytes: mesh.indices, length: ibLen, options: [.storageModeShared])
        glbIndexCount = mesh.indices.count
    }

    // MARK: - Encoding

    func encodeRotatingCube(
        encoder: MTLRenderCommandEncoder,
        proj: simd_float4x4,
        view: simd_float4x4,
        angle: Float,
        translation: SIMD3<Float> = .zero,
        scale: Float = 1.0
    ) {
        guard let simpleColorPipeline else { return }
        encoder.setRenderPipelineState(simpleColorPipeline)
        let model =
            simd_float4x4.translation(translation)
            * simd_float4x4.rotation(radians: angle, axis: [0.3, 1.0, 0.2])
            * simd_float4x4.scale(SIMD3<Float>(repeating: scale))
        let mvp = proj * view * model
        var uniforms = Uniforms(mvp: mvp)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: cubeIndexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
    }

    func encodeGLBFallbackIfReady(
        encoder: MTLRenderCommandEncoder,
        proj: simd_float4x4,
        view: simd_float4x4,
        modelMatrix: simd_float4x4
    ) -> Bool {
        guard glbIndexCount > 0,
              let glbVertexBuffer,
              let glbIndexBuffer,
              let simpleColorPipeline
        else {
            return false
        }
        encoder.setRenderPipelineState(simpleColorPipeline)
        let mvp = proj * view * modelMatrix
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
        return true
    }

    // MARK: - Vertex layout

    private static func makeVertexDescriptor() -> MTLVertexDescriptor {
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
        return vertexDescriptor
    }
}
