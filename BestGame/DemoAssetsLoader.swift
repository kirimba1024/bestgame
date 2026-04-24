import Foundation

/// Загрузка демо-ассетов из бандла (без Metal и без кадрового цикла).
enum DemoAssetsLoader {
    private enum Resource {
        static let damagedHelmet = "DamagedHelmet"
        static let fox = "Fox"
    }

    struct Loaded {
        var pendingStaticPBRModels: [GLBStaticModel] = []
        var staticPBRAssetNames: [String] = []
        var pendingSkinnedModel: GLBSkinnedModel?
        var foxStaticMesh: GLBStaticMesh?
        /// Строка для HUD; `nil`, если нечего показать.
        var modelDebugLine: String?
    }

    static func loadDefaultScene() -> Loaded {
        var loaded = Loaded()

        if let model = try? GLBLoader.loadStaticModel(named: Resource.damagedHelmet) {
            loaded.pendingStaticPBRModels.append(model)
            loaded.staticPBRAssetNames.append(Resource.damagedHelmet)
        }

        if let skinned = try? GLBLoader.loadSkinnedModel(named: Resource.fox) {
            loaded.pendingSkinnedModel = skinned
        } else if let mesh = try? GLBLoader.loadStaticMesh(named: Resource.fox) {
            loaded.foxStaticMesh = mesh
        }

        loaded.modelDebugLine = makeSceneHUDLine(
            staticModels: loaded.pendingStaticPBRModels,
            hasSkinnedFox: loaded.pendingSkinnedModel != nil,
            hasFoxMesh: loaded.foxStaticMesh != nil
        )
        return loaded
    }

    private static func makeSceneHUDLine(
        staticModels: [GLBStaticModel],
        hasSkinnedFox: Bool,
        hasFoxMesh: Bool
    ) -> String? {
        var parts: [String] = []
        if !staticModels.isEmpty {
            parts.append("\(staticModels.count)× PBR static (glTF)")
        }
        if hasSkinnedFox {
            parts.append("Fox skinned")
        } else if hasFoxMesh {
            parts.append("Fox mesh (debug)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
