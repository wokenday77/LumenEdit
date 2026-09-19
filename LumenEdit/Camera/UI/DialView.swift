import SwiftUI

// MARK: - 圆盘几何（EV / 对焦两盘共用 · 模块 #8）

/// 圆盘的**纯几何与常量**，对齐原型 `DIALS` 组件（2026-09-17 第八轮定稿：
/// 对焦 / 曝光补偿**共用一套**，两盘互为反向镜像）。
///
/// ⚠️ 原型的半径体系写在 **SVG viewBox 400 坐标系**里、随容器等比缩放 ——
/// 本视图用同一个 400 坐标系画 Path、再按 `size/400` 缩放，
/// 所以**改 `Theme.Size.dialSize` 一个值，刻度/数字/指针/高亮段自动同步**，
/// 不可能出现"盘改大了刻度半径没跟上"的脱节（原型注释里那次 bug 的教训）。
enum DialGeometry {

    enum TickKind { case minor, mid, major }

    // 半径体系（原型 `FD_R_*`，400 坐标系，两盘共用）
    /// 刻度外沿（原型 `FD_R_OUT = 188`）
    static let rOut: Double = 188
    /// 数字环半径（原型 `FD_R_NUM = 140`）
    static let rNum: Double = 140
    /// 指针：尖端 / 底边 / 半宽（原型 `FD_PTR`，尖端朝圆心、贴刻度环外缘）
    static let ptrTip: Double = 190
    static let ptrBase: Double = 197
    static let ptrHalf: Double = 7
    /// 三层刻度长度，比例 1 : 1.7 : 2.7（原型 `FD_LEN`）
    static let tickLength: [TickKind: Double] = [.minor: 12, .mid: 20, .major: 32]
    /// 数字自转角（原型 `FD_NUM_FLIP = 180`：每个数字的"上"指向圆心）
    static let numFlip: Double = 180

    /// **CSS 角**（0° = 12 点方向，顺时针为正）→ 值 v ∈ [0,1] 的刻度角。
    ///
    /// 镜像盘（EV）：v=0 正下(180°) → v=0.5 正左(270°) → v=1 正上(360°)。
    /// 对焦盘（非镜像）：v=0 正下(180°) → v=0.5 正右(90°) → v=1 正上(0°)。
    /// 两盘"0 在正下、满值在正上"，中间值一个走左、一个走右 —— 这就是反向镜像
    /// （`docs/19` 第二节：镜像布局的物理自洽 —— 两盘"盘跟手"一致、值方向相反是必然）。
    static func angle(ofNormalized v: Double, mirror: Bool) -> Double {
        mirror ? 180 + v * 180 : 180 - v * 180
    }

    /// 极坐标 → 400 坐标系点（圆心 200,200）：CSS 角 θ 的点 = (200 + r·sinθ, 200 − r·cosθ)。
    /// 原型 `fdPoint`；`mirror` 不影响本函数 —— 镜像语义全在 `angle(ofNormalized:mirror:)` 里。
    static func point(radius: Double, cssDeg deg: Double) -> CGPoint {
        let a = deg * Double.pi / 180
        return CGPoint(x: 200 + radius * sin(a), y: 200 - radius * cos(a))
    }

    /// 归一化步进取整：`raw = min + v·(max−min)`，按 `step` 取整并 clamp。
    static func value(normalized v: Double, min minValue: Double, max maxValue: Double, step: Double) -> Double {
        let raw = minValue + v * (maxValue - minValue)
        return (raw / step).rounded() * step
    }

    /// 值 → 归一化 v ∈ [0,1]
    static func normalized(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        let span = maxValue - minValue
        guard span > 0 else { return 0 }
        return (value - minValue) / span
    }
}

// MARK: - 圆盘配置（两盘差异全在这里，`docs/19` 第二节规格表的代码化）

