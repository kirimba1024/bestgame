import Foundation
import simd

enum GLTFAnimationParser {
    static func parseFirstAnimation(gltf: GLTF, bin: Data) throws -> GLBAnimation? {
        guard let anim = gltf.animations?.first else { return nil }

        var out = GLBAnimation(duration: 0)
        for ch in anim.channels {
            guard let nodeIndex = ch.target.node else { continue }
            let sampler = anim.samplers[ch.sampler]
            let times = try GLTFAccessors.readScalarFloat(gltf: gltf, accessorIndex: sampler.input, bin: bin)
            out.duration = max(out.duration, times.last ?? 0)

            switch ch.target.path {
            case "translation":
                let vals = try GLTFAccessors.readVec3Float(gltf: gltf, accessorIndex: sampler.output, bin: bin)
                out.translations[nodeIndex] = .init(times: times, values: vals)
            case "scale":
                let vals = try GLTFAccessors.readVec3Float(gltf: gltf, accessorIndex: sampler.output, bin: bin)
                out.scales[nodeIndex] = .init(times: times, values: vals)
            case "rotation":
                let vals = try GLTFAccessors.readVec4Float(gltf: gltf, accessorIndex: sampler.output, bin: bin)
                let quats = vals.map { v in simd_quatf(ix: v.x, iy: v.y, iz: v.z, r: v.w) }
                out.rotations[nodeIndex] = .init(times: times, values: quats)
            default:
                continue
            }
        }
        return out
    }
}

