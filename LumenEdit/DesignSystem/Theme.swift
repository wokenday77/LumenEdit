import SwiftUI

/// 设计令牌。
///
/// 相机页与修图页都是深色，颜色集中在这里定义，避免各页面各写一套
/// `Color.black.opacity(x)`，改一次要翻遍全工程。
enum Theme {

    // MARK: - 颜色

    enum Palette {
        /// 取景器底色
        static let canvas = Color.black
        /// 浮层面板
        static let panel = Color(white: 0.09)
        /// 面板上的次级按钮/胶囊
        static let panelElevated = Color(white: 0.16)
        /// 分隔线与描边
        static let stroke = Color.white.opacity(0.14)
        static let primaryText = Color.white
        static let secondaryText = Color.white.opacity(0.62)
        static let tertiaryText = Color.white.opacity(0.38)
        /// 主强调色（与 AccentColor 保持一致的金黄）
        static let accent = Color(red: 0.949, green: 0.686, blue: 0.235)
        static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
        /// 对焦方框
        static let focusIndicator = Color(red: 1.0, green: 0.83, blue: 0.25)
        /// 录制指示
        static let recording = Color(red: 1.0, green: 0.23, blue: 0.19)
        /// 成功 / 电平表点亮（原型 `--ok: #34d058`）
        static let ok = Color(red: 0.204, green: 0.816, blue: 0.345)
        /// accent 的低饱和底：用在「已开启」的胶囊上（原型 `--accent-dim: rgba(242,175,60,.20)`）
        static let accentDim = accent.opacity(0.20)
        /// 模式条未选中档位（原型 `.mode-tab{ color: rgba(255,255,255,.5) }`）
        static let modeInactive = Color.white.opacity(0.5)
    }

