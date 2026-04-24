import Foundation

/// Загрузка демо-ассетов из бандла (без Metal и без кадрового цикла).
enum DemoAssetsLoader {
    private enum Resource {
        static let damagedHelmet = "DamagedHelmet"
        static let boomBox = "BoomBox"
        static let box = "Box"
        static let fox = "Fox"
        static let cesiumMan = "CesiumMan"
        static let riggedSimple = "RiggedSimple"
    }

    private static let staticCatalog: [(name: String, hero: Bool)] = [
        (Resource.boomBox, false),
        (Resource.box, false),
        (Resource.damagedHelmet, true),
    ]

    private static let skinnedCatalog: [String] = [
        Resource.fox,
        Resource.cesiumMan,
        Resource.riggedSimple,
    ]

    struct Loaded {
        var pendingStaticPBRModels: [GLBStaticModel] = []
        var staticPBRAssetNames: [String] = []
        var staticSlotIsHeroScale: [Bool] = []
        var pendingSkinnedModels: [GLBSkinnedModel] = []
        var skinnedPBRAssetNames: [String] = []
        var foxStaticMesh: GLBStaticMesh?
        /// Строка для HUD; `nil`, если нечего показать.
        var modelDebugLine: String?
    }

    static func loadDefaultScene() -> Loaded {
        var loaded = Loaded()

        for entry in staticCatalog {
            if let model = try? GLBLoader.loadStaticModel(named: entry.name) {
                loaded.pendingStaticPBRModels.append(model)
                loaded.staticPBRAssetNames.append(entry.name)
                loaded.staticSlotIsHeroScale.append(entry.hero)
            }
        }

        for name in skinnedCatalog {
            if let skinned = try? GLBLoader.loadSkinnedModel(named: name) {
                loaded.pendingSkinnedModels.append(skinned)
                loaded.skinnedPBRAssetNames.append(name)
            }
        }

        if loaded.pendingSkinnedModels.isEmpty, let mesh = try? GLBLoader.loadStaticMesh(named: Resource.fox) {
            loaded.foxStaticMesh = mesh
        }

        loaded.modelDebugLine = makeSceneHUDLine(loaded: loaded)
        return loaded
    }

    private static func makeSceneHUDLine(loaded: Loaded) -> String? {
        var parts: [String] = []
        if !loaded.pendingStaticPBRModels.isEmpty {
            parts.append("\(loaded.pendingStaticPBRModels.count)× PBR static")
        }
        if !loaded.pendingSkinnedModels.isEmpty {
            parts.append("\(loaded.pendingSkinnedModels.count)× skinned (\(loaded.skinnedPBRAssetNames.joined(separator: ", ")))")
        } else if loaded.foxStaticMesh != nil {
            parts.append("Fox mesh (debug)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
