import Metal
import MetalKit
import simd

/// Точка входа рендера: состояние кадра и подсистемы. Логика кадра — в `Renderer+*.swift`, простая геометрия — в `SolidColorMeshPass`.
final class Renderer: NSObject, MTKViewDelegate {
    // MARK: - Presentation

    var clearColor: MTLClearColor
    weak var hudSink: GameHUDSink?

    // MARK: - GPU core

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let solidPass: SolidColorMeshPass

    var depthState: MTLDepthStencilState?
    var skyDepthState: MTLDepthStencilState?
    var depthTexture: MTLTexture?
    /// Copy of depth used for sampling in water (avoid sampling the depth attachment directly).
    var depthTextureForSampling: MTLTexture?

    // MARK: - Frame / input

    var startTime: CFTimeInterval = CACurrentMediaTime()
    var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    var input = InputState()

    // MARK: - Subsystems

    let camera: FlyCamera
    let debugDraw: DebugDraw
    let environmentMap: EnvironmentMap
    let shadowMap: ShadowMapRenderer
    var skyRenderer: SkyRenderer?
    let frameEffects: FrameEffectsCoordinator
    let sunOcularGlare: SunOcularGlarePass

    // MARK: - Scene selection
    let scene: RenderScene

    // MARK: - HUD / debug

    var modelDebugLine: String?
    var hudAccum: Float = 0
    var hudFrames: Int = 0
    let debugShowShadowFactor = false

    // MARK: - Life cycle

    init(clearColor: MTLClearColor) {
        self.clearColor = clearColor

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this machine.")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create MTLCommandQueue.")
        }

        self.device = device
        self.commandQueue = commandQueue
        solidPass = SolidColorMeshPass(device: device)
        debugDraw = DebugDraw(device: device)
        environmentMap = EnvironmentMap(device: device, commandQueue: commandQueue)
        shadowMap = ShadowMapRenderer(device: device)
        camera = FlyCamera()
        frameEffects = FrameEffectsCoordinator(device: device)
        sunOcularGlare = SunOcularGlarePass(device: device)
        scene = WorldScene()

        super.init()

        modelDebugLine = scene.hudLine
    }

    func updateInput(_ input: InputState) {
        self.input = input
    }

    var hasRenderableScene: Bool {
        true
    }
}
