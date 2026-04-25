import Foundation
import simd

final class WorldHeightmapAsset {
    struct Header: Codable {
        var version: Int
        var resolution: Int
        var halfSizeXZ: Float
        var createdAtUnix: Int
    }

    let header: Header
    private let heights: [Float] // row-major [z][x], length = resolution*resolution

    init(header: Header, heights: [Float]) {
        self.header = header
        self.heights = heights
    }

    func heightBilinear(x: Float, z: Float, config: TerrainRenderer.Config) -> Float {
        let n = max(2, header.resolution)
        let half = header.halfSizeXZ
        if n < 2 { return 0 }

        // Map world x,z -> grid space [0..n-1]
        let gx = (x + half) / max(1e-6, (2 * half)) * Float(n - 1)
        let gz = (z + half) / max(1e-6, (2 * half)) * Float(n - 1)

        let x0 = Int(floor(gx))
        let z0 = Int(floor(gz))
        let x1 = min(n - 1, x0 + 1)
        let z1 = min(n - 1, z0 + 1)

        let ix0 = max(0, min(n - 1, x0))
        let iz0 = max(0, min(n - 1, z0))
        let tx = gx - Float(ix0)
        let tz = gz - Float(iz0)

        let h00 = heights[iz0 * n + ix0]
        let h10 = heights[iz0 * n + x1]
        let h01 = heights[z1 * n + ix0]
        let h11 = heights[z1 * n + x1]

        let hx0 = h00 + (h10 - h00) * tx
        let hx1 = h01 + (h11 - h01) * tx
        return hx0 + (hx1 - hx0) * tz
    }

    static func loadOrGenerate(
        worldID: String,
        config: TerrainRenderer.Config,
        generator: (_ x: Float, _ z: Float, _ cfg: TerrainRenderer.Config) -> Float
    ) -> WorldHeightmapAsset {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BestGame", isDirectory: true)
            .appendingPathComponent("WorldMaps", isDirectory: true)
            .appendingPathComponent(worldID, isDirectory: true)

        try? fm.createDirectory(at: base, withIntermediateDirectories: true)

        let metaURL = base.appendingPathComponent("heightmap.json")
        let binURL = base.appendingPathComponent("heightmap.f32")

        if let metaData = try? Data(contentsOf: metaURL),
           let header = try? JSONDecoder().decode(Header.self, from: metaData),
           header.version == 1,
           header.resolution == config.resolution,
           abs(header.halfSizeXZ - config.halfSizeXZ) < 1e-3,
           let bin = try? Data(contentsOf: binURL)
        {
            let expected = header.resolution * header.resolution * MemoryLayout<Float>.stride
            if bin.count == expected {
                let heights = bin.withUnsafeBytes { raw -> [Float] in
                    Array(raw.bindMemory(to: Float.self))
                }
                return WorldHeightmapAsset(header: header, heights: heights)
            }
        }

        let n = max(2, config.resolution)
        let half = config.halfSizeXZ
        let step = (2 * half) / Float(n - 1)

        var heights: [Float] = Array(repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let x = -half + Float(i) * step
                let z = -half + Float(j) * step
                heights[j * n + i] = generator(x, z, config)
            }
        }

        let header = Header(
            version: 1,
            resolution: n,
            halfSizeXZ: config.halfSizeXZ,
            createdAtUnix: Int(Date().timeIntervalSince1970)
        )

        if let metaData = try? JSONEncoder().encode(header) {
            try? metaData.write(to: metaURL, options: [.atomic])
        }
        let bin = heights.withUnsafeBytes { Data($0) }
        try? bin.write(to: binURL, options: [.atomic])

        return WorldHeightmapAsset(header: header, heights: heights)
    }
}