    // MARK: - 间距

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 34
    }

    // MARK: - 圆角

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: - 尺寸

    enum Size {
        static let shutterDiameter: CGFloat = 74
        static let shutterRingWidth: CGFloat = 5
        static let thumbnailSide: CGFloat = 52

        /// 模式条单档高度（原型 `.mode-tab{ height:26px }`，此前用的是 34）
        static let modeSelectorHeight: CGFloat = 26
        /// 模式条单档的间距（原型 `.mode-tabs{ gap:10px }`）
        static let modeSelectorSpacing: CGFloat = 10
        /// 模式条「实况」档的同心圆图标尺寸（原型里 `ICON_LIVE` 的 svg 宽 18）
        static let modeSelectorGlyphSize: CGFloat = 18

        // MARK: 顶栏（两行）
        //
        // 2026-09-17 起顶栏是**两行**（原型 `.topbar{ height:56px }`）：
        //   主行 30 = L/R 电平表 + 模式条 + 右上三图标
        //   副行 26 = 「影调预览」胶囊 + 右「剩余存储」胶囊

        static let topBarRow1Height: CGFloat = 30
        static let topBarRow2Height: CGFloat = 26
        static let topBarHeight: CGFloat = 56
        /// 顶栏两行内、以及行内各块之间的间距（原型 `.tb-row1{ gap:8px }`）
        static let topBarRowSpacing: CGFloat = 8

        /// 顶栏单侧宽度 = 右上三图标的自然宽 = 3 × 24.33 ≈ 73（原型 `--tb-side-w: 73px`）。
        ///
        /// **左右必须等宽**，模式条的盒中心才等于屏幕中心 —— 这是网页原型
        /// `--tb-side-w` 的做法（原型注释：「把两侧块钉成同宽，盒中心回到屏中心」）。
        ///
        /// 真机实测与推算（iPhone 16 Pro / iOS 26.6，屏宽 402pt、顶栏可用宽 370pt）：
        ///   - 左侧电平表块与右侧图标块各 73pt → 中段 370 − 146 = **224pt**
        ///   - 模式条改版后约 **150pt**（原型同形态是 139.6：无胶囊底、档位无内边距、
        ///     字号 11.5、档间距 10、「实况」档用 18pt 图标；我们多出的约 10pt
        ///     是每档两端各 5pt 的**透明命中区扩展**，文字之间的视觉间距仍是 10）
        ///     → 中段 224 装得下 150，两侧各余 **约 37pt**
        ///
        /// ⚠️ **73 / 224 / 140 这组数字是「4 档、三图标、iPhone 16 Pro」这个形态下的结论。**
        /// 三件事会让它失效，改完必须重新测量并更新本注释：
        ///   1. 档位数变化（加第 5 档），或档位字号/图标尺寸变化；
        ///   2. 右上图标数量变化（模块 #10 的 ⠿ 面板、模块 #11 的格式芯片都会动这一格
        ///      —— 格式芯片顶替三图标时同样要钉成 73pt 宽，否则模式条会跟着漂）；
        ///   3. 换机型（iPhone SE 375pt 宽 → 可用 343 → 中段 197，仍容得下 140，可以，但要重测）。
        ///
        /// ⚠️ 顺带记一条**几何上的硬约束**：Apple HIG 建议 44×44pt 触控目标，
        /// 而这里每个图标只有约 24pt 宽。想做到 44pt 就要把单侧加到 132pt（3×44），
        /// 中段只剩 370 − 264 = 106pt < 模式条 140pt → **必然溢出**。
        /// 也就是说「模式条居中」与「三图标各 44pt」在 402pt 屏宽上不可兼得，
        /// 现在选的是保版式、把命中区从原型的 17×17 提到 24.33×30（且互不重叠）。
        static let topBarSideWidth: CGFloat = 73

        /// 顶栏图标按钮的单元宽度 = 73 / 3 ≈ 24.33。
        /// 三个单元**间距为 0** 地拼起来正好等于侧宽 —— 这样命中区各自独立、互不重叠
        /// （用负间距或 `contentShape` 外扩都会让相邻按钮的命中区交叠，点谁都可能错）。
        static let topBarIconCellWidth: CGFloat = topBarSideWidth / 3
        /// 顶栏图标字形尺寸（原型 `.tb-icon svg{ width:15px }`）
        static let topBarIconGlyphSize: CGFloat = 15

        /// 副行胶囊（原型 `.chip{ height:24px; padding:0 10px; font-size:11px; gap:6px }`）
        static let chipHeight: CGFloat = 24
        static let chipGlyphSize: CGFloat = 11
        static let chipHorizontalPadding: CGFloat = 10
        static let chipIconSpacing: CGFloat = 6

        /// 副行 L/R 电平表：每声道 8 个点（原型 `.levels .dots i{ 3.5px; gap:2px }`）
        static let levelDotSide: CGFloat = 3.5
        static let levelDotSpacing: CGFloat = 2

        /// Live Photo 角标（黄底同心圆）本体的边长与其中图标的边长。
        ///
        /// 对齐网页原型 `.live-badge`：22×22 黄底圆 + 14×14 图标（图标由
        /// `LivePhotoCircleIcon` 自绘，设计坐标系 24 单位，按 size/24 等比缩放）。
        static let liveBadgeSide: CGFloat = 22
        static let liveBadgeIconSize: CGFloat = 14
    }

    // MARK: - 字体

    enum Typography {
        static let value = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let label = Font.system(size: 11, weight: .medium, design: .rounded)
        static let toast = Font.system(size: 13, weight: .medium, design: .rounded)
        static let mono = Font.system(size: 11, design: .monospaced)

        /// 模式条档位文字：原型 `.mode-tab{ font-size:11.5px }`，
        /// 选中态 `.on{ font-weight:700 }`，未选中 600。
        /// 做成函数是因为"选中加粗"这个变化没法用同一个 Font 表达。
        static let modeTitleSize: CGFloat = 11.5
        static func modeTitle(selected: Bool) -> Font {
            .system(size: modeTitleSize, weight: selected ? .bold : .semibold, design: .rounded)
        }

        /// 顶栏副行胶囊文字（原型 `.chip{ font-size:11px; font-weight:600 }`）
        static let chip = Font.system(size: 11, weight: .semibold, design: .rounded)
        /// 电平表的声道字母 L / R（原型 `.levels .ch{ font-size:8px; font-weight:700 }`）
        static let levelChannel = Font.system(size: 8, weight: .bold, design: .rounded)
    }
}
