import Metal
import simd

/// GPU-instanced procedural 3D tree (no textures, no GLB).
/// Low-poly trunk + canopy blobs, all generated in code once, then instanced.
final class ProceduralTreeRenderer {
    struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var materialID: UInt32 // 0 = trunk, 1 = leaves
        var _pad: UInt32 = 0
    }

    struct Instance {
        var position: SIMD3<Float>   // world-space base point (on terrain)
        var scale: Float             // overall size
        var yaw: Float               // rotation around Y
        var seed: Float              // random seed for shape variation
    }

    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState?
    private var shadowPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var vb: MTLBuffer?
    private var vertexCount: Int = 0
    private var instanceBuffer: MTLBuffer?
    private(set) var instanceCount: Int = 0
    private(set) var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?

    init(device: MTLDevice) {
        self.device = device
        buildGeometryIfNeeded()
    }

    func buildIfNeeded(library: MTLLibrary, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        if pipeline == nil {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = true
            d.depthCompareFunction = .lessEqual
            depthState = device.makeDepthStencilState(descriptor: d)

            let rp = MTLRenderPipelineDescriptor()
            rp.label = "ProceduralTrees"
            rp.vertexFunction = library.makeFunction(name: "proceduralTreeVS")
            rp.fragmentFunction = library.makeFunction(name: "proceduralTreeFS")
            rp.colorAttachments[0].pixelFormat = colorPixelFormat
            rp.depthAttachmentPixelFormat = depthPixelFormat
            rp.colorAttachments[0].isBlendingEnabled = false
            pipeline = try? device.makeRenderPipelineState(descriptor: rp)

            let sp = MTLRenderPipelineDescriptor()
            sp.label = "ProceduralTreesShadow"
            sp.vertexFunction = library.makeFunction(name: "proceduralTreeShadowVS")
            sp.fragmentFunction = library.makeFunction(name: "proceduralTreeShadowFS")
            sp.depthAttachmentPixelFormat = depthPixelFormat
            shadowPipeline = try? device.makeRenderPipelineState(descriptor: sp)
        }
    }

    func ensureInstancesOnTerrain(terrain: TerrainSampler, maxInstances: Int) {
        let target = max(1, maxInstances)
        if instanceCount == target, instanceBuffer != nil { return }

        var instances: [Instance] = []
        instances.reserveCapacity(target)

        // Spawn around origin so it's immediately visible near (0,0,0),
        // but much wider and with a minimum spacing so it doesn't look like a carpet.
        let radius: Float = 260
        let minSpacing: Float = 9.5
        let minSpacing2 = minSpacing * minSpacing

        // Deterministic rejection sampling (fast enough for hundreds of trees).
        var attempts = 0
        var i = 0
        while instances.count < target, attempts < target * 40 {
            attempts += 1
            let fi = Float(i)
            i += 1

            let a = fract(sin(fi * 12.9898) * 43758.5453) * (Float.pi * 2)
            // Bias outward a bit: fewer trees in the center, more towards the edge.
            let rr = mix(0.25, 1.0, sqrt(fract(sin(fi * 78.233) * 31415.9265)))
            let r = rr * radius
            let x = cos(a) * r
            let z = sin(a) * r

            // Spacing check (2D).
            var ok = true
            for existing in instances {
                let dx = existing.position.x - x
                let dz = existing.position.z - z
                if dx * dx + dz * dz < minSpacing2 {
                    ok = false
                    break
                }
            }
            if !ok { continue }

            let y = terrain.height(x: x, z: z)
            let seed = fract(sin(fi * 91.7) * 10000.0)
            let scale = mix(2.8, 6.5, fract(sin(fi * 0.17) * 1000.0))
            let yaw = fract(sin(fi * 0.73) * 999.0) * (Float.pi * 2)
            instances.append(.init(position: SIMD3(x, y, z), scale: scale, yaw: yaw, seed: seed))
        }

        instanceCount = instances.count
        instanceBuffer = device.makeBuffer(bytes: instances, length: MemoryLayout<Instance>.stride * instances.count)

        // Conservative bounds for shadow culling.
        worldBounds = (min: SIMD3(-radius, -50, -radius), max: SIMD3(radius, 200, radius))
    }

    func drawShadow(encoder: MTLRenderCommandEncoder, lightViewProj: simd_float4x4) {
        guard let shadowPipeline, let vb, let instanceBuffer, instanceCount > 0, vertexCount > 0 else { return }
        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        var u = ProceduralTreeUniforms(viewProj: lightViewProj, time: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<ProceduralTreeUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: instanceCount)
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProj: simd_float4x4,
        cameraPos: SIMD3<Float>,
        time: Float,
        keyLight: SceneLighting.KeyLightFrame,
        shadowTexture: MTLTexture?,
        shadowSampler: MTLSamplerState?
    ) {
        guard let pipeline, let vb, let instanceBuffer, instanceCount > 0, vertexCount > 0 else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        var u = ProceduralTreeUniforms(viewProj: viewProj, time: time)
        encoder.setVertexBytes(&u, length: MemoryLayout<ProceduralTreeUniforms>.stride, index: 2)

        var fu = ProceduralTreeFragmentUniforms(
            cameraPosWS: cameraPos,
            sunDirectionWS: keyLight.directionWS,
            sunIntensity: max(max(keyLight.radianceLinear.x, keyLight.radianceLinear.y), keyLight.radianceLinear.z)
        )
        encoder.setFragmentBytes(&fu, length: MemoryLayout<ProceduralTreeFragmentUniforms>.stride, index: 0)
        if let shadowTexture, let shadowSampler {
            encoder.setFragmentTexture(shadowTexture, index: 0)
            encoder.setFragmentSamplerState(shadowSampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: instanceCount)
    }

    /// Call right before `draw(...)` if you want shadows on trees.
    func setLightViewProjForNextDraw(_ m: simd_float4x4, encoder: MTLRenderCommandEncoder) {
        var fu = ProceduralTreeLightVPUniforms(lightViewProj: m)
        encoder.setFragmentBytes(&fu, length: MemoryLayout<ProceduralTreeLightVPUniforms>.stride, index: 1)
    }

    // MARK: - Private

    private func buildGeometryIfNeeded() {
        if vb != nil { return }
        var v: [Vertex] = []
        v.reserveCapacity(4096)

        // Trunk: 8-sided cylinder (no caps to keep it minimal; looks OK in forest).
        appendCylinder(
            &v,
            radialSegments: 8,
            radius: 0.10,
            height: 1.15,
            materialID: 0
        )

        // Canopy: 3 low-poly "blobs" (octahedrons) stacked.
        appendOctaBlob(&v, center: SIMD3(0, 1.25, 0), r: SIMD3(0.65, 0.55, 0.65), materialID: 1)
        appendOctaBlob(&v, center: SIMD3(0.25, 1.55, 0.05), r: SIMD3(0.45, 0.42, 0.45), materialID: 1)
        appendOctaBlob(&v, center: SIMD3(-0.20, 1.62, -0.12), r: SIMD3(0.42, 0.38, 0.42), materialID: 1)

        vertexCount = v.count
        vb = device.makeBuffer(bytes: v, length: MemoryLayout<Vertex>.stride * v.count)
    }
}

