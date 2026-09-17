import Foundation

/// 焦段档位（毫米）：超广角 / 主摄 / 长焦 / 5 倍长焦。
///
/// 真机上这是**镜头切换 + 变焦**，属于 P2 的硬件活（走 `CaptureDeviceConfigurator`）。
/// 这里只定义"有哪些档位、顺序如何、默认选哪个"；
/// **具体毫米数到 `videoZoomFactor` 的换算由设备能力决定**
/// （不同机型镜头不同，iPhone 16 与 16 Pro 的档位就不一样）。
///
/// 真源：网页原型 `prototype/index.html` 的 `FOCALS`，由 `tools/check_presets.js` 比对。
struct FocalPreset: Identifiable, Equatable, Codable {
    let id: String
    /// UI 显示文本（不带单位，单位由 UI 拼）
    let displayName: String
    /// 是否为默认选中的档位
    let isDefault: Bool
}

enum FocalCatalog {

    static let all: [FocalPreset] = [
        FocalPreset(id: "13",  displayName: "13",  isDefault: false),
        FocalPreset(id: "24",  displayName: "24",  isDefault: true),
        FocalPreset(id: "48",  displayName: "48",  isDefault: false),
        FocalPreset(id: "120", displayName: "120", isDefault: false)
    ]

    /// 默认档位
    static var defaultFocal: FocalPreset {
        all.first { $0.isDefault } ?? all[0]
    }

    /// 与原型 `FOCALS` 同构的机器可读 JSON
    static func machineReadableJSON() -> String {
        let rows = all.map { f -> String in
            let on = f.isDefault ? "true" : "null"
            return "{\"id\":\"\(f.id)\",\"name\":\"\(f.displayName)\",\"on\":\(on)}"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }
}