/// 一颗圆盘的**全部可变差异**。加新差异时先进这张表，不要在 `DialView` 里写
/// `if config.id == "ev"` —— 那是差异表失效的开始（单一真源）。
struct DialConfig {
    enum HubStyle { case exposureMinus, focusReticle }

    /// 标识（日志 / 无障碍文案用）
    let id: String
    /// 镜像：EV `true`（露左半、右半出屏）；对焦 `false`（露右半、左半出屏）
    let mirror: Bool
    /// 指针角：EV 9 点(270°) / 对焦 3 点(90°) —— 指针钉死不动，正对各自数值框
    let pointerDeg: Double
    /// 档位根数（原型 count）：EV 61（±3 / 0.1）/ 对焦 51（0~1 / 0.02 一根…见原型 51 档）
    let count: Int
    let minValue: Double
    let maxValue: Double
    /// 步进：EV 0.1（原型 `Math.round(v*10)/10`）/ 对焦 0.01（显示两位小数）
    let step: Double
    /// 当前值附近的高亮段半宽（归一化）：EV 0.05 / 对焦 0.06（原型 `litSpan`）
    let litSpan: Double
    /// 档位分级闭包（两盘规则不同，原型 `tickKind`）
    let tickKind: (Int) -> DialGeometry.TickKind
    /// 数值框文案：EV `+1.5 EV` / 对焦 `0.56`（≥0.995 显示 ∞）
    let valueText: (Double) -> String
    /// 盘上主刻度数字：EV `+1.5`（0 显示 `0`）/ 对焦 `0.0 … 1.0`
    let tickNumberText: (Double) -> String
    /// 盘心标题：曝光补偿 / 对焦
    let hubTitle: String
    /// 盘心图标样式（自画 —— SF Symbol 名写错静默留白）
    let hubStyle: DialConfig.HubStyle
    /// 数值框在盘**左**（EV）还是盘**右**（对焦）
    let valueBoxOnLeading: Bool
    /// 数值框可点（EV = 归零；对焦原型无数值框点击行为）
    let valueBoxTappable: Bool
    /// 圆心锚在第几格图标中心（EV 第 6 格 = 5.5 / 对焦第 2 格 = 1.5；见 `DialView.centerX`）
    let anchorCellIndex: CGFloat
    /// 是否有盘下「自动对焦」开关行（对焦专属，原型 `.fd-auto`）
    let hasAutoSwitch: Bool

    // MARK: 两盘工厂（差异的唯一出处）

    /// EV 盘（曝光补偿）：原型 `DIALS.ev`
    static let ev = DialConfig(
        id: "ev",
        mirror: true,
        pointerDeg: 270,
        count: 61,
        minValue: -3,
        maxValue: 3,
        step: 0.1,
        litSpan: 0.05,
        tickKind: { i in
            if i % 10 == 0 { return .major }
            if i % 5 == 0 { return .mid }
            return .minor
        },
        valueText: { ev in
            (ev >= 0 ? "+" : "") + String(format: "%.1f", ev) + " EV"
        },
        tickNumberText: { ev in
            ev == 0 ? "0" : (ev > 0 ? "+" : "") + String(format: "%.1f", ev)
        },
        hubTitle: "曝光补偿",
        hubStyle: .exposureMinus,
        valueBoxOnLeading: true,
        valueBoxTappable: true,
        anchorCellIndex: 5.5,
        hasAutoSwitch: false
    )

    /// 对焦盘：原型 `DIALS.focus`（0 近 → 1 远；0.995 以上显示 ∞）
    static let focus = DialConfig(
        id: "focus",
        mirror: false,
        pointerDeg: 90,
        count: 51,
        minValue: 0,
        maxValue: 1,
        step: 0.01,
        litSpan: 0.06,
        tickKind: { i in
            // 原型：主 11（每 0.1）/ 中 20 / 副 20
            if i % 5 == 0 { return .major }
            if i % 5 == 1 || i % 5 == 4 { return .mid }
            return .minor
        },
        valueText: { v in
            v >= 0.995 ? "∞" : String(format: "%.2f", v)
        },
        tickNumberText: { v in
            String(format: "%.1f", v)
        },
        hubTitle: "对焦",
        hubStyle: .focusReticle,
        valueBoxOnLeading: false,
        valueBoxTappable: false,
        anchorCellIndex: 1.5,
        hasAutoSwitch: true
    )
}

