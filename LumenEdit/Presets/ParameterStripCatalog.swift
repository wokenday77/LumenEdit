import CoreGraphics
import Foundation

// MARK: - 三种刻度条

/// 参数排（展开态）里三条刻度条的种类 —— **同一时刻只显示一条**，由底部图标行切换。
///
/// 原型：`state.paramStrip ∈ {'iso','shutter','wb',null}`（单值寄存 = "一次一条"天然成立）。
/// 本件（B2a）只做数据层；UI 在 B2b。
enum ParameterStripKind: String, CaseIterable, Identifiable {
    case iso = "iso"
    case shutter = "shutter"
    case whiteBalance = "wb"

    var id: String { rawValue }

    /// 条名（toast / 日志用）。原型 `STRIPS[id].name`
    var displayName: String {
        switch self {
        case .iso: return "ISO"
        case .shutter: return "快门"
        case .whiteBalance: return "白平衡"
        }
    }
}

// MARK: - 档位

/// 刻度条上的一个档位。
///
/// `value` 是**直接写进硬件的物理量**：ISO 值 / 曝光秒数 / 色温 K —— 与焦段那套不同，
/// 这里**不需要任何换算**（焦段要按设备镜头角色换 `videoZoomFactor`）。
struct ParameterStripStep: Identifiable, Equatable {

    /// 原始值：ISO 值 / 曝光秒数 / 色温 K
    let value: Double
    /// 刻度下显示的文本（原型 `fmt`）
    let label: String
    /// 是否显示数字。**批六起恒为 `true`**（复刻飓风：每档都带标签）；
    /// 字段保留是为了将来若回到"只标主档"（原型 `labelAt` 那套）不必改结构。
    let showsLabel: Bool
    /// 白平衡的「预设档」（原型 `preset`：白炽灯/荧光灯/日光/阴天/阴影 → 琥珀色刻度）
    let isPreset: Bool

    var id: Double { value }
}

// MARK: - 目录（单一真源）

/// 参数刻度条数据 —— 三条条的**档位表 / 数值格式 / 可视步进 / 预设档**。
///
/// ## 2026-09-21 批六：**复刻飓风**（方案 A，用户拍板 —— 这是本文件的口径分水岭）
///
/// 用户口径原文：**"原始需求就是复刻飓风；之前的「细刻度」是基于错判参考图的产物；
/// 每档带标签才是飓风做法"**。因此：
///
/// | 量 | 飓风实测 | 旧口径 | 现在 |
/// |---|---|---|---|
/// | 档距 | 120px = **40.0pt/档** | ISO 46 / 快门 56 / WB 26 | **统一 40pt** |
/// | 刻度高 / 宽 | 42px = 14pt / 4px = 1.33pt，**每档同高** | 五档层级 22/15/10/6.5 | **单档 14 / 1.33** |
/// | 选中刻度 | 66px = 22pt（向上 +8pt）+ 加宽 2pt + 绿 | 三角指针 12×8 + 竖线 | **选中档加高加宽变绿** |
/// | 档间细刻度 | **无**（细:主 = 1:1） | 每条都加（批五 `hair`） | **删** |
/// | 每档标签 | **全部带**（≈11pt） | 只有 `labelAt` 的档 | **全标签**（字号维持 10.5） |
/// | 选中档标签 | 不放大 | — | **不放大** |
/// | 可视档数 | 8~9（滚动式） | — | 8~9（接受） |
///
/// 精度依据：全分辨率截图 1206×2622 = **402pt @3x**（用户给的飓风实测量，精确到 0.3pt）。
/// 402pt 屏、gutter 64 → 可视 (402−64)/40 = **8.45 档**，与"8~9"吻合。
///
/// ⚠️ **作废**：旧 `reference/video-frames-2026-09-16`（contact sheet）推出的
/// 「9~10 条细刻度 / 细:主 1:2」已作废（那就是"错判参考图"的产物，别再拿它当依据）。
///
/// ## ⚠️ 与原型的关系：**Swift 先行 + 标记**（用户 2026-09-21 拍板路由）
///
/// 原型 `prototype/index.html` 归 CB 改（WB 端**只读不写**），所以本文件先按飓风口径落地，
/// 由 `isSwiftAheadOfPrototype` 显式标记"我领先原型"：
/// `tools/check_presets.js` 第 6 组见到该标记会把手上的逐条比对**降级为 WARN**
/// 并打印差异清单（= CB 的待办）；**CB 同步完原型后必须把标记改回 `false`**，
/// 那一刻本组自动收紧回"逐条全等"（与第 4 组 FOCALS 的 `isSwiftExtension` 同款机制）。
enum ParameterStripCatalog {

