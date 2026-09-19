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

    /// 等效焦距（mm）。
    ///
    /// 从 `id` 解析（`id` 本身就是 mm 字符串，见 `FocalCatalog.all`）——
    /// 不新增存储字段，避免与原型 `FOCALS` 的数据同源校验（`tools/check_presets.js` 第 4 组）
    /// 产生第二处真源。B1 用它换算 `videoZoomFactor`。
    var millimeters: CGFloat? {
        // ⚠️ 不能写 `CGFloat(Double(id))` —— `Double(id)` 是 `Double?`，
        // 而 `CGFloat` 没有接收 Optional 的初始化器（编译错误）
        guard let value = Double(id) else { return nil }
        return CGFloat(value)
    }

    /// 这一档代表的**镜头角色**（B1 修订 2026-09-19）。
    ///
    /// ⚠️ **毫米数只是 UI 标签，不是换算依据。** 换 `videoZoomFactor` 一律按角色从设备读
    /// （`CaptureCapabilities.zoomFactor(forFocal:of:)`），**不再做 `mm ÷ 基准`** ——
    /// 原因见下面的实测反证。
    var lensRole: FocalLensRole? {
        guard let mm = millimeters else { return nil }
        switch mm {
        case 13: return .ultraWide
        case 24: return .wide
        case 48: return .wideCrop2x
        case 120: return .telephoto
        default: return nil
        }
    }
}

/// 焦段档位对应的镜头角色。
///
/// **为什么需要它**（2026-09-19 Mac 侧真机实测反证了原来的"纯算术"方案）：
///
/// 实测某机型 `virtualDeviceSwitchOverVideoZoomFactors = [2.000, 10.000]`。
/// 2.0 与 10.0 正对着 24mm / 120mm 两颗镜头的等效焦距 ⇒ **它的虚拟基准是 12mm，不是 13mm**
/// （2.0 × 12 = 24 ✓，10.0 × 12 = 120 ✓，自洽）。
///
/// 而原方案写死"有超广角 → 基准 13mm"，于是 `mm ÷ 13` 整表偏小约 8%
/// （24 → 1.846 而不是 2.0；120 → 9.231 而不是 10.0）。最要命的一档是 120mm：
/// **9.231 落在 `switchOver[1] = 10.0` 之下 → 系统根本不会切到长焦**，
/// 只会继续用主摄数码放大（画质崩），而 UI 却显示"已切到 120mm"。
///
/// 按角色读设备就绕开了这个问题：**基准是 12 还是 13mm 不再需要知道**，
/// 而且"哪几档可用"顺带由设备自身的镜头构成决定（没有长焦 → 120mm 档置灰）。
enum FocalLensRole: String, CaseIterable {
    /// 超广角那颗的原生视场（虚拟设备的 `videoZoomFactor = 1.0`）
    case ultraWide
    /// 广角（主摄）那颗的原生视场
    case wide
    /// 广角那颗的原生视场 × 2 —— 传感器 2× 裁切，画质最优的那一档（**不是独立镜头**）
    case wideCrop2x
    /// 长焦那颗的原生视场
    case telephoto

    /// 按"视场从最广到最长"排序用的名次。
    ///
    /// 只对能当 constituent 的角色（`ultraWide` / `wide` / `telephoto`）有意义 ——
    /// `wideCrop2x` 不是一颗镜头，不会出现在 constituent 列表里。
    var canonicalRank: Int {
        switch self {
        case .ultraWide: return 0
        case .wide: return 1
        case .wideCrop2x: return 2
        case .telephoto: return 3
        }
    }

    /// 中文名（日志 / toast 用）
    var displayName: String {
        switch self {
        case .ultraWide: return "超广角"
        case .wide: return "广角"
        case .wideCrop2x: return "广角×2"
        case .telephoto: return "长焦"
        }
    }
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