@inline(__always) private func fract(_ x: Float) -> Float { x - floor(x) }
@inline(__always) private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

// Must match Metal shader layouts.
struct ProceduralTreeUniforms {
    var viewProj: simd_float4x4
    var time: Float
    var _pad0: SIMD3<Float> = .zero
}

struct ProceduralTreeFragmentUniforms {
    var cameraPosWS: SIMD3<Float>
    var _pad0: Float = 0
    var sunDirectionWS: SIMD3<Float>
    var sunIntensity: Float
}

// Separate buffer to avoid re-uploading a big matrix per draw call when not needed.
struct ProceduralTreeLightVPUniforms {
    var lightViewProj: simd_float4x4
}

// MARK: - Mesh helpers

private func appendCylinder(
    _ out: inout [ProceduralTreeRenderer.Vertex],
    radialSegments: Int,
    radius: Float,
    height: Float,
    materialID: UInt32
) {
    let n = max(3, radialSegments)
    for i in 0..<n {
        let a0 = (Float(i) / Float(n)) * (Float.pi * 2)
        let a1 = (Float(i + 1) / Float(n)) * (Float.pi * 2)
        let p00 = SIMD3<Float>(cos(a0) * radius, 0, sin(a0) * radius)
        let p10 = SIMD3<Float>(cos(a1) * radius, 0, sin(a1) * radius)
        let p01 = SIMD3<Float>(p00.x, height, p00.z)
        let p11 = SIMD3<Float>(p10.x, height, p10.z)
        let n0 = normalize(SIMD3<Float>(p00.x, 0, p00.z))
        let n1 = normalize(SIMD3<Float>(p10.x, 0, p10.z))

        // Two triangles per segment, CCW viewed from outside.
        out.append(.init(position: p00, normal: n0, materialID: materialID))
        out.append(.init(position: p01, normal: n0, materialID: materialID))
        out.append(.init(position: p11, normal: n1, materialID: materialID))

        out.append(.init(position: p00, normal: n0, materialID: materialID))
        out.append(.init(position: p11, normal: n1, materialID: materialID))
        out.append(.init(position: p10, normal: n1, materialID: materialID))
    }
}

private func appendOctaBlob(
    _ out: inout [ProceduralTreeRenderer.Vertex],
    center: SIMD3<Float>,
    r: SIMD3<Float>,
    materialID: UInt32
) {
    // Octahedron vertices.
    let top = center + SIMD3(0, r.y, 0)
    let bot = center - SIMD3(0, r.y, 0)
    let xp = center + SIMD3(r.x, 0, 0)
    let xn = center - SIMD3(r.x, 0, 0)
    let zp = center + SIMD3(0, 0, r.z)
    let zn = center - SIMD3(0, 0, r.z)

    func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        // Ensure consistent CCW winding as seen from outside.
        let centroid = (a + b + c) / 3
        var n = cross(b - a, c - a)
        // If the normal points towards the center, flip the triangle.
        if dot(n, centroid - center) < 0 {
            n = cross(c - a, b - a)
            out.append(.init(position: a, normal: normalize(n), materialID: materialID))
            out.append(.init(position: c, normal: normalize(n), materialID: materialID))
            out.append(.init(position: b, normal: normalize(n), materialID: materialID))
        } else {
            let nn = normalize(n)
            out.append(.init(position: a, normal: nn, materialID: materialID))
            out.append(.init(position: b, normal: nn, materialID: materialID))
            out.append(.init(position: c, normal: nn, materialID: materialID))
        }
    }

    // Top 4
    tri(top, xp, zp)
    tri(top, zp, xn)
    tri(top, xn, zn)
    tri(top, zn, xp)
    // Bottom 4
    tri(bot, zp, xp)
    tri(bot, xn, zp)
    tri(bot, zn, xn)
    tri(bot, xp, zn)
}

