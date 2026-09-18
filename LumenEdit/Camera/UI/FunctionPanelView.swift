import SwiftUI

// MARK: - 拍摄现场设置的两个枚举（面板里要循环切换）

/// 画幅比（竖拍口径：面板上写 `4:3` 表示画面宽:高 = 3:4）。
///
/// 循环顺序照原型 `FN_RATIOS = ['4:3','16:9','1:1']`，**默认 4:3**（原型初值）。
enum FrameRatio: String, CaseIterable, Identifiable {
    case r4x3 = "4:3"
    case r16x9 = "16:9"
    case r1x1 = "1:1"

    var id: String { rawValue }
    /// 面板圆形图标里显示的文字
    var displayName: String { rawValue }

    /// 画面**高 ÷ 宽**（遮幅用：取景器宽不变，算出画面高后上下各压一半黑边）
    /// - `4:3` → 4/3（竖拍 3:4）
    /// - `16:9` → 16/9（竖拍 9:16，比 4:3 更"长"）
    /// - `1:1` → 1
    var heightOverWidth: CGFloat {
        switch self {
        case .r4x3: return 4.0 / 3.0
        case .r16x9: return 16.0 / 9.0
        case .r1x1: return 1
        }
    }

    /// 下一个比例（循环）
    var next: FrameRatio {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

/// 倒计时（原型 `关 → 3s → 10s` 循环）
enum ShootTimer: String, CaseIterable, Identifiable {
    case off = "关"
    case three = "3s"
    case ten = "10s"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var isOn: Bool { self != .off }

    var next: ShootTimer {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

// MARK: - 面板条目

/// 功能面板里的一格。
///
/// 做成数据驱动而不是把 7 格写死在 View 里：格数、顺序、开关态全在调用点（`CameraView`）一处，
/// 自检第 9 组就能按顺序断言这 7 个标签（防止"悄悄少一格/顺序变了"）。
struct FunctionPanelItem: Identifiable {

    /// 圆形图标里画什么
    enum Glyph {
        /// SF Symbol 名
        case symbol(String)
        /// 文字字形（原型 `.fn-ic-text`）—— 没有合适符号的格子用（`4:3` / `关`）
        case text(String)
    }

    let id: String
    let glyph: Glyph
    let label: String
    /// 开启态：圆底与字形转绿（原型 `.fn-btn.on`）
    let isOn: Bool
    let action: () -> Void
}

// MARK: - 功能面板

/// 功能面板（⠿ 弹出 · **模态浮层**）。
///
/// ## 位置：盖住底栏的浮层，不是底栈里的一行
///
/// 原型 `.fn-panel{ position:absolute; left:8px; right:8px; bottom:8px; z-index:20 }` ——
/// 它是**整条底栏之上**的一张卡（底栏控件被它盖住、点不到），**不参与底栈布局**。
/// 这一点与 #6 / #7 的"底栈行"形态完全不同，是本件最容易搞错的地方：
/// 面板态反而比底栏行更省取景器（约 59% 净可见，因为它是"盖"不是"挤"）。
///
/// ## 版式（4 列网格，第 2 行 3 格）
///
/// ```
/// ┌──────────────────────────────────────────┐
/// │  (实况)   (4:3)   (闪光灯)  (关)          │
/// │   实况    画幅比   闪光灯   倒计时         │
/// │  (HDR)   (设置)    (HUD)                 │  ← 第 2 行 3 格（左对齐）
/// │  高亮增益   设置     HUD                  │
/// │  ──────────────────────────────────────  │
/// │  简易模式                              ›  │
/// └──────────────────────────────────────────┘
/// ```
/// 原型是 8 格（第 8 格「阶段标记」是给原型演示看的研发工具）。**用户 2026-09-18 拍板去掉它，
/// 做成 7 格** —— 真机上对拍摄无价值，而实现它要给每个控件加标记层（成本高、收益低）。
/// 见 `docs/12` 第五节。
///
/// ## 入场动画（照原型）
///
/// 面板整体从底部升起（`translateY(112%) → 0`，300ms `cubic-bezier(.22,.9,.3,1)`，
/// 由调用点的 `transition` + `animation` 驱动）；**7 个圆钮依次浮入**（opacity 0→1 +
/// 上移 10pt，每个错 40ms），收起时一起退（不拖沓）——"一起退"由面板整体移除天然实现。
///
/// ## 本件的诚实边界
///
/// 面板里 5 个开关只有 **画幅比（真遮幅）** 与 **HUD（真开关）** 是本件真生效的，
/// **实况**只到"状态 + 角标"，**闪光灯 / 倒计时 / 高亮增益**只记状态 —— 都要 toast 说明。
/// **简易模式**（foot 链接）Swift 侧还没有（模块 #12）→ 置灰 + toast 说原因，
/// 不做"点了没反应"。
struct FunctionPanelView: View {

    let items: [FunctionPanelItem]
    /// 简易模式是否开启（原型 `.fn-link.on` 转绿）。Swift 侧暂无简易模式 → 恒 false
    let isSimpleModeOn: Bool
    let onSimpleModeTap: () -> Void

    /// 控制 7 个圆钮的"依次浮入"：出现后置 true，错位动画才会跑
    @State private var isContentIn = false

    /// 每个圆钮的入场错位间隔（原型 `transition-delay` 每个 +40ms）
    private static let staggerStep: Double = 0.04
    private static let contentAnimDuration: Double = 0.24

    var body: some View {
        VStack(spacing: 0) {
            grid
            foot
        }
        .padding(.top, Theme.Size.functionPanelTopPadding)
        .padding(.horizontal, Theme.Size.functionPanelHorizontalPadding)
        .padding(.bottom, Theme.Size.functionPanelBottomPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Size.functionPanelCornerRadius, style: .continuous)
                .fill(Theme.Palette.functionPanelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Size.functionPanelCornerRadius, style: .continuous)
                .stroke(Theme.Palette.functionPanelStroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.6), radius: 22, x: 0, y: 18)
        .onAppear { isContentIn = true }
        .onDisappear { isContentIn = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("功能面板")
    }

    // MARK: - 网格

    private var grid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .flexible(),
                    spacing: Theme.Size.functionGridColumnSpacing
                ),
                count: Theme.Size.functionGridColumns
            ),
            spacing: Theme.Size.functionGridRowSpacing
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                cell(item)
                    // 依次浮入：每个比前一个晚 40ms（原型 `.fn-btn:nth-child(n)` 的 transition-delay）
                    .opacity(isContentIn ? 1 : 0)
                    .offset(y: isContentIn ? 0 : 10)
                    .animation(
                        .easeOut(duration: Self.contentAnimDuration)
                            .delay(Double(index) * Self.staggerStep),
                        value: isContentIn
                    )
            }
        }
    }

    /// 一格 = 圆形图标底（54）+ 间距 7 + 标签（行高钉死 13），整格宽 64
    private func cell(_ item: FunctionPanelItem) -> some View {
        Button(action: item.action) {
            VStack(spacing: Theme.Size.functionCellInnerSpacing) {
                glyphCircle(item)
                Text(item.label)
                    .font(Theme.Typography.functionLabel)
                    .foregroundStyle(
                        item.isOn ? Theme.Palette.ok : Theme.Palette.secondaryText
                    )
                    .lineLimit(1)
                    // 行高钉死（见 Theme.Size.functionLabelHeight）：面板高度账不交给字体度量
                    .frame(height: Theme.Size.functionLabelHeight)
            }
            .frame(width: Theme.Size.functionCellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(FunctionCellButtonStyle(isOn: item.isOn))
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(item.isOn ? [.isSelected] : [])
    }

    /// 圆形图标底：默认白 9% / 开启转绿（原型 `.fn-ic` / `.fn-btn.on .fn-ic`）
    private func glyphCircle(_ item: FunctionPanelItem) -> some View {
        ZStack {
            Circle()
                .fill(item.isOn ? Theme.Palette.functionGlyphFillOn : Theme.Palette.functionGlyphFill)
            Circle()
                .stroke(
                    item.isOn ? Theme.Palette.functionGlyphStrokeOn : Theme.Palette.functionGlyphStroke,
                    lineWidth: 1
                )
            glyphContent(item)
        }
        .frame(
            width: Theme.Size.functionGlyphCircleSide,
            height: Theme.Size.functionGlyphCircleSide
        )
    }

    @ViewBuilder
    private func glyphContent(_ item: FunctionPanelItem) -> some View {
        switch item.glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: Theme.Size.functionGlyphSize, weight: .regular))
        case .text(let value):
            Text(value)
                .font(Theme.Typography.functionGlyphText)
                .kerning(0.2)
        }
    }

    // MARK: - foot（简易模式链接）

    private var foot: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Palette.functionFootSeparator)
                .frame(height: 0.5)

            Button(action: onSimpleModeTap) {
                HStack(spacing: 0) {
                    Text("简易模式")
                        .font(Theme.Typography.functionLink)
                        .foregroundStyle(
                            isSimpleModeOn ? Theme.Palette.ok : Theme.Palette.tertiaryText
                        )
                    Spacer(minLength: 0)
                    Text("›")
                        .font(Theme.Typography.functionLinkArrow)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
                .padding(.horizontal, Theme.Size.functionLinkHorizontalPadding)
                .frame(height: Theme.Size.functionLinkHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("简易模式")
        }
        .padding(.top, Theme.Size.functionFootTopPadding)
        .padding(.bottom, Theme.Size.functionFootBottomPadding)
        // 原型 `.fn-foot{ margin-top:14px }`（与网格之间的间距）
        .padding(.top, Theme.Size.functionFootTopSpacing)
    }
}

// MARK: - 按下反馈

/// 格子的按下态（原型 `.fn-btn:active .fn-ic{ background:rgba(255,255,255,.16) }`）。
///
/// 用自定义 `ButtonStyle` 而不是 `.buttonStyle(.plain)` + 手势：
/// 按下态只改圆形底的填充色，**不动 layout**（`docs/09` 记过原型的教训：
/// 用会替换 transform 的写法会让命中区跟着偏）。
private struct FunctionCellButtonStyle: ButtonStyle {

    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                Group {
                    if configuration.isPressed {
                        Circle()
                            .fill(Theme.Palette.functionGlyphFillPressed)
                            .frame(
                                width: Theme.Size.functionGlyphCircleSide,
                                height: Theme.Size.functionGlyphCircleSide
                            )
                            // 圆形底画在标签上方那一段；用 alignment 顶到格子顶部
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