// MARK: - 圆盘视图（EV / 对焦共用）

/// 参数圆盘（EV 曝光补偿 / 手动对焦共用 · 模块 #8）。
///
/// ## 形态（原型 `.focus-dial` / `.ev-dial`，1:1；差异全在 `DialConfig`）
///
///   - 直径 246，圆心**钉在图标行对应按钮中心**（EV 第 6 格 / 对焦第 2 格），
///     各有半边出屏（参考图本身就是这个裁切）；
///   - 「**刻度动、指针不动**」：指针钉死（EV 9 点 / 对焦 3 点），刻度环整体旋转到
///     "当前档位停在指针下"；
///   - **半透明盘底**（0.45/0.50/0.55，2026-09-19 用户拍板：透出取景画面）；
///   - **相对位移拖拽**（顺滑顺走 ΔRing = Δcss）：首次触摸**只锚定、不改值**（点击不跳值），
///     拖动按角位移增量换算，零位移松手不推值。⚠️ 该模型下 EV 盘"顺时针滑 = 值减小"
///     （物理转盘语义，2026-09-19 拍板保持；对焦盘镜像布局天然"顺时针 = 增大（近→远）"，
///     两盘值方向相反、盘跟手一致 —— `docs/19` 第四节）。
///   - 数值框：EV 盘左可点归零 / 对焦盘右不可点（∞ 上限）；
///   - 对焦盘下方有「自动对焦」开关行（`hasAutoSwitch`），状态由**硬件真值回读**驱动。
///
/// ## 分工
///
/// 本视图只管"跟手 + 步进"；**值写硬件由 VM 承接** —— 回调进 VM 的
/// `evDialValueChanged` / `focusDialValueChanged`，各自走 `docs/14` 编辑态闸门。
struct DialView: View {

    let config: DialConfig
    /// 当前值（**硬件真值**，来自 VM；拖动期由 VM 同步更新）
    let value: Double
    /// 自动档（**对焦盘专属**：自动对焦开着 = 锁定手动拖动；EV 盘传 `nil`）
    let autoMode: Bool?
    /// 提示条（圆盘打开期间的 toast **在这里显示**，抬到取景器上半区 —— 原型
    /// `.dial-on .toast{ top:38% }`；原位会被盘体盖住）。
    let toastText: String?
    /// 跨档 / 松手回调：`(值, 是否仍在拖动)`
    let onValueChanged: (Double, Bool) -> Void
    /// 数值框点击（EV = 归零；对焦 `config.valueBoxTappable == false` 时不挂手势）
    let onValueBoxTapped: (() -> Void)?
    /// 自动对焦开关回调（对焦盘专属）
    let onAutoToggled: (() -> Void)?

    /// 圆心 X = 图标行第 `anchorCellIndex + 0.5` 格的中心。
    ///
    /// 推导（与 `ToolIconRow` 的布局一致，全部读 Theme 令牌，不写死屏幕数）：
    /// 图标行外有 `md` 横向 padding（cameraContent 容器）、自身又有 `xs` 横向 padding，
    /// 7 格均分 → 第 i 格中心 = md + xs + (i + 0.5) × 格宽。
    /// EV 第 6 格（i=5 → 5.5）/ 对焦第 2 格（i=1 → 1.5，原型 `--fd-center-x:83.1` 同式）。
    private func centerX(containerWidth w: CGFloat) -> CGFloat {
        let cell = (w - 2 * Theme.Spacing.md - 2 * Theme.Spacing.xs) / 7
        return Theme.Spacing.md + Theme.Spacing.xs + config.anchorCellIndex * cell
    }

