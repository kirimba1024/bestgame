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

        let step = stepFrame(now: CACurrentMediaTime())
        updateHUD(dt: step.dt, drawableSize: view.drawableSize)

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

        let mats = makeViewMatrices(drawableSize: view.drawableSize)

        let keyLight = SceneLighting.keyLight(atTime: step.time)
        let effectContext = makeEffectContext(step: step, mats: mats)
        frameEffects.encodeAllCompute(into: commandBuffer, context: effectContext)

        let lightViewProj = makeLightViewProj(sunDir: keyLight.directionWS)

        shadowMap.render(into: commandBuffer) { encoder in
            drawShadowCasters(encoder: encoder, lightViewProj: lightViewProj, time: step.time)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        encoder.setDepthStencilState(depthState)
        drawSkyIfNeeded(encoder: encoder, mats: mats, keyLight: keyLight)
        applyBaseRasterState(encoder)

        let debugMode: UInt32 = debugShowShadowFactor ? 1 : 0

        if hasRenderableScene {
            scene.draw(
                encoder: encoder,
                proj: mats.proj,
                view: mats.view,
                viewProj: mats.viewProj,
                lightViewProj: lightViewProj,
                cameraPos: camera.position,
                time: step.time,
                keyLight: keyLight,
                shadowTexture: shadowMap.texture,
                shadowSampler: shadowMap.compareSampler,
                environment: environmentMap,
                depthTexture: depthTexture,
                drawableSize: view.drawableSize
            )
            // Restore default depth state for anything else (effects overlay, etc.).
            encoder.setDepthStencilState(depthState)
            applyBaseRasterState(encoder)

            // Keep basic primitives visible even in world mode (useful for debugging / sanity checks).
            solidPass.encodeRotatingCube(
                encoder: encoder,
                proj: mats.proj,
                view: mats.view,
                angle: step.angle,
                translation: SIMD3<Float>(-36, 16, -40),
                scale: 2.2
            )
        } else {
            solidPass.encodeRotatingCube(encoder: encoder, proj: mats.proj, view: mats.view, angle: step.angle)
        }

        frameEffects.encodeAllPostOpaqueDraws(encoder: encoder, context: effectContext)

        let axisNDCs = WorldAxesGizmo.axisLabelNDCs(proj: mats.proj, view: mats.view)
        let sink = hudSink
        DispatchQueue.main.async {
            sink?.updateAxisLegendNDCPositions(x: axisNDCs.x, y: axisNDCs.y, z: axisNDCs.z)
        }

        encoder.endEncoding()

        sunOcularGlare.encode(
            commandBuffer: commandBuffer,
            drawableTexture: drawable.texture,
            drawableAspect: mats.aspect,
            viewProjection: mats.viewProj,
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
            let gizmoMVP = WorldAxesGizmo.modelViewProj(proj: mats.proj, view: mats.view)
            debugDraw.drawWorldAxesOverlay(encoder: overlayEncoder, pipeline: pipe, modelViewProj: gizmoMVP)
            overlayEncoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        hudSink?.flushPerFrameInputEnd()
    }
}
