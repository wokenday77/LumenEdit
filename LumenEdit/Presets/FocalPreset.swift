import Foundation

/// 焦段档位：**13 / 24 / 35 / 48 / 120**（毫米，5 档）。
///
/// ⚠️ **毫米数是"标称标签"，不是换算依据** —— 换 `videoZoomFactor` 一律按**镜头角色**
/// 从设备读（`CaptureCapabilities.zoomFactor(forFocal:of:)`），**不做任何 mm 除法**。
/// 原因见 `FocalLensRole` 的说明（真机实测推翻了旧的"mm ÷ 基准"）。
///
/// 真机上这是**镜头切换 + 变焦**，属于 P2 的硬件活（走 `CaptureDeviceConfigurator`）。
/// 这里只定义"有哪些档位、顺序如何、默认选哪个"。
///
/// 真源：网页原型 `prototype/index.html` 的 `FOCALS`，由 `tools/check_presets.js` 第 4 组比对；
/// **Swift 先行扩展**的档位（目前是 35mm）必须标 `isSwiftExtension` —— 见那个字段的说明。
struct FocalPreset: Identifiable, Equatable, Codable {
    let id: String
    /// UI 显示文本（不带单位，单位由 UI 拼）
    let displayName: String
    /// 是否为默认选中的档位
    let isDefault: Bool

    /// 是否为 **Swift 先行扩展**的档位（原型 `FOCALS` 里还没有这一档）。
    ///
    /// 原型仍是档位数据的**真源**，但允许 Swift 侧先行扩展 —— 前提是**必须显式声明**。
    /// `tools/check_presets.js` 第 4 组就按这条口径比对（2026-09-19 用户拍板 · 见 `docs/17` 第八节）：
    ///
    ///   - **原型里有的档位** → 逐项一致（id / 显示名 / 默认选中），且本标记必须为 `false`；
    ///   - **Swift 多出来的档位** → 本标记必须为 `true`，且每次自检打印一行「原型尚未同步：…」；
    ///   - 两边一致之后（CB 补完原型、这里改回 `false`），第 4 组会**自动**要求完全一致。
    ///
    /// 这套做法的好处：把"原型没同步"从一个**看不见的差异**，变成**每次自检都会打印、
    /// 且必须显式声明**的状态 —— 既不会被静默放过，也不会因为"等原型"而阻塞 Swift。
    ///
    /// ⚠️ **必须是 `var`（不能是 `let`）**：`let` 带默认值的属性**不会**进 memberwise 初始化器，
    /// 传 `isSwiftExtension:` 会报 "extra argument"（2026-09-19 Mac 侧编译实测，[mac-fix]）。
    var isSwiftExtension: Bool = false

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
        // 35 与 48 是**同一类**：主摄内部的数码裁切，只是比例不同（35/24 与 48/24=2）。
        // 共用一条式子（见 `mainCropFactor`）比两处硬编码更难写错 —— 48 的值也一分不变。
        case 35, 48: return .mainCrop
        case 120: return .telephoto
        default: return nil
        }
    }

    /// 这一档相对**主摄原生视场**的裁切系数（只对 `.mainCrop` 角色有意义）。
    ///
    /// = `标称毫米数 ÷ 24`。
    ///
    /// 为什么除以 24：本套档位标签（13 / 24 / 35 / 48 / 120）本来就是按"**主摄 = 24mm**"
    /// 这组标称值定的（与原型 `FOCALS` 同源）。所以"同一颗主摄内部的裁切比例"就是标称焦距之比：
    ///
    ///   - 35mm 档 = `35/24 ≈ 1.458`
    ///   - 48mm 档 = `48/24 = 2`（正好是 48MP 传感器的 2× 裁切点）
    ///
    /// ⚠️ **24 是"标称基准"，不是探测值**：`AVCaptureDevice` **不暴露**镜头的绝对等效焦距
    /// （没有这个 API），拿不到真值。在用户那台机（主摄确实 24mm）上，35mm 档恰好等于 35.0mm；
    /// 若某机型主摄是 26mm，这一档实际约 **37.9mm**。
    ///
    /// 这条近似**不是本件引入的** —— 这套标签本来就有这个前提。B1 那次事故的错在于**锚点**
    /// （把基准当成 13mm 去硬除），不在于标签。本方案的口径是：
    /// **锚点全部取设备真值**（三颗镜头的原生视场），**比例只用于同一颗镜头内部**的裁切。
    var mainCropFactor: CGFloat? {
        guard let mm = millimeters else { return nil }
        return mm / 24
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
    /// **主摄内部的数码裁切**（35mm / 48mm 档）—— 比例由 `FocalPreset.mainCropFactor` 给，
    /// **不是一颗独立镜头**，所以不会出现在 `constituentDevices` 里。
    ///
    /// 2026-09-19 由 `.wideCrop2x` 改名而来（原写法把"×2"写死在名字和代码里）：
    /// 加了 35mm 档之后，"名字里带 2x"就成了谎言，而且两处硬编码容易只改一处。
    case mainCrop
    /// 长焦那颗的原生视场
    case telephoto

    /// 按"视场从最广到最长"排序用的名次。
    ///
    /// 只对能当 constituent 的角色（`ultraWide` / `wide` / `telephoto`）有意义 ——
    /// `mainCrop` 不是一颗镜头，永远不会出现在 constituent 列表里。
    var canonicalRank: Int {
        switch self {
        case .ultraWide: return 0
        case .wide: return 1
        case .mainCrop: return 2
        case .telephoto: return 3
        }
    }

    /// 中文名（日志 / toast 用）
    var displayName: String {
        switch self {
        case .ultraWide: return "超广角"
        case .wide: return "广角"
        case .mainCrop: return "主摄裁切"
        case .telephoto: return "长焦"
        }
    }
}

enum FocalCatalog {

    /// **5 档**，数组顺序即版式（焦段条从左到右）：超广角 / 主摄 / 主摄裁切 / 主摄裁切 / 长焦。
    ///
    /// ⚠️ **宽度账**（`docs/17` 第四节；自检第 11 组⑫守着，改档位前先看这里）：
    /// ```
    /// 总宽 = 档数 × 44（药丸宽 focalPillWidth） + (档数 − 1) × 9（间距 focalStripSpacing）
    /// 可用宽 = 屏宽 − 2 × 16（外层水平内缩 Spacing.md）
    /// 5 档 = 256pt；最窄机型 375 上可用 343 ⇒ 余 87pt ✓
    /// 上限：44n + 9(n−1) ≤ 343 → n ≤ 6.64 ⇒ 375 机型最多 6 档
    /// ```
    static let all: [FocalPreset] = [
        FocalPreset(id: "13",  displayName: "13",  isDefault: false),
        FocalPreset(id: "24",  displayName: "24",  isDefault: true),
        // 35mm 是 **Swift 先行扩展**（原型 `FOCALS` 仍是 4 档）→ 必须显式标 `isSwiftExtension`。
        // 见 `FocalPreset.isSwiftExtension` 的说明与 `tools/check_presets.js` 第 4 组。
        // 映射 = 主摄原生视场 × 35/24（**纯数码裁切**，不跨系统切换点、不换镜头）。
        FocalPreset(id: "35",  displayName: "35",  isDefault: false, isSwiftExtension: true),
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
