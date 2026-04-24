import Metal
import simd

extension SkinnedModelRenderer {
    // MARK: - Skinning

    func updateJoints(time: Float) {
        guard jointCount > 0 else { return }

        var trs = model.nodeLocalTRS
        if let anim = model.animation, anim.duration > 0 {
            let t = fmodf(time, anim.duration)
            for (node, track) in anim.translations { trs[node].t = sampleVec3(track: track, t: t) }
            for (node, track) in anim.scales { trs[node].s = sampleVec3(track: track, t: t) }
            for (node, track) in anim.rotations { trs[node].r = sampleQuat(track: track, t: t) }
        }

        var global: [simd_float4x4] = Array(repeating: matrix_identity_float4x4, count: trs.count)
        var computed: [Bool] = Array(repeating: false, count: trs.count)
        var visiting: [Bool] = Array(repeating: false, count: trs.count)

        func localMatrix(_ i: Int) -> simd_float4x4 {
            simd_float4x4.translation(trs[i].t) * simd_float4x4(trs[i].r) * simd_float4x4.scale(trs[i].s)
        }
        func compute(_ i: Int) -> simd_float4x4 {
            if computed[i] { return global[i] }
            if visiting[i] {
                global[i] = localMatrix(i)
                computed[i] = true
                return global[i]
            }
            visiting[i] = true
            let l = simd_float4x4.translation(trs[i].t) * simd_float4x4(trs[i].r) * simd_float4x4.scale(trs[i].s)
            if let p = model.parentIndex[i] { global[i] = compute(p) * l } else { global[i] = l }
            computed[i] = true
            visiting[i] = false
            return global[i]
        }
        for i in 0..<trs.count { _ = compute(i) }

        let meshGlobal = global[model.meshNodeIndex]
        let invMeshGlobal = meshGlobal.inverse

        if jointMatsScratch.count != jointCount {
            jointMatsScratch = Array(repeating: matrix_identity_float4x4, count: jointCount)
        }
        for j in 0..<jointCount {
            let nodeIndex = model.jointNodes[j]
            jointMatsScratch[j] = invMeshGlobal * global[nodeIndex] * model.inverseBindMatrices[j]
        }

        jointMatsScratch.withUnsafeBytes { bytes in
            memcpy(jointBuffer.contents(), bytes.baseAddress!, bytes.count)
        }
    }

    // MARK: - Animation sampling

    private func animationKeyframeIndex(times: [Float], t: Float, step: Bool) -> Int {
        if times.count <= 1 { return 0 }
        if t <= times[0] { return 0 }
        let last = times.count - 1
        if t >= times[last] { return last }
        if step {
            var k = 0
            for j in 1..<times.count where times[j] <= t { k = j }
            return k
        }
        var i = 0
        while i + 1 < times.count, times[i + 1] < t { i += 1 }
        return i
    }

    private func sampleVec3(track: GLBAnimation.TrackVec3, t: Float) -> SIMD3<Float> {
        let times = track.times
        let values = track.values
        guard times.count == values.count, !times.isEmpty else { return values.first ?? .zero }
        if times.count == 1 { return values[0] }
        let i = animationKeyframeIndex(times: times, t: t, step: track.step)
        if track.step { return values[i] }
        if i >= values.count - 1 { return values[i] }
        let t0 = times[i], t1 = times[i + 1]
        let a = (t - t0) / max(1e-6, (t1 - t0))
        return simd_mix(values[i], values[i + 1], SIMD3<Float>(repeating: a))
    }

    private func sampleQuat(track: GLBAnimation.TrackQuat, t: Float) -> simd_quatf {
        let times = track.times
        let values = track.values
        guard times.count == values.count, !times.isEmpty else { return values.first ?? simd_quatf(angle: 0, axis: [0, 1, 0]) }
        if times.count == 1 { return values[0] }
        let i = animationKeyframeIndex(times: times, t: t, step: track.step)
        if track.step { return values[i] }
        if i >= values.count - 1 { return values[i] }
        let t0 = times[i], t1 = times[i + 1]
        let a = (t - t0) / max(1e-6, (t1 - t0))
        return simd_slerp(values[i], values[i + 1], a)
    }
}
