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
    /// 是否在刻度下显示数字（原型 `labelAt`：只有主档位显示，避免 76 档白平衡密密麻麻）
    let showsLabel: Bool
    /// 白平衡的「预设档」（原型 `preset`：白炽灯/荧光灯/日光/阴天/阴影 → 琥珀色刻度）
    let isPreset: Bool

    var id: Double { value }
}

// MARK: - 目录（单一真源）

/// 参数刻度条数据 —— 三条条的**档位表 / 数值格式 / 可视步进 / 标签档 / 预设档**。
///
/// ## 数据来源
///
/// 与原型 `prototype/index.html` 同源，由 `tools/check_presets.js` 第 6 组逐条比对：
///
/// | 条 | 原型 | 档数 |
/// |---|---|---|
/// | ISO | `ISO_STRIP`（L3076） | **25 档**（50…12000，约 1/3 档等比） |
/// | 快门 | `SHUTTER_VAL` + `SHUTTER_LABEL`（L1753-1754） | **15 档**（1s … 1/12000，整档） |
/// | 白平衡 | `WB_STRIP`（L3077） | **76 档**（2500…10000K，线性步长 100） |
///
/// ## 与"能力求交"的分工
///
/// 本类型只给**标称档位**；"哪些档位在这台设备上真的可用"由
/// `CaptureCapabilities.availableRange(for:on:)` 求交，UI 把越界的档位**置灰但保留可点**
/// （点了给 toast 说明）—— 与焦段条那套一致，守"不做点了没反应"。
enum ParameterStripCatalog {

    // MARK: ISO（25 档）

    /// ISO 档位值（原型 `ISO_STRIP`，**约 1/3 档等比**，50…12000）
    static let isoValues: [Double] = [
        50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640,
        800, 1000, 1200, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12000
    ]
    /// ISO 显示数字的档位（原型 `labelAt`）
    static let isoLabelledValues: Set<Double> = [400, 800, 1200, 1600, 3200, 6400, 12000]
    /// 手动档初值兜底（原型 `state.cal.iso` 的种子值）。
    /// ⚠️ 真机切手动时**不用它** —— 用设备当前值（用户 2026-09-19 拍板 ③），
    /// 它只在"设备拿不到当前 ISO"时兜底。
    static let defaultISO: Double = 800

    // MARK: 快门（15 档，整档）

    /// 快门档位的**曝光秒数**（原型 `SHUTTER_VAL`，1s → 1/12000，**递减**）
    static let shutterSecondValues: [Double] = [
        1, 1.0 / 2, 1.0 / 4, 1.0 / 8, 1.0 / 15, 1.0 / 30, 1.0 / 60, 1.0 / 125,
        1.0 / 250, 1.0 / 500, 1.0 / 1000, 1.0 / 2000, 1.0 / 4000, 1.0 / 8000, 1.0 / 12000
    ]
    /// 快门显示文本（原型 `SHUTTER_LABEL`，与上一行**逐项对应**；最慢档是 `"1"` 不是 `"1s"`）
    static let shutterLabels: [String] = [
        "1", "1/2", "1/4", "1/8", "1/15", "1/30", "1/60", "1/125",
        "1/250", "1/500", "1/1000", "1/2000", "1/4000", "1/8000", "1/12000"
    ]
    /// 手动档初值兜底（同 ISO 的口径）
    static let defaultShutterSeconds: Double = 1.0 / 125

    // MARK: 白平衡（76 档，线性）

    /// 色温档位（原型 `WB_STRIP = 2500…10000 步长 100` ⇒ **76 档**）
    static let whiteBalanceValues: [Double] = (0...75).map { 2500 + Double($0) * 100 }
    /// 显示数字的档位：每 500K 一档（原型 `labelAt` 循环 `k=3000; k<=10000; k+=500`，15 个）
    static let whiteBalanceLabelledValues: Set<Double> = Set(stride(from: 3000, through: 10000, by: 500).map(Double.init))
    /// 预设档（原型 `preset:[3000,4000,5200,6000,7500]` → 琥珀色刻度）
    static let whiteBalancePresetValues: Set<Double> = [3000, 4000, 5200, 6000, 7500]
    /// 手动档初值兜底（原型 `state.cal.wb = '5600K'`）
    static let defaultWhiteBalanceKelvin: Double = 5600

    // MARK: 可视步进（原型 `slot`，px）

    /// 相邻档位的可视步进（pt）。三条各不相同 —— 档数差 5 倍，步进不区分会一条长得离谱、一条挤成一团。
    static func slot(for kind: ParameterStripKind) -> CGFloat {
        switch kind {
        case .iso: return 46
        case .shutter: return 56
        case .whiteBalance: return 26
        }
    }

    // MARK: 求交容差

    /// "档位 vs 设备可用区间"的求交容差（**三条各给**）。
    ///
    /// 为什么不是一个通用常数：三条的**量纲跨度极大** —— ISO 50…12000（最小档间距 14）、
    /// 快门 8.3e-5…1.0 秒（最小档间距 4.2e-5）、白平衡步长 100。
    /// 通用容差要么对快门过宽（把相邻档误判成可用）、要么对 ISO 形同虚设。
    static func tolerance(for kind: ParameterStripKind) -> Double {
        switch kind {
        case .iso: return 0.5
        case .shutter: return 1e-6      // ≈ 1 微秒，比最小档间距（4.2e-5）小一个数量级
        case .whiteBalance: return 0.5
        }
    }

    // MARK: 档位表

    /// 某条刻度条的**标称档位表**（未与设备能力求交）
    static func steps(for kind: ParameterStripKind) -> [ParameterStripStep] {
        switch kind {
        case .iso:
            return isoValues.map { value in
                ParameterStripStep(
                    value: value,
                    label: isoLabel(value),
                    showsLabel: isoLabelledValues.contains(value),
                    isPreset: false
                )
            }
        case .shutter:
            return zip(shutterSecondValues, shutterLabels).map { seconds, label in
                ParameterStripStep(
                    value: seconds,
                    // 快门 15 档**全部**显示数字（原型 `labelAt: SHUTTER_LABEL.slice()`）
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
                    showsLabel: whiteBalanceLabelledValues.contains(value),
                    isPreset: whiteBalancePresetValues.contains(value)
                )
            }
        }
    }

    /// 档位总数（自检用：25 / 15 / 76）
    static func stepCount(for kind: ParameterStripKind) -> Int {
        switch kind {
        case .iso: return isoValues.count
        case .shutter: return shutterSecondValues.count
        case .whiteBalance: return whiteBalanceValues.count
        }
    }

    // MARK: 数值格式（与原型 `fmt` 逐字对齐）

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