    /// 圆心 Y = 底栈里图标行的**竖直中心**（两盘相同；原型 `--fd-center-y` 的推导方式：
    /// "圆盘是以按钮为中心展开，不是贴屏幕底往上排"）。
    ///
    /// 从容器底往上：底内边距账 20（两层各 10）+ 快门排 80 + 行距 10 + 焦段条 44
    /// + 行距 10 + 图标行半高 22 —— **全部 Theme 令牌**，自检可复算。
    /// ⚠️ 圆盘打开时底栈虽被隐藏（模态），圆心仍按"底栈在位"的几何钉 —— 原型同款。
    private func centerY(containerHeight h: CGFloat) -> CGFloat {
        h - (Theme.Size.bottomStackBottomPadding
            + Theme.Size.shutterRowHeight
            + Theme.Spacing.sm
            + Theme.Size.focalStripHeight
            + Theme.Spacing.sm
            + Theme.Size.toolRowHeight / 2)
    }

    /// 数值框中心 X：EV 盘左（圆心 − 半径 − 间隙 − 框宽/2）/ 对焦盘右（+）。
    /// 原型把框的**靠盘缘**钉在盘缘外 8pt —— 固定框宽让这条式子不依赖文本测量。
    private func valueBoxCenterX(centerX cx: CGFloat) -> CGFloat {
        let offset = Theme.Size.dialSize / 2
            + Theme.Size.dialValueBoxGap
            + Theme.Size.dialValueBoxWidth / 2
        return config.valueBoxOnLeading ? cx - offset : cx + offset
    }

    /// 拖动锚点：首次触摸只记录「起始值 + 起始 CSS 角」，**不改值**（点击不改变读数）；
    /// 拖动中按**角位移增量**换算 —— 顺滑顺走，且不随 VM 回写漂移。
    @State private var dragAnchor: (value: Double, css: Double)?
    /// 拖动期最近一次上报的值（步进只在**跨档**时上报，停在同一档不重复推）
    @State private var lastReported: Double?
    /// 触觉节流（与刻度条同一量级：0.15s）
    @State private var lastTickAt: Date = .distantPast

    var body: some View {
        GeometryReader { proxy in
            let cx = centerX(containerWidth: proxy.size.width)
            let cy = centerY(containerHeight: proxy.size.height)
            let size = Theme.Size.dialSize

            ZStack {
                // ⚠️ **手势必须挂在 `.position` 之前**：`.position` 会把视图包进一个"占满父级"
                // 的容器，手势挂在其后时 `DragGesture` 的坐标空间变成整页 GeometryReader，
                // 而传入的 center 是**圆盘局部坐标**（123,123）——两者错位 → 算出的角度几乎
                // 全部落进无效弧 → 值被钉死、怎么拖都不动（2026-09-19 真机实测，[mac-fix]）。
                dial
                    .gesture(dragGesture(center: CGPoint(x: size / 2, y: size / 2)))
                    .position(x: cx, y: cy)

                valueBox
                    .position(x: valueBoxCenterX(centerX: cx), y: cy)

                // 盘下「自动对焦」开关行（对焦专属；EV `hasAutoSwitch == false` 不渲染）
                if config.hasAutoSwitch, let autoMode, let onAutoToggled {
                    autoSwitchRow(isOn: autoMode, onToggle: onAutoToggled)
                        .position(x: cx,
                                  y: cy + size / 2
                                      + Theme.Size.dialAutoSwitchGap
                                      + Theme.Size.dialAutoSwitchHeight / 2)
                }

                // 圆盘打开期间的 toast：抬到取景器上半区（原型 `top:38%`）。
                // 样式与 CameraView.toastView 一致（Capsule 黑底 + stroke）——
                // 不抽公共组件：一处 9 行的样式复制比为一个胶囊建共享视图划算。
                if let toastText {
                    Text(toastText)
                        .font(Theme.Typography.toast)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .overlay(Capsule().stroke(Theme.Palette.stroke, lineWidth: 0.5))
                        .accessibilityAddTraits(.isStaticText)
                        .position(x: proxy.size.width / 2,
                                  y: proxy.size.height * 0.38)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: toastText)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(config.hubTitle)圆盘")
    }

    // MARK: - 盘体

    private var dial: some View {
        let size = Theme.Size.dialSize
        return ZStack {
            // 盘底（原型 radial-gradient，中心偏上 45%）。
            // ⚠️ **半透明（2026-09-19 用户拍板）**：圆盘要"透出背后的取景画面"
            // （参考飓风相机对焦圆盘的效果）。原型旧口径 0.78/0.84/0.88 是"接近实底"，
            // 现为 **0.45/0.50/0.55**（色相不变，只降 alpha）。
            // 刻度/数字/指针**保持不透明**（可读性优先）。
            // ⚠️ **盘底只此一份**：对焦 / EV 两盘共用本组件 —— 别处再写一份盘底渐变
            // 就是抄第二份（自检守着：RadialGradient 全仓唯一）。
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 28 / 255, green: 31 / 255, blue: 37 / 255).opacity(0.45),
                            Color(red: 16 / 255, green: 19 / 255, blue: 23 / 255).opacity(0.50),
                            Color(red: 10 / 255, green: 12 / 255, blue: 15 / 255).opacity(0.55)
                        ],
                        center: UnitPoint(x: 0.5, y: 0.45),
                        startRadius: 0,
                        endRadius: size / 2
                    )
                )
                .shadow(color: .black.opacity(0.5), radius: 17, x: 0, y: 4)