    // MARK: 先行标记（CB 同步完原型后请改回 false）

    /// **Swift 领先原型** 的显式标记 —— 见类型头部的说明。
    ///
    /// - `true`：本文件的档位表 / 步进**领先**原型，`check_presets` 第 6 组降级为 WARN
    ///   （不阻塞，但会逐条打印差异清单给 CB）。
    /// - `false`：两边应当逐条全等，本组收紧为 FAIL。
    ///
    /// ⚠️ 必须是 `var`/`let` 静态常量且**只有这一处**（改口径时改这里，别在别的文件再写一个开关）。
    static let isSwiftAheadOfPrototype: Bool = true

    /// 现行口径的名字（日志 / WARN 里带出来，避免"哪一版口径"说不清）。
    static let specVersion: String = "hurricane-A（2026-09-21 批六 · 复刻飓风）"

    // MARK: ISO（25 档）

    /// ISO 档位值 —— **约 1/3 档等比**，50…**12096**。
    ///
    /// ⚠️ 末档**不是**行业表的 12800（用户 2026-09-21 拍板）：设备实读 `maxISO` = **12096**
    /// （本机日志实锤同值）。标称表按设备实读值收尾，运行时再由
    /// `isoValues(deviceISOMax:)` 按当前设备覆盖一次，保证换了机型末档也精确。
    static let isoValues: [Double] = [
        50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640,
        800, 1000, 1200, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12096
    ]
    /// 手动档初值兜底（原型 `state.cal.iso` 的种子值）。
    /// ⚠️ 真机切手动时**不用它** —— 用设备当前值（用户 2026-09-19 拍板 ③），
    /// 它只在"设备拿不到当前 ISO"时兜底。
    static let defaultISO: Double = 800

    /// 末档按**设备实读** `maxISO` 覆盖后的 ISO 档位表。
    ///
    /// - 设备给的 `maxISO` 与标称末档一致（本机 12096）→ 原样返回；
    /// - 不一致 → **只替换末档**（档数不变，自检 / 比对口径才不会漂）；
    /// - 拿不到（`nil` 或非有限 / ≤ 0）→ 用标称表。
    static func isoValues(deviceISOMax: Double?) -> [Double] {
        guard let maxISO = deviceISOMax, maxISO.isFinite, maxISO > 0,
              maxISO != isoValues.last else { return isoValues }
        var values = isoValues
        values[values.count - 1] = maxISO
        return values
    }

    // MARK: 快门（42 档：1/3 档行业表 + 两个影院值）

    /// 快门档位的**曝光秒数**（**递减**：1s → 1/8000）。
    ///
    /// 口径（用户 2026-09-21 拍板"档位表走行业主流"）：
    /// ① 从 15 档整档**补成 1/3 档**（1 → 1/8000，含 1/1.3 / 1/1.6 / 1/2.5 / 1/3 / 1/5 / 1/6 /
    ///    1/10 / 1/13 / 1/20 / 1/25 / 1/40 / 1/50 / 1/80 / 1/1250 / 1/2500 / 1/5000 这些
    ///    整档表里没有的中间值）；
    /// ② **加影院值** `1/96` 与 `1/120`（180° 快门角，行业摄影机表里都有）；
    /// ③ **删掉 `1/12000`** —— 行业表没有它，且在 40pt 档距 + 全标签下它是 7 字符
    ///    （≈43pt）**必然与相邻标签叠字**（用户给的三选项里选了"去掉"）。
    static let shutterSecondValues: [Double] = [
        1,
        1.0 / 1.3, 1.0 / 1.6, 1.0 / 2, 1.0 / 2.5, 1.0 / 3, 1.0 / 4, 1.0 / 5,
        1.0 / 6, 1.0 / 8, 1.0 / 10, 1.0 / 13, 1.0 / 15, 1.0 / 20, 1.0 / 25, 1.0 / 30,
        1.0 / 40, 1.0 / 50, 1.0 / 60, 1.0 / 80, 1.0 / 96, 1.0 / 100, 1.0 / 120, 1.0 / 125,
        1.0 / 160, 1.0 / 200, 1.0 / 250, 1.0 / 320, 1.0 / 400, 1.0 / 500, 1.0 / 640, 1.0 / 800,
        1.0 / 1000, 1.0 / 1250, 1.0 / 1600, 1.0 / 2000, 1.0 / 2500, 1.0 / 3200,
        1.0 / 4000, 1.0 / 5000, 1.0 / 6400, 1.0 / 8000
    ]
    /// 快门显示文本（与上一行**逐项对应**；最慢档是 `"1"` 不是 `"1s"`）
    static let shutterLabels: [String] = [
        "1",
        "1/1.3", "1/1.6", "1/2", "1/2.5", "1/3", "1/4", "1/5",
        "1/6", "1/8", "1/10", "1/13", "1/15", "1/20", "1/25", "1/30",
        "1/40", "1/50", "1/60", "1/80", "1/96", "1/100", "1/120", "1/125",
        "1/160", "1/200", "1/250", "1/320", "1/400", "1/500", "1/640", "1/800",
        "1/1000", "1/1250", "1/1600", "1/2000", "1/2500", "1/3200",
        "1/4000", "1/5000", "1/6400", "1/8000"
    ]
    /// 手动档初值兜底（同 ISO 的口径）
    static let defaultShutterSeconds: Double = 1.0 / 125

