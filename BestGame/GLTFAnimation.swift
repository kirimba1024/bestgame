import Foundation
import simd

enum GLTFAnimationParser {
    /// Одна клип из `gltf.animations[i]`.
    static func parseAnimation(gltf: GLTF, anim: GLTF.Animation, bin: Data) throws -> GLBAnimation? {
        var out = GLBAnimation(duration: 0)
        for ch in anim.channels {
            guard let nodeIndex = ch.target.node else { continue }
            guard ch.sampler >= 0 && ch.sampler < anim.samplers.count else { continue }
            if let nodes = gltf.nodes {
                guard nodeIndex >= 0 && nodeIndex < nodes.count else { continue }
            }

            let sampler = anim.samplers[ch.sampler]
            guard sampler.input >= 0 && sampler.input < gltf.accessors.count else { continue }
            guard sampler.output >= 0 && sampler.output < gltf.accessors.count else { continue }

            let interpUpper = sampler.interpolation?.uppercased() ?? "LINEAR"
            let step: Bool
            switch interpUpper {
            case "LINEAR": step = false
            case "STEP": step = true
            case "CUBICSPLINE": continue
            default: continue
            }

            let times = try GLTFAccessors.readScalarFloat(gltf: gltf, accessorIndex: sampler.input, bin: bin)
            out.duration = max(out.duration, times.last ?? 0)

            switch ch.target.path {
            case "translation":
                let vals = try GLTFAccessors.readVec3Float(gltf: gltf, accessorIndex: sampler.output, bin: bin)
                guard times.count == vals.count else { continue }
                out.translations[nodeIndex] = .init(times: times, values: vals, step: step)
            case "scale":
                let vals = try GLTFAccessors.readVec3Float(gltf: gltf, accessorIndex: sampler.output, bin: bin)
                guard times.count == vals.count else { continue }
                out.scales[nodeIndex] = .init(times: times, values: vals, step: step)
            case "rotation":
                let vals = try GLTFAccessors.readVec4Float(gltf: gltf, accessorIndex: sampler.output, bin: bin)
                guard times.count == vals.count else { continue }
                let quats = vals.map { v in simd_quatf(ix: v.x, iy: v.y, iz: v.z, r: v.w) }
                out.rotations[nodeIndex] = .init(times: times, values: quats, step: step)
            default:
                continue
            }
        }

        let hasKeys = !out.translations.isEmpty || !out.scales.isEmpty || !out.rotations.isEmpty
        guard hasKeys else { return nil }
        if out.duration <= 0 { out.duration = 1 }
        return out
    }

    static func parseFirstAnimation(gltf: GLTF, bin: Data) throws -> GLBAnimation? {
        guard let anim = gltf.animations?.first else { return nil }
        return try parseAnimation(gltf: gltf, anim: anim, bin: bin)
    }

    /// Все клипы с поддерживаемыми каналами (LINEAR/STEP); по очереди крутятся в рантайме.
    static func parseAllAnimations(gltf: GLTF, bin: Data) throws -> [GLBAnimation] {
        guard let list = gltf.animations, !list.isEmpty else { return [] }
        var out: [GLBAnimation] = []
        for anim in list {
            if let clip = try parseAnimation(gltf: gltf, anim: anim, bin: bin) {
                out.append(clip)
            }
        }
        return out
    }
}
