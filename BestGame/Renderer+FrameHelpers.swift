import MetalKit
import simd

extension Renderer {
    struct FrameStep {
        var now: CFTimeInterval
        var dt: Float
        var time: Float
        var angle: Float
    }

    struct ViewMatrices {
        var aspect: Float
        var proj: simd_float4x4
        var view: simd_float4x4
        var viewProj: simd_float4x4
    }

    func stepFrame(now: CFTimeInterval) -> FrameStep {
        let elapsed = Float(max(0, now - lastFrameTime))
        let dt = min(RendererFrameTiming.maxDeltaTimeSeconds, elapsed)
        lastFrameTime = now
        camera.update(dt: dt, input: input)

        let time = Float(now - startTime)
        let angle = time * RendererFrameTiming.cubeRotationMultiplier
        return .init(now: now, dt: dt, time: time, angle: angle)
    }

    func updateHUD(dt: Float, drawableSize: CGSize) {
        hudAccum += dt
        hudFrames += 1
        if hudAccum >= RendererFrameTiming.hudRefreshIntervalSeconds, let hud = hudSink {
            hud.setHUDText(RendererHUDFormatting.formatHUDText(
                fps: Float(hudFrames) / max(1e-6, hudAccum),
                frameMs: (hudAccum / Float(hudFrames)) * 1000,
                drawableSize: drawableSize,
                modelLine: modelDebugLine
            ))
            hudAccum = 0
            hudFrames = 0
        }
    }

    func makeViewMatrices(drawableSize: CGSize) -> ViewMatrices {
        let aspect = max(1e-3, Float(drawableSize.width / max(drawableSize.height, 1)))
        let proj = simd_float4x4.perspectiveRH(
            fovyRadians: RendererFrameTiming.verticalFieldOfViewRadians,
            aspect: aspect,
            nearZ: RendererFrameTiming.depthNear,
            farZ: RendererFrameTiming.depthFar
        )
        let viewM = camera.viewMatrix()
        return .init(aspect: aspect, proj: proj, view: viewM, viewProj: proj * viewM)
    }

    func makeEffectContext(step: FrameStep, mats: ViewMatrices) -> FrameEffectContext {
        @inline(__always)
        func safeNormalize(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
            let l2 = simd_length_squared(v)
            guard l2.isFinite, l2 > 1e-10 else { return fallback }
            return v / sqrt(l2)
        }

        let anchors = scene.effectsAnchor(time: step.time)

        // Billboard basis must be in world space.
        let invView = mats.view.inverse
        let invRightRaw = SIMD3<Float>(invView.columns.0.x, invView.columns.0.y, invView.columns.0.z)
        let invUpRaw = SIMD3<Float>(invView.columns.1.x, invView.columns.1.y, invView.columns.1.z)

        let fwd = safeNormalize(camera.forward, fallback: SIMD3<Float>(0, 0, -1))
        let worldUp = SIMD3<Float>(0, 1, 0)
        let altUp = SIMD3<Float>(0, 0, 1)
        let upHint = abs(dot(fwd, worldUp)) > 0.97 ? altUp : worldUp
        let fallbackRight = safeNormalize(cross(fwd, upHint), fallback: SIMD3<Float>(1, 0, 0))
        let fallbackUp = safeNormalize(cross(fallbackRight, fwd), fallback: SIMD3<Float>(0, 1, 0))

        let camRight = safeNormalize(invRightRaw, fallback: fallbackRight)
        let camUp = safeNormalize(invUpRaw, fallback: fallbackUp)

        return FrameEffectContext(
            time: step.time,
            deltaTime: step.dt,
            viewProjection: mats.viewProj,
            viewMatrix: mats.view,
            projectionMatrix: mats.proj,
            cameraPosition: camera.position,
            cameraRight: camRight,
            cameraUp: camUp,
            showcaseFocalPoint: anchors.showcaseFocal,
            effectsAnchorPoint: anchors.effectsAnchor,
            hasSceneContent: hasRenderableScene
        )
    }

    func applyBaseRasterState(_ encoder: MTLRenderCommandEncoder) {
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
    }

    func drawSkyIfNeeded(encoder: MTLRenderCommandEncoder, mats: ViewMatrices, keyLight: SceneLighting.KeyLightFrame) {
        guard let skyRenderer else { return }
        encoder.setDepthStencilState(skyDepthState)
        skyRenderer.draw(
            encoder: encoder,
            uniforms: .init(
                invViewProj: mats.viewProj.inverse,
                cameraPosWS: camera.position,
                sunDirWS: keyLight.directionWS,
                sunDiskRadianceHDR: SceneLighting.hdrSunRadiance
            )
        )
        encoder.setDepthStencilState(depthState)
    }
}

