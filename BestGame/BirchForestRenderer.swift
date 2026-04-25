import Metal
import simd

/// Инстансинг берёз по правилам биома (высота/уклон/плотность) поверх `TerrainRenderer`.
final class BirchForestRenderer {
    struct Config {
        var halfSizeXZ: Float = 240
        var gridStep: Float = 6.2
        var maxInstances: Int = 9000

        var minHeight: Float = 2.0
        var maxHeight: Float = 24.0
        var maxSlope01: Float = 0.55 // 0 = flat, 1 = vertical wall

        var baseScale: Float = 1.65
        var scaleJitter: Float = 0.55
    }

    private let device: MTLDevice
    private let terrain: TerrainSampler
    private let cfg: Config

    private(set) var instanceBuffer: MTLBuffer
    private(set) var instanceCount: Int = 0
    private(set) var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (.zero, .zero)

    init(device: MTLDevice, terrain: TerrainSampler, config: Config = .init()) {
        self.device = device
        self.terrain = terrain
        self.cfg = config
        instanceBuffer = device.makeBuffer(length: max(1, config.maxInstances) * MemoryLayout<simd_float4x4>.stride, options: [.storageModeShared])!
        rebuildInstances()
    }

    func rebuildInstances() {
        let half = min(cfg.halfSizeXZ, terrain.config.halfSizeXZ * 0.98)
        let step = max(2.0, cfg.gridStep)

        let nx = Int((2 * half) / step)
        let nz = Int((2 * half) / step)

        var count = 0
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        let ptr = instanceBuffer.contents().assumingMemoryBound(to: simd_float4x4.self)

        for j in 0..<nz {
            for i in 0..<nx {
                if count >= cfg.maxInstances { break }

                let fx = Float(i), fz = Float(j)
                let u = (fx + hash2(fx, fz, seed: 3.1)) / max(1, Float(nx))
                let v = (fz + hash2(fx, fz, seed: 7.7)) / max(1, Float(nz))

                let x = (-half + u * (2 * half))
                let z = (-half + v * (2 * half))

                let y = terrain.height(x: x, z: z)
                if !(y.isFinite) { continue }
                if y < cfg.minHeight || y > cfg.maxHeight { continue }

                let n = terrain.normal(x: x, z: z, step: 1.25)
                let slope01 = saturate(1.0 - n.y)
                if slope01 > cfg.maxSlope01 { continue }

                // Density mask: small clearings + altitude fade.
                let d0 = hash2(x * 0.07, z * 0.07, seed: 19.0)
                if d0 < 0.22 { continue }
                let altitudeT = saturate((y - cfg.minHeight) / max(1e-3, (cfg.maxHeight - cfg.minHeight)))
                if hash2(x, z, seed: 23.0) < mix(0.10, 0.30, altitudeT) { continue }

                let yaw = (hash2(fx, fz, seed: 11.0) * 2 - 1) * .pi
                let s = cfg.baseScale * (1.0 + (hash2(fx, fz, seed: 13.0) * 2 - 1) * cfg.scaleJitter)
                let lift: Float = 0.02
                let M =
                    simd_float4x4.translation(SIMD3(x, y + lift, z))
                    * simd_float4x4.rotation(radians: yaw, axis: SIMD3(0, 1, 0))
                    * simd_float4x4.scale(SIMD3(repeating: s))

                ptr[count] = M
                let p = SIMD3<Float>(x, y, z)
                bmin = simd_min(bmin, p)
                bmax = simd_max(bmax, p)
                count += 1
            }
            if count >= cfg.maxInstances { break }
        }

        instanceCount = count
        if count == 0 {
            worldBounds = (min: .zero, max: .zero)
        } else {
            // Conservative vertical padding for tree height.
            worldBounds = (min: bmin - SIMD3(4, 0.5, 4), max: bmax + SIMD3(4, 24, 4))
        }
    }

    // MARK: - Helpers

    private func hash2(_ a: Float, _ b: Float, seed: Float) -> Float {
        let x = sin(a * 12.9898 + b * 78.233 + seed * 45.164) * 43758.5453
        return x - floor(x)
    }

    private func saturate(_ x: Float) -> Float { min(1, max(0, x)) }
    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
}