    // MARK: 白平衡（76 档，线性）

    /// 色温档位（原型 `WB_STRIP = 2500…10000 步长 100` ⇒ **76 档**）
    static let whiteBalanceValues: [Double] = (0...75).map { 2500 + Double($0) * 100 }
    /// 预设档（原型 `preset:[3000,4000,5200,6000,7500]` → 琥珀色刻度）。
    ///
    /// 批六保留"预设位"语义（用户拍板），但**高度与普通档相同** —— 飓风没有层级。
    static let whiteBalancePresetValues: Set<Double> = [3000, 4000, 5200, 6000, 7500]
    /// 手动档初值兜底（原型 `state.cal.wb = '5600K'`）
    static let defaultWhiteBalanceKelvin: Double = 5600

    // MARK: 可视步进（统一 40pt）

    /// 相邻档位的可视步进（pt）—— **批六起三条统一 40pt**（飓风实测 120px ÷ 3）。
    ///
    /// ⚠️ 旧口径是"三条各不相同"（ISO 46 / 快门 56 / WB 26，按档数差 5 倍分别配密度）；
    /// 飓风是**一个档距走三条**，靠"滚动 + 8~9 档可视"消化档数差 — 用户已接受这个代价。
    ///
    /// 实现上仍按条分派（**三个分支都返回 40**）：`check_presets` 第 6 组要按条比对步进，
    /// 写成单个常量它就读不出来了（会误报"取不到数据"）。
    static func slot(for kind: ParameterStripKind) -> CGFloat {
        switch kind {
        case .iso: return 40
        case .shutter: return 40
        case .whiteBalance: return 40
        }
    }

    // MARK: 求交容差

    /// "档位 vs 设备可用区间"的求交容差（**三条各给**）。
    ///
    /// 为什么不是一个通用常数：三条的**量纲跨度极大** —— ISO 50…12096（最小档间距 14）、
    /// 快门 1.25e-4…1.0 秒（最小档间距 2.1e-5，来自 1/96 与 1/100）、白平衡步长 100。
    /// 通用容差要么对快门过宽（把相邻档误判成可用）、要么对 ISO 形同虚设。
    static func tolerance(for kind: ParameterStripKind) -> Double {
        switch kind {
        case .iso: return 0.5
        case .shutter: return 1e-6      // ≈ 1 微秒，仍比最小档间距（2.1e-5）小一个数量级
        case .whiteBalance: return 0.5
        }
    }

    // MARK: 档位表

