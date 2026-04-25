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

    // MARK: - Scene (lazy GPU wrappers)

    var skinnedRenderers: [SkinnedModelRenderer] = []
    var pendingSkinnedModels: [GLBSkinnedModel] = []
    /// Имена скиннутых ассетов (порядок = слоты на полке; стиль слота — `scenePlacement.skinnedStyle`).
    var skinnedPBRAssetNames: [String] = []
    var pendingStaticPBRModels: [GLBStaticModel] = []
    var staticPBRAssetNames: [String] = []
    /// Параллельно `staticPBRRenderers`: крупный масштаб и подъём как у шлема.
    var staticSlotHeroScale: [Bool] = []
    var staticPBRRenderers: [StaticModelRenderer] = []
    /// Пол и сферы-пробы вне ряда слотов (отдельные матрицы).
    var groundPlaneRenderer: StaticModelRenderer?
    var materialProbeRenderer: StaticModelRenderer?
    var grassRenderer: GrassInstancedRenderer?
    var riverWaterRenderer: RiverWaterRenderer?

    // MARK: - HUD / debug

    var modelDebugLine: String?
    var hudAccum: Float = 0
    var hudFrames: Int = 0
    let debugShowShadowFactor = false

    // MARK: - Layout

    let scenePlacement: ScenePlacementProviding

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
        scenePlacement = DemoScenePlacementProvider()
        frameEffects = FrameEffectsCoordinator(device: device)
        sunOcularGlare = SunOcularGlarePass(device: device)

        super.init()

        let demo = DemoAssetsLoader.loadDefaultScene()
        pendingStaticPBRModels = demo.pendingStaticPBRModels
        staticPBRAssetNames = demo.staticPBRAssetNames
        staticSlotHeroScale = demo.staticSlotIsHeroScale
        pendingSkinnedModels = demo.pendingSkinnedModels
        skinnedPBRAssetNames = demo.skinnedPBRAssetNames
        if let mesh = demo.foxStaticMesh {
            solidPass.uploadFoxDebugMesh(mesh)
        }
        modelDebugLine = demo.modelDebugLine
    }

    func updateInput(_ input: InputState) {
        self.input = input
    }

    var hasRenderableScene: Bool {
        !staticPBRRenderers.isEmpty
            || !skinnedRenderers.isEmpty
            || (solidPass.glbVertexBuffer != nil && solidPass.glbIndexCount > 0)
    }
}
