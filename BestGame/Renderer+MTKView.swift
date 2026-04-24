import MetalKit
import QuartzCore
import simd

extension Renderer {
    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildDepthTextureIfNeeded(for: view, size: size)
    }

    func draw(in view: MTKView) {
        if solidPass.simpleColorPipeline == nil || depthState == nil {
            buildPipelineIfNeeded(for: view)
            rebuildDepthTextureIfNeeded(for: view, size: view.drawableSize)
        }

        let now = CACurrentMediaTime()
        let elapsed = Float(max(0, now - lastFrameTime))
        let dt = min(FrameTiming.maxDeltaTimeSeconds, elapsed)
        lastFrameTime = now
        camera.update(dt: dt, input: input)

        hudAccum += dt
        hudFrames += 1
        if hudAccum >= FrameTiming.hudRefreshIntervalSeconds, let hud = hudSink {
            hud.setHUDText(Self.formatHUDText(
                fps: Float(hudFrames) / max(1e-6, hudAccum),
                frameMs: (hudAccum / Float(hudFrames)) * 1000,
                drawableSize: view.drawableSize,
                modelLine: modelDebugLine
            ))
            hudAccum = 0
            hudFrames = 0
        }

        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        if let depthTexture {
            renderPassDescriptor.depthAttachment.texture = depthTexture
            renderPassDescriptor.depthAttachment.clearDepth = 1.0
            renderPassDescriptor.depthAttachment.loadAction = .clear
            renderPassDescriptor.depthAttachment.storeAction = .dontCare
        }

        let time = Float(now - startTime)
        let angle = time * FrameTiming.cubeRotationMultiplier

        let aspect = max(1e-3, Float(view.drawableSize.width / max(view.drawableSize.height, 1)))
        let proj = simd_float4x4.perspectiveRH(
            fovyRadians: FrameTiming.verticalFieldOfViewRadians,
            aspect: aspect,
            nearZ: FrameTiming.depthNear,
            farZ: FrameTiming.depthFar
        )
        let viewM = camera.viewMatrix()
        let viewProj = proj * viewM

        let keyLight = SceneLighting.keyLight(atTime: time)
        let shelf = DemoScenePlacements.computeShelfFrame(
            staticAssetNames: staticPBRAssetNames,
            staticHeroScale: staticSlotHeroScale,
            staticRendererCount: staticPBRRenderers.count,
            skinnedAssetNames: skinnedPBRAssetNames,
            skinnedRendererCount: skinnedRenderers.count,
            hasFoxMeshFallback: solidPass.glbVertexBuffer != nil && solidPass.glbIndexCount > 0,
            config: sceneShelfConfig
        )
        let lightViewProj = makeLightViewProj(sunDir: keyLight.directionWS, shelf: shelf, time: time)

        shadowMap.render(into: commandBuffer) { encoder in
            drawShadowCasters(encoder: encoder, lightViewProj: lightViewProj, time: time, shelf: shelf)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        encoder.setDepthStencilState(depthState)

        if let skyRenderer {
            encoder.setDepthStencilState(skyDepthState)
            skyRenderer.draw(
                encoder: encoder,
                uniforms: .init(
                    invViewProj: viewProj.inverse,
                    cameraPosWS: camera.position,
                    sunDirWS: keyLight.directionWS,
                    sunDiskRadianceHDR: SceneLighting.hdrSunRadiance
                )
            )
            encoder.setDepthStencilState(depthState)
        }

        let debugMode: UInt32 = debugShowShadowFactor ? 1 : 0

        if hasRenderableScene {
            for (index, staticRenderer) in staticPBRRenderers.enumerated() {
                let assetName = index < staticPBRAssetNames.count ? staticPBRAssetNames[index] : ""
                let modelM = DemoScenePlacements.staticWorldModelMatrix(
                    base: shelf.staticModelMatrices[index],
                    assetName: assetName,
                    time: time
                )
                staticRenderer.draw(
                    encoder: encoder,
                    params: .init(
                        proj: proj,
                        view: viewM,
                        cameraPosWS: camera.position,
                        model: modelM,
                        lightViewProj: lightViewProj,
                        keyLight: keyLight,
                        shadowTexture: shadowMap.texture,
                        shadowSampler: shadowMap.compareSampler,
                        debugMode: debugMode
                    )
                )
            }

            for (idx, skinned) in skinnedRenderers.enumerated() {
                guard idx < shelf.skinnedSlotCentersX.count, idx < shelf.skinnedSlotBaseZ.count else { continue }
                let cx = shelf.skinnedSlotCentersX[idx]
                let baseZ = shelf.skinnedSlotBaseZ[idx]
                let assetName = idx < skinnedPBRAssetNames.count ? skinnedPBRAssetNames[idx] : ""
                let style = DemoScenePlacements.skinnedStyle(assetName: assetName, config: sceneShelfConfig)
                let baseY = sceneShelfConfig.heroRestHeightY + style.extraLiftY
                let origin = SIMD3(cx, baseY, baseZ)
                let baseParams = SkinnedModelRenderer.DrawParams(
                    proj: proj,
                    view: viewM,
                    cameraPosWS: camera.position,
                    time: time,
                    modelTranslation: .zero,
                    modelScale: style.modelScale,
                    modelBasisRotation: style.modelBasisRotation,
                    lightViewProj: lightViewProj,
                    keyLight: keyLight,
                    shadowTexture: shadowMap.texture,
                    shadowSampler: shadowMap.compareSampler,
                    debugMode: debugMode
                )
                if style.useInstancingGrid {
                    let grid = DemoScenePlacements.foxInstancingGrid(origin: origin)
                    skinned.drawInstances(encoder: encoder, baseParams: baseParams, translations: grid)
                } else {
                    var one = baseParams
                    one.modelTranslation = origin
                    skinned.draw(encoder: encoder, params: one)
                }
            }

            if skinnedRenderers.isEmpty, let foxX = shelf.foxMeshDebugSlotCenterX, solidPass.glbIndexCount > 0 {
                let foxY = sceneShelfConfig.heroRestHeightY + sceneShelfConfig.foxGridExtraLiftY
                let baseT = simd_float4x4.translation([0, foxY, sceneShelfConfig.sceneDepthZ])
                let model =
                    baseT
                    * simd_float4x4.translation([foxX, 0, 0])
                    * simd_float4x4.scale([4, 4, 4])
                    * simd_float4x4.rotation(radians: .pi, axis: [0, 1, 0])
                _ = solidPass.encodeGLBFallbackIfReady(
                    encoder: encoder,
                    proj: proj,
                    view: viewM,
                    modelMatrix: model
                )
            }

            let groundM = DemoScenePlacements.groundWorldMatrix(shelf: shelf, config: sceneShelfConfig)
            groundPlaneRenderer?.draw(
                encoder: encoder,
                params: .init(
                    proj: proj,
                    view: viewM,
                    cameraPosWS: camera.position,
                    model: groundM,
                    lightViewProj: lightViewProj,
                    keyLight: keyLight,
                    shadowTexture: shadowMap.texture,
                    shadowSampler: shadowMap.compareSampler,
                    debugMode: debugMode
                )
            )
            let probeM = DemoScenePlacements.materialProbeWorldMatrix(shelf: shelf, config: sceneShelfConfig)
            materialProbeRenderer?.draw(
                encoder: encoder,
                params: .init(
                    proj: proj,
                    view: viewM,
                    cameraPosWS: camera.position,
                    model: probeM,
                    lightViewProj: lightViewProj,
                    keyLight: keyLight,
                    shadowTexture: shadowMap.texture,
                    shadowSampler: shadowMap.compareSampler,
                    debugMode: debugMode
                )
            )
        } else {
            solidPass.encodeRotatingCube(encoder: encoder, proj: proj, view: viewM, angle: angle)
        }

        if let pipe = solidPass.simpleColorPipeline {
            encoder.setDepthStencilState(skyDepthState)
            let gizmoMVP = WorldAxesGizmo.modelViewProj(proj: proj, view: viewM)
            debugDraw.drawWorldAxesOverlay(encoder: encoder, pipeline: pipe, modelViewProj: gizmoMVP)
            encoder.setDepthStencilState(depthState)
        }

        let axisNDCs = WorldAxesGizmo.axisLabelNDCs(proj: proj, view: viewM)
        let sink = hudSink
        DispatchQueue.main.async {
            sink?.updateAxisLegendNDCPositions(x: axisNDCs.x, y: axisNDCs.y, z: axisNDCs.z)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        hudSink?.flushPerFrameInputEnd()
    }

    // MARK: - HUD

    private static func formatHUDText(
        fps: Float,
        frameMs: Float,
        drawableSize: CGSize,
        modelLine: String?
    ) -> String {
        let w = drawableSize.width
        let h = drawableSize.height
        if let modelLine {
            return String(format: "FPS: %.1f  (%.2f ms)\nDrawable: %.0fx%.0f\n%@", fps, frameMs, w, h, modelLine)
        }
        return String(format: "FPS: %.1f  (%.2f ms)\nDrawable: %.0fx%.0f", fps, frameMs, w, h)
    }
}

// MARK: - Constants

private enum FrameTiming {
    /// Ограничение dt при лагах (стабильность симуляции камеры).
    static let maxDeltaTimeSeconds: Float = 1.0 / 20.0
    static let hudRefreshIntervalSeconds: Float = 0.35
    static let verticalFieldOfViewRadians: Float = 60 * (.pi / 180)
    static let depthNear: Float = 0.1
    /// Сцена + свободный полёт камеры легко уходят дальше 100 m — иначе клип → «дыры» и небо сквозь меши.
    static let depthFar: Float = 600
    static let cubeRotationMultiplier: Float = 0.9
}
