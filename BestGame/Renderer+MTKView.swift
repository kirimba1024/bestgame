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
        let dt = min(RendererFrameTiming.maxDeltaTimeSeconds, elapsed)
        lastFrameTime = now
        camera.update(dt: dt, input: input)

        hudAccum += dt
        hudFrames += 1
        if hudAccum >= RendererFrameTiming.hudRefreshIntervalSeconds, let hud = hudSink {
            hud.setHUDText(RendererHUDFormatting.formatHUDText(
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
            renderPassDescriptor.depthAttachment.storeAction = .store
        }

        let time = Float(now - startTime)
        let angle = time * RendererFrameTiming.cubeRotationMultiplier

        let aspect = max(1e-3, Float(view.drawableSize.width / max(view.drawableSize.height, 1)))
        let proj = simd_float4x4.perspectiveRH(
            fovyRadians: RendererFrameTiming.verticalFieldOfViewRadians,
            aspect: aspect,
            nearZ: RendererFrameTiming.depthNear,
            farZ: RendererFrameTiming.depthFar
        )
        let viewM = camera.viewMatrix()
        let viewProj = proj * viewM

        let keyLight = SceneLighting.keyLight(atTime: time)
        let shelf = scenePlacement.computeShelfFrame(
            staticAssetNames: staticPBRAssetNames,
            staticHeroScale: staticSlotHeroScale,
            staticRendererCount: staticPBRRenderers.count,
            skinnedAssetNames: skinnedPBRAssetNames,
            skinnedRendererCount: skinnedRenderers.count,
            hasFoxMeshFallback: solidPass.glbVertexBuffer != nil && solidPass.glbIndexCount > 0
        )

        let showcaseFocal: SIMD3<Float>
        let effectsAnchor: SIMD3<Float>
        if hasRenderableScene {
            let cx = (shelf.slotSpanMinX + shelf.slotSpanMaxX) * 0.5
            let z = scenePlacement.shelfConfig.sceneDepthZ + 4.3
            showcaseFocal = SIMD3(
                cx + sin(time * 0.95) * 2.4,
                4.05 + sin(time * 1.25) * 0.45,
                z + cos(time * 0.72) * 1.6
            )
            // Вбок от полки по +X за крайний слот — частицы/светлячки.
            let lateral = shelf.slotSpanMaxX + 22
            effectsAnchor = SIMD3(
                lateral,
                showcaseFocal.y - 0.6,
                showcaseFocal.z - 7
            )
        } else {
            showcaseFocal = SIMD3(sin(time * 0.9) * 1.2, 1.85 + sin(time * 1.1) * 0.2, -4.2 + cos(time * 0.5) * 0.35)
            effectsAnchor = showcaseFocal + SIMD3(6, 0, -3)
        }

        let camRight = normalize(SIMD3<Float>(viewM.columns.0.x, viewM.columns.0.y, viewM.columns.0.z))
        let camUp = normalize(SIMD3<Float>(viewM.columns.1.x, viewM.columns.1.y, viewM.columns.1.z))
        let effectContext = FrameEffectContext(
            time: time,
            deltaTime: dt,
            viewProjection: viewProj,
            viewMatrix: viewM,
            projectionMatrix: proj,
            cameraPosition: camera.position,
            cameraRight: camRight,
            cameraUp: camUp,
            showcaseFocalPoint: showcaseFocal,
            effectsAnchorPoint: effectsAnchor,
            hasSceneContent: hasRenderableScene
        )
        frameEffects.encodeAllCompute(into: commandBuffer, context: effectContext)

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
                let modelM = scenePlacement.staticWorldModelMatrix(
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
                let style = scenePlacement.skinnedStyle(assetName: assetName)
                let baseY = scenePlacement.shelfConfig.heroRestHeightY + style.extraLiftY
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
                    let grid = scenePlacement.foxInstancingGrid(origin: origin)
                    skinned.drawInstances(encoder: encoder, baseParams: baseParams, translations: grid)
                } else {
                    var one = baseParams
                    one.modelTranslation = origin
                    skinned.draw(encoder: encoder, params: one)
                }
            }

            if skinnedRenderers.isEmpty, let foxX = shelf.foxMeshDebugSlotCenterX, solidPass.glbIndexCount > 0 {
                let foxY = scenePlacement.shelfConfig.heroRestHeightY + scenePlacement.shelfConfig.foxGridExtraLiftY
                let baseT = simd_float4x4.translation([0, foxY, scenePlacement.shelfConfig.sceneDepthZ])
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

            let groundM = scenePlacement.groundWorldMatrix(shelf: shelf)
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
            if let depthTexture, let river = riverWaterRenderer {
                river.draw(
                    encoder: encoder,
                    viewProj: viewProj,
                    cameraPos: camera.position,
                    time: time,
                    sunDirectionWS: keyLight.directionWS,
                    viewportWidth: Float(view.drawableSize.width),
                    viewportHeight: Float(view.drawableSize.height),
                    shelf: shelf,
                    config: scenePlacement.shelfConfig,
                    depthTexture: depthTexture,
                    environmentTexture: environmentMap.texture,
                    environmentSampler: environmentMap.sampler,
                    keyLightBytes: SceneLighting.KeyLightGPUBytes(keyLight)
                )
            }
            grassRenderer?.ensureInstances(shelf: shelf, config: scenePlacement.shelfConfig)
            grassRenderer?.draw(
                encoder: encoder,
                viewProj: viewProj,
                cameraPos: camera.position,
                time: time,
                sunDirectionWS: keyLight.directionWS
            )
            let probeM = scenePlacement.materialProbeWorldMatrix(shelf: shelf)
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

        frameEffects.encodeAllPostOpaqueDraws(encoder: encoder, context: effectContext)

        let axisNDCs = WorldAxesGizmo.axisLabelNDCs(proj: proj, view: viewM)
        let sink = hudSink
        DispatchQueue.main.async {
            sink?.updateAxisLegendNDCPositions(x: axisNDCs.x, y: axisNDCs.y, z: axisNDCs.z)
        }

        encoder.endEncoding()

        sunOcularGlare.encode(
            commandBuffer: commandBuffer,
            drawableTexture: drawable.texture,
            drawableAspect: aspect,
            viewProjection: viewProj,
            cameraPosition: camera.position,
            sunDirectionWS: keyLight.directionWS,
            cameraForward: camera.forward
        )

        let overlayDesc = MTLRenderPassDescriptor()
        overlayDesc.colorAttachments[0].texture = drawable.texture
        overlayDesc.colorAttachments[0].loadAction = .load
        overlayDesc.colorAttachments[0].storeAction = .store
        if let depthTexture {
            overlayDesc.depthAttachment.texture = depthTexture
            overlayDesc.depthAttachment.loadAction = .load
            overlayDesc.depthAttachment.storeAction = .dontCare
        }

        if let pipe = solidPass.simpleColorPipeline,
           depthTexture != nil,
           let overlayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: overlayDesc)
        {
            overlayEncoder.setDepthStencilState(skyDepthState)
            let gizmoMVP = WorldAxesGizmo.modelViewProj(proj: proj, view: viewM)
            debugDraw.drawWorldAxesOverlay(encoder: overlayEncoder, pipeline: pipe, modelViewProj: gizmoMVP)
            overlayEncoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        hudSink?.flushPerFrameInputEnd()
    }
}