    /// 某条刻度条的**标称档位表**（未与设备能力求交）。
    ///
    /// - Parameter deviceISOMax: 设备实读 `maxISO`（只对 ISO 有意义；`nil` = 用标称末档）
    static func steps(for kind: ParameterStripKind, deviceISOMax: Double? = nil) -> [ParameterStripStep] {
        switch kind {
        case .iso:
            return isoValues(deviceISOMax: deviceISOMax).map { value in
                ParameterStripStep(
                    value: value,
                    label: isoLabel(value),
                    showsLabel: true,           // 批六：全标签（飓风口径）
                    isPreset: false
                )
            }
        case .shutter:
            return zip(shutterSecondValues, shutterLabels).map { seconds, label in
                ParameterStripStep(
                    value: seconds,
                    label: label,
                    showsLabel: true,
                    isPreset: false
                )
            }
        case .whiteBalance:
            return whiteBalanceValues.map { value in
                ParameterStripStep(
                    value: value,
                    label: whiteBalanceLabel(value),
                    showsLabel: true,
                    isPreset: whiteBalancePresetValues.contains(value)
                )
            }
        }
    }

    /// 档位总数（自检用：25 / **42** / 76）
    static func stepCount(for kind: ParameterStripKind) -> Int {
        switch kind {
        case .iso: return isoValues.count
        case .shutter: return shutterSecondValues.count
        case .whiteBalance: return whiteBalanceValues.count
        }
    }

    // MARK: 标签宽度预算（批六新增；自检第 19 组照这个式子复算）

    /// 刻度标签的**估算字符宽**（em 倍数）—— 用于"40pt 档距下标签会不会叠字"的预算。
    ///
    /// ⚠️ 这是**估算**，不是实测：数字按 0.62em、字母按 0.68em、`/` 按 0.42em、`.` 按 0.30em。
    /// 项目纪律里"拉丁/数字必须实测"依旧成立 —— 所以复验口径里留了一条
    /// **Mac 实测最宽标签**（见 `docs/23`），本估算只用来在静态自检里挡住"明显要叠"的情况。
    static func estimatedLabelWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        text.reduce(0) { total, ch in
            let em: CGFloat
            switch ch {
            case "0"..."9": em = 0.62
            case "/": em = 0.42
            case ".": em = 0.30
            default: em = 0.68          // K 等字母
            }
            return total + fontSize * em
        }
    }

    /// 一条刻度条里**最宽标签的估算宽**（pt）
    static func widestLabelWidth(_ kind: ParameterStripKind, fontSize: CGFloat) -> CGFloat {
        steps(for: kind).map { estimatedLabelWidth($0.label, fontSize: fontSize) }.max() ?? 0
    }

    // MARK: 数值格式（与原型 `fmt` 对齐）

    /// ISO → **纯数字**（原型 `String(Math.round(v))`，**不带 "ISO" 前缀**）：`800`
    static func isoLabel(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// 快门（秒）→ 分数字符串（原型直接用 `SHUTTER_LABEL`）：`1/125`、最慢档 `1`
    ///
    /// 表里没有的秒数走通用的 `FormatText.shutterSpeed`（不会出现在正常路径上，只作兜底）。
    static func shutterLabel(_ seconds: Double) -> String {
        if let index = shutterSecondValues.firstIndex(of: seconds) {
            return shutterLabels[index]
        }
        return FormatText.shutterSpeed(seconds)
    }

    /// 色温 → `<数值>K`（原型 `Math.round(v) + 'K'`）：`5600K`
    static func whiteBalanceLabel(_ kelvin: Double) -> String {
        "\(Int(kelvin.rounded()))K"
    }

    /// 档位值的显示文本（按条分派）
    static func label(for kind: ParameterStripKind, value: Double) -> String {
        switch kind {
        case .iso: return isoLabel(value)
        case .shutter: return shutterLabel(value)
        case .whiteBalance: return whiteBalanceLabel(value)
        }
    }

    /// 三条共用的**默认档位值**（自动态气泡为「自动」时才用到）
    static func defaultValue(for kind: ParameterStripKind) -> Double {
        switch kind {
        case .iso: return defaultISO
        case .shutter: return defaultShutterSeconds
        case .whiteBalance: return defaultWhiteBalanceKelvin
        }
    }

    /// 把任意值**吸附**到最近档位（回写时用：设备给回来的值不可能正好落在档位上）
    static func nearestStep(for kind: ParameterStripKind, to value: Double) -> Double? {
        let candidates: [Double]
        switch kind {
        case .iso: candidates = isoValues
        case .shutter: candidates = shutterSecondValues
        case .whiteBalance: candidates = whiteBalanceValues
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min { abs($0 - value) < abs($1 - value) }
    }
}