            // 刻度环（刻度 + 数字 + 高亮段）：整体旋转 —— "刻度动"
            tickRing
                .rotationEffect(.degrees(
                    config.pointerDeg
                        - DialGeometry.angle(ofNormalized: normalizedValue, mirror: config.mirror)
                ))

            // 指针：钉死 —— "指针不动"（EV 9 点 / 对焦 3 点）
            pointer
                .rotationEffect(.degrees(config.pointerDeg))

            // 盘心标签，不接收触摸
            hub
        }
        .frame(width: size, height: size)
        // 内描边（原型 inset 0 0 0 .5px rgba(255,255,255,.08)）
        .overlay(
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// 当前值的归一化（拖动期由 VM 同步更新 `value`，此处只做映射）
    private var normalizedValue: Double {
        DialGeometry.normalized(value, min: config.minValue, max: config.maxValue)
    }

    /// 刻度环：三条粗细各一条 Path + 高亮段 Path + 主刻度数字。
    /// 全部在 400 坐标系按各自**绝对角度**画，整体旋转交给外层（见 `dial`）。
    private var tickRing: some View {
        let size = Theme.Size.dialSize
        let scale = Double(size) / 400
        let n = config.count - 1
        let currentV = normalizedValue

        func tickPath(_ kinds: DialGeometry.TickKind...) -> Path {
            var path = Path()
            for i in 0...n {
                let kind = config.tickKind(i)
                guard kinds.contains(kind) else { continue }
                let len = DialGeometry.tickLength[kind] ?? 12
                let deg = DialGeometry.angle(ofNormalized: Double(i) / Double(n), mirror: config.mirror)
                let outer = DialGeometry.point(radius: DialGeometry.rOut, cssDeg: deg)
                let inner = DialGeometry.point(radius: DialGeometry.rOut - len, cssDeg: deg)
                path.move(to: CGPoint(x: outer.x * scale, y: outer.y * scale))
                path.addLine(to: CGPoint(x: inner.x * scale, y: inner.y * scale))
            }
            return path
        }

        func litPath() -> Path {
            var path = Path()
            for i in 0...n {
                guard abs(Double(i) / Double(n) - currentV) <= config.litSpan else { continue }
                let kind = config.tickKind(i)
                let len = DialGeometry.tickLength[kind] ?? 12
                let deg = DialGeometry.angle(ofNormalized: Double(i) / Double(n), mirror: config.mirror)
                let outer = DialGeometry.point(radius: DialGeometry.rOut, cssDeg: deg)
                let inner = DialGeometry.point(radius: DialGeometry.rOut - len, cssDeg: deg)
                path.move(to: CGPoint(x: outer.x * scale, y: outer.y * scale))
                path.addLine(to: CGPoint(x: inner.x * scale, y: inner.y * scale))
            }
            return path
        }

        return ZStack {
            // ⚠️ `tickPath` 返回的就是 `Path`（Path 本身就是 Shape，可直接 .stroke）——
            // 不能再包一层 `Path(...)`：SwiftUICore.Path 没有 `init(Path)` 初始化器
            // （2026-09-19 Mac 侧编译实测）。
            tickPath(.minor)
                .stroke(Color.white.opacity(0.26), lineWidth: 1.1 * scale)
            tickPath(.mid)
                .stroke(Color.white.opacity(0.46), lineWidth: 1.7 * scale)
            tickPath(.major)
                .stroke(Color.white.opacity(0.88), lineWidth: 2.4 * scale)
            // 当前值附近的高亮段：绿 + 外发光（原型 .fd-lit）
            litPath()
                .stroke(Theme.Palette.dialAccent, lineWidth: 2.6 * scale)
                .shadow(color: Theme.Palette.dialAccent.opacity(0.75), radius: 2.5)

            // 主刻度数字：位置在角度 θ_i 的数字环上，自转 θ_i + 180 = "上指向圆心"
            // （原型两层 transform 的合成等价：绕盘心转 θ_i + 绕自身转 180）
            ForEach(0...n, id: \.self) { i in
                let kind = config.tickKind(i)
                if kind == .major {
                    let deg = DialGeometry.angle(ofNormalized: Double(i) / Double(n), mirror: config.mirror)
                    let p = DialGeometry.point(radius: DialGeometry.rNum, cssDeg: deg)
                    let tickValue = config.minValue
                        + Double(i) / Double(n) * (config.maxValue - config.minValue)
                    Text(config.tickNumberText(tickValue))
                        // ⚠️ **字号必须乘 `scale`**：原型里刻度数字是 SVG `<text>`（viewBox 400，
                        // 字号 13 是**用户单位**，随容器等比缩放到 246pt 盘 → 实际 ≈8pt）。
                        // 曾写死 13pt → 比原型大 62%（2026-09-19 用户截图报偏大，[mac-fix]）。
                        .font(.system(size: 13 * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        // ⚠️ **自转必须在 `.position` 之前**：`.position` 会把 Text 包进一个
                        // 占满整个 tickRing 的容器，之后的 `.rotationEffect` 转的是**该容器**
                        // （绕盘心），不是文字自身 → 每个数字被双重旋转：间距翻倍、−3/+3 重叠
                        //（2026-09-19 真机实测，[mac-fix]；与拖不动那条同源：`.position`
                        // 之后挂的修饰器都作用在"占满父级"的容器上）。
                        .rotationEffect(.degrees(deg + DialGeometry.numFlip))
                        .position(x: p.x * scale, y: p.y * scale)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// 指针：绿色三角，尖端朝圆心、贴刻度环外缘（12 点方向画好，整体转到目标角）
    private var pointer: some View {
        let size = Theme.Size.dialSize
        let scale = Double(size) / 400
        let tip = CGPoint(x: 200, y: 200 - DialGeometry.ptrTip)
        let baseL = CGPoint(x: 200 - DialGeometry.ptrHalf, y: 200 - DialGeometry.ptrBase)
        let baseR = CGPoint(x: 200 + DialGeometry.ptrHalf, y: 200 - DialGeometry.ptrBase)
        return Path { path in
            path.move(to: CGPoint(x: tip.x * scale, y: tip.y * scale))
            path.addLine(to: CGPoint(x: baseL.x * scale, y: baseL.y * scale))
            path.addLine(to: CGPoint(x: baseR.x * scale, y: baseR.y * scale))
            path.closeSubpath()
        }
        .fill(Theme.Palette.dialAccent)
        .shadow(color: Theme.Palette.dialAccent.opacity(0.7), radius: 3)
        .frame(width: size, height: size)
    }

    /// 盘心标签（图标按 `hubStyle` 自画 + 标题；不用 SF Symbol —— 名字写错静默留白）
    private var hub: some View {
        VStack(spacing: 7) {
            hubIcon
                .frame(width: Theme.Size.dialHubIconSize,
                       height: Theme.Size.dialHubIconSize)

            Text(config.hubTitle)
                .font(.system(size: Theme.Size.dialHubFontSize, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.white.opacity(0.9))
        }
        .allowsHitTesting(false)
    }

    /// 盘心图标（22pt 框内自画）：
    /// - `.exposureMinus`：⊖（圆环 + 横线，原型 EV hub）
    /// - `.focusReticle`：◎ 对焦 reticle（中心实点 + 虚线圆 + 上下左右四条短刻线，原型 focus hub）
    @ViewBuilder
    private var hubIcon: some View {
        switch config.hubStyle {
        case .exposureMinus:
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.92), lineWidth: 1.7)
                    .frame(width: Theme.Size.dialHubIconSize - 6,
                           height: Theme.Size.dialHubIconSize - 6)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 9, height: 1.7)
            }
        case .focusReticle:
            let line = Color.white.opacity(0.92)
            ZStack {
                // 中心实点
                Circle()
                    .fill(line)
                    .frame(width: 5, height: 5)
                // 虚线圆（原型 stroke-dasharray="2 3"）
                Circle()
                    .stroke(line, style: StrokeStyle(lineWidth: 1.7, dash: [2, 3]))
                    .frame(width: 15, height: 15)
                // 上下左右四条短刻线（原型 M12 2.4v3 / M2.4 12h3 …）
                VStack(spacing: 0) {
                    hubTickV; Spacer(minLength: 0); hubTickV
                }
                .frame(height: Theme.Size.dialHubIconSize)
                HStack(spacing: 0) {
                    hubTickH; Spacer(minLength: 0); hubTickH
                }
                .frame(width: Theme.Size.dialHubIconSize)
            }
        }
    }

    /// reticle 竖向短刻线（1.7 × 3）
    private var hubTickV: some View {
        RoundedRectangle(cornerRadius: 0.8, style: .continuous)
            .fill(Color.white.opacity(0.92))
            .frame(width: 1.7, height: 3)
    }

    /// reticle 横向短刻线（3 × 1.7）
    private var hubTickH: some View {
        RoundedRectangle(cornerRadius: 0.8, style: .continuous)
            .fill(Color.white.opacity(0.92))
            .frame(width: 3, height: 1.7)
    }

    // MARK: - 数值框（EV 盘左可归零 / 对焦盘右不可点）

    private var valueBox: some View {
        Text(config.valueText(value))
            .font(.system(size: Theme.Size.dialValueFontSize,
                          weight: .bold,
                          design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Theme.Palette.dialAccent)
            .frame(width: Theme.Size.dialValueBoxWidth,
                   height: Theme.Size.dialValueBoxHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 13 / 255, green: 16 / 255, blue: 19 / 255).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.Palette.dialAccent, lineWidth: 1.5)
            )
            .shadow(color: Theme.Palette.dialAccent.opacity(0.26), radius: 7)
            .onTapGesture {
                if config.valueBoxTappable { onValueBoxTapped?() }
            }
            .accessibilityLabel(config.valueBoxTappable
                ? "当前\(config.hubTitle)，点按归零"
                : "当前\(config.hubTitle)")
    }

    // MARK: - 「自动对焦」开关行（对焦盘专属 · 原型 `.fd-auto`）

    /// 视觉与刻度条右端开关同语言（原型同一个 `.sw` 类：47×29 / on 绿）。
    /// 状态由**硬件真值回读**驱动（`focusMode == .locked` = 手动），不本地记账。
    private func autoSwitchRow(isOn: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Button {
                onToggle()
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Theme.Palette.dialSwitchOn : Theme.Palette.dialSwitchOff)
                        .frame(width: Theme.Size.dialAutoSwitchWidth,
                               height: Theme.Size.dialAutoSwitchHeight)
                    Circle()
                        .fill(Color.white)
                        .frame(width: Theme.Size.dialAutoSwitchKnob,
                               height: Theme.Size.dialAutoSwitchKnob)
                        .padding(.horizontal, 2)
                }
                .frame(width: Theme.Size.dialAutoSwitchWidth,
                       height: Theme.Size.dialAutoSwitchHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("自动对焦开关")
            .accessibilityValue(isOn ? "开（已锁定拖动）" : "关（可拖动调焦）")

            Text("自动对焦")
                .font(.system(size: Theme.Size.dialAutoSwitchLabelFontSize))
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    // MARK: - 拖拽（相对位移模型：顺滑顺走 + 点击不改值，2026-09-19 用户拍板）

    private func dragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                // 自动档（对焦盘"自动对焦已开"）锁定手动拖动（原型 `focusFromPoint` 同款）
                if autoMode == true { return }

                let css = cssAngle(from: gesture.location, center: center)
                guard let anchor = dragAnchor else {
                    // 首次触摸：**只锚定、不动值**（点击不改变读数 —— 与原型 `dialFromPoint`
                    // 的"绝对定位"不同：那是按下即跳到触点位置的值，2026-09-19 用户拍板改为
                    // 只能滑动调整）。
                    dragAnchor = (value, css)
                    return
                }
                // **顺滑顺走**：指尖转多少度、盘面就转多少度（ΔRing = Δcss）。
                // 盘面旋转 R = pointerDeg − angle(v)；
                //   镜像（EV）：angle = 180+180v → R = 90−180v → Δv = −Δcss/180（顺时针滑 = 值减小）
                //   非镜像（对焦）：angle = 180−180v → R = −90+180v → Δv = +Δcss/180（顺时针 = 增大）
                // 两盘"盘跟手"一致、值方向相反 —— 镜像布局的物理自洽（`docs/19` 第四节）。
                var delta = css - anchor.css
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                let signedDelta = config.mirror ? -delta : delta
                let base = DialGeometry.normalized(anchor.value,
                                                   min: config.minValue, max: config.maxValue)
                let v = min(max(base + signedDelta / 180, 0), 1)
                let stepped = DialGeometry.value(normalized: v,
                                                 min: config.minValue,
                                                 max: config.maxValue,
                                                 step: config.step)
                guard stepped != lastReported else { return }
                lastReported = stepped
                onValueChanged(stepped, true)
                fireTickThrottled()
            }
            .onEnded { _ in
                defer { dragAnchor = nil }
                // 松手：把拖动最终值按"结束编辑"再报一次；**纯点击（零位移）什么都不推**
                guard let last = lastReported else { return }
                lastReported = nil
                onValueChanged(last, false)
                fireTickThrottled()
            }
    }

    /// 触摸点 → CSS 角（0° = 12 点方向、顺时针为正；与原型 `dialFromPoint` 同一约定）。
    /// 本模型只吃**角位移增量**，触点落在哪一半圈不影响换算（不再有"吸到两端"分支）。
    private func cssAngle(from location: CGPoint, center: CGPoint) -> Double {
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        var css = atan2(dx, -dy) * 180 / .pi
        if css < 0 { css += 360 }
        return css
    }

    /// 带节流的跨档触感（量级与刻度条一致：0.15s）
    private func fireTickThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= 0.15 else { return }
        lastTickAt = now
        Haptics.tick()
    }
}
