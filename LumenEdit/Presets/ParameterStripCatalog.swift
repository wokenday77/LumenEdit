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

// MARK: - 刻度层级（视觉）

/// 刻度线的**视觉层级** —— 原型 CSS `.sp-tick` 的四档，**逐字对齐原型**：
///
/// | 档 | 原型选择器 | 高 | 颜色 |
/// |---|---|---|---|
/// | `minor` | `.sp-tick` | 10 | `rgba(255,255,255,.34)` |
/// | `mid` | `.sp-tick.mid` | **15** | `rgba(255,255,255,.48)` |
/// | `major` | `.sp-tick.major` | 22 | `rgba(255,255,255,.82)` |
/// | `preset` | `.sp-tick.preset` | 22 | `rgba(242,175,60,.85)` |
///
/// ## 为什么要有这个枚举（2026-09-20 批四，用户批三实测"细密度没生效"）
///
/// 原型的四档 CSS 一直都在，但 `renderStrip` 的 JS 只给 `major` / `preset` 打了类 ——
/// `mid` 那一层**定义了却没人用**。Swift 侧照着 JS 抄，于是"主档之间的细刻度"只能
/// 自己发明：1px 宽 / 20% 白 / 半高发丝线（`ParameterStripView` 旧实现）。
/// 结果就是用户看到的"细线太淡 + 档距偏疏 + 白平衡无层级区分"。
///
/// **现在把原型那一层用起来**：细刻度 = `mid`（15pt / 48% / 1.5pt 宽），
/// 层级由**高度 + 对比度**同时表达，不再靠"更细更淡"。
enum ParameterStripTickTier: String, CaseIterable {
    case hair
    case minor
    case mid
    case major
    case preset
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

    // MARK: 刻度层级（渲染用；不参与与设备的"能力求交"）

    /// 某个档位的刻度层级（**只依赖档位数据本身**，不依赖设备当前值）。
    ///
    /// 规则（三条各一条理由，都写在注释里，避免以后被"顺手统一"掉）：
    ///
    /// - **带数字的档 = `major`**（原型 `labelAt` 判据）—— 与原型逐条一致。
    /// - **预设档 = `preset`**（白平衡 5 个琥珀档）—— ⚠️ 优先级**高于** `major`：
    ///   原型 `.sp-tick.preset` 与 `.major` 同为 22pt，颜色覆盖。5200K 只出现在预设里
    ///   （不是 500K 的整数倍 → 原型 `labelAt` 不含它）—— 旧实现让它只改色不改高（10pt），
    ///   那是**偏离原型**，本轮修正为 22pt。
    /// - **ISO 的整档（1 EV 步，即每 3 个 1/3 档）= `mid`**：`ISO_STRIP` 是约 1/3 档等比
    ///   （50,64,80,100,125,160,200,…），`index % 3 == 0` 恰好是 50/100/200/400/800/1600/
    ///   3200/6400/12000 —— 与"整档 ISO"逐项吻合。剩下的是 1/3 档 → `minor`。
    ///   ⚠️ **ISO 不再加"合成细线"**：它那 25 条就是真实的 1/3 档档位（可吸附），
    ///   再塞视觉细分线会与真实档位混淆 —— 层级靠 `mid/major` 表达就够了。
    /// - **白平衡非整百五档 = `mid`**：76 档每 100K 一条，每 5 条（500K）带数字 =
    ///   `major`，中间 4 条 = `mid` —— 这样才有"层级"（旧实现：除了 major 全是
    ///   同一个 10pt 灰线，用户实测"无层级区分"）。
    /// - **快门 15 档全部带数字**（原型 `labelAt: SHUTTER_LABEL.slice()`）→ 全部 `major`；
    ///   它的"细刻度"是**档间半档**（`ParameterStripView` 里的合成 `mid` 线，
    ///   见 `halfStepOffsets(for:)`）。
    static func tickTier(
        for kind: ParameterStripKind,
        index: Int,
        step: ParameterStripStep
    ) -> ParameterStripTickTier {
        if step.isPreset { return .preset }
        if step.showsLabel { return .major }
        switch kind {
        case .iso:
            return index % 3 == 0 ? .mid : .minor
        case .shutter:
            // 快门 15 档全是 labelAt → 走不到这里；真走到了也按 minor 兜底
            return .minor
        case .whiteBalance:
            return .mid
        }
    }

    /// 需要**合成档间细分刻度**的条（批五 问题 2：三条都要）。
    ///
    /// ## 为什么三条都要（含此前只有快门的"半档线"）
    ///
    /// 批四是"只有快门加半档 `mid` 线"，其余两条不加 —— 用户批四复验后要求
    /// **对照参考图再加一层细分**："标点更细、更多"。
    /// 参考图实测（源帧 588px / 393pt = 1.5px per pt）：白平衡条主档（500K）间距 ≈18pt、
    /// 其间约 **9~10 条细刻度**，细:主高度比 ≈1:2。
    ///
    /// 我们的 `slot` 是**原型真源**（WB 26 / ISO 46 / 快门 56，`check_presets.js` 逐条比对），
    /// **绝对密度对不齐**（照参考图要么把 slot 压到 4pt、要么把标签全挤掉，都是倒退）。
    /// 所以对齐**相对口径**：**每两个相邻真实档位之间补 1 条细分线**（`hair`）——
    ///   · WB：主档间 4 真实 + 4 细分 = **8 条**（参考图 9~10，同量级 ✓）
    ///   · ISO：主档间同理；快门：原来的半档 `mid` 线**降级为 `hair`**（它本来就该更细）
    ///
    /// ⚠️ **这些线不参与吸附**（刻度条永远是离散档位吸附）—— 纯视觉细分，
    /// 与真实档位线在高度（6.5 vs 10/15/22）与亮度（26% vs 34/48/82%）上双重区分，
    /// 不会让人误判"拖到这里会停"。
    static func hasSubTicks(_ kind: ParameterStripKind) -> Bool {
        switch kind {
        case .iso, .shutter, .whiteBalance: return true
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
