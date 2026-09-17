import Foundation

/// 一个拍摄场景预设。
///
/// 场景同时服务两侧：
///   - **拍摄侧**：给出建议的曝光补偿 `exposureBias` 与色温 `whiteBalanceKelvin`，
///     切场景时直接进 `CapturePreset`；
///   - **修图侧**：推荐一套风格或滤镜（`styleId` / `filterId`）。
///
/// ⚠️ 同一个场景的 `styleId` 与 `filterId` **不会同时有值** ——
/// 要么推荐风格，要么推荐滤镜（两者都可能是 nil，如"风景"只推滤镜）。这与原型一致。
///
/// 真源：网页原型 `prototype/index.html` 的 `SCENES` 数组，由 `tools/check_presets.js` 比对。
struct ScenePreset: Identifiable, Equatable, Codable {

    let id: String
    let displayName: String
    /// 推荐的风格 id（可为 nil）
    let styleId: String?
    /// 推荐的滤镜 id（可为 nil）
    let filterId: String?
    /// 建议的曝光补偿（EV）
    let exposureBias: Double
    /// 建议的白平衡色温（K）
    let whiteBalanceKelvin: Double
}

/// 场景目录 —— 5 个场景的真源
enum SceneCatalog {

    static let all: [ScenePreset] = [
        ScenePreset(id: "portrait",  displayName: "人像",
                    styleId: "portra160",     filterId: nil,
                    exposureBias:  0.33, whiteBalanceKelvin: 5600),

        ScenePreset(id: "landscape", displayName: "风景",
                    styleId: nil,             filterId: "f_vivid",
                    exposureBias: -0.33, whiteBalanceKelvin: 5200),

        ScenePreset(id: "food",      displayName: "美食",
                    styleId: "creamskin",     filterId: nil,
                    exposureBias:  0.33, whiteBalanceKelvin: 5200),

        ScenePreset(id: "night",     displayName: "夜景",
                    styleId: "tealorange",    filterId: nil,
                    exposureBias: -0.67, whiteBalanceKelvin: 4000),

        ScenePreset(id: "street",    displayName: "街拍",
                    styleId: "classicchrome", filterId: nil,
                    exposureBias:  0.00, whiteBalanceKelvin: 5000)
    ]

    static func scene(id: String?) -> ScenePreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// 与原型 `SCENES` 同构的机器可读 JSON，供 `tools/check_presets.js` 比对
    static func machineReadableJSON() -> String {
        var rows: [String] = []
        for s in all {
            let style = s.styleId.map { "\"\($0)\"" } ?? "null"
            let filter = s.filterId.map { "\"\($0)\"" } ?? "null"
            let wb = "\(PresetJSON.trim(s.whiteBalanceKelvin))K"
            rows.append("""
            {"id":"\(s.id)","name":"\(s.displayName)","style":\(style),\
            "filter":\(filter),"ev":\(PresetJSON.trim(s.exposureBias)),"wb":"\(wb)"}
            """)
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }
}
