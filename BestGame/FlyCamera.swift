import simd
import CoreGraphics

final class FlyCamera {
    var position = SIMD3<Float>(0, 1.0, 5.0)
    var yaw: Float = 0
    var pitch: Float = 0

    var mouseSensitivity: Float = 0.003
    var baseMoveSpeed: Float = 4.0

    func update(dt: Float, input: InputState) {
        yaw += Float(input.mouseDelta.x) * mouseSensitivity
        pitch -= Float(input.mouseDelta.y) * mouseSensitivity
        pitch = min(1.55, max(-1.55, pitch))

        let speed = baseMoveSpeed * (input.isPressed(KeyCode.shift) ? 3.0 : 1.0)

        let forward = self.forward
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = normalize(cross(forward, worldUp))
        let up = normalize(cross(right, forward))

        var move = SIMD3<Float>(0, 0, 0)
        if input.isPressed(KeyCode.w) { move += forward }
        if input.isPressed(KeyCode.s) { move -= forward }
        if input.isPressed(KeyCode.d) { move += right }
        if input.isPressed(KeyCode.a) { move -= right }
        if input.isPressed(KeyCode.e) { move += up }
        if input.isPressed(KeyCode.q) { move -= up }

        if simd_length_squared(move) > 0 {
            position += normalize(move) * speed * dt
        }
    }

    var forward: SIMD3<Float> {
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        return normalize(SIMD3<Float>(sy * cp, sp, -cy * cp))
    }

    func viewMatrix() -> simd_float4x4 {
        simd_float4x4.lookAtRH(eye: position, forward: forward, upHint: SIMD3<Float>(0, 1, 0))
    }
}

