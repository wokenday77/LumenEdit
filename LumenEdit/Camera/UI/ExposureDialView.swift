import SwiftUI

// MARK: - EV 圆盘几何（模块 #8 · B3a）

/// EV 圆盘的**纯几何与常量**，全部对齐原型 `DIALS.ev`（2026-09-17 第八轮定稿：
/// 与对焦圆盘共用一套组件、EV 是它的**反向镜像**）。
///
/// ⚠️ 原型的半径体系写在 **SVG viewBox 400 坐标系**里、随容器等比缩放 ——
/// 本视图用同一个 400 坐标系画 Path、再按 `size/400` 缩放，
/// 所以**改 `Theme.Size.evDialSize` 一个值，刻度/数字/指针/高亮段自动同步**，
/// 不可能出现"盘改大了刻度半径没跟上"的脱节（原型注释里那次 bug 的教训）。
enum EvDialGeometry {

    enum TickKind { case minor, mid, major }

    // 半径体系（原型 `FD_R_*`，400 坐标系）
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

    // 档位体系（原型 `DIALS.ev`：count 61 / min -3 / max 3 / litSpan 0.05）
    /// 刻度根数：±3 EV、0.1 一根 → 61 根
    static let count = 61
    static let minValue: Double = -3
    static let maxValue: Double = 3
    /// 当前值附近的高亮段半宽（归一化 0~1，原型 `litSpan = 0.05`）
    static let litSpan: Double = 0.05
    /// EV 步进（0.1，原型 `set` 里 `Math.round(v*10)/10`）
    static let step: Double = 0.1

    /// 刻度分级：**主 7**（每 1 EV，带数字）/ **中 6**（每 0.5 EV）/ 其余副（原型 `tickKind`）
    static func tickKind(at index: Int) -> TickKind {
        if index % 10 == 0 { return .major }
        if index % 5 == 0 { return .mid }
        return .minor
    }

    /// **CSS 角**（0° = 12 点方向，顺时针为正）→ 值 v ∈ [0,1] 的刻度角。
    ///
    /// 镜像盘（EV）：v=0 正下(180°) → v=0.5 正左(270°) → v=1 正上(360°)。
    /// 对焦盘（非镜像）是 `180 − v·180` —— 两盘"0 在正下、满值在正上"，
    /// 中间值一个走左、一个走右，这就是反向镜像（B3b 对焦盘复用本函数，传 `mirror: false`）。
    static func angle(ofNormalized v: Double, mirror: Bool = true) -> Double {
        mirror ? 180 + v * 180 : 180 - v * 180
    }

    /// 指针角：对焦盘 3 点(90°)、**EV 盘 9 点(270°)** —— 指针钉死不动，正对各自数值框。
    static let pointerDeg: Double = 270

    /// 归一化 v → EV 值（0.1 步进取整，clamp ±3）
    static func evValue(normalized v: Double) -> Double {
        let raw = minValue + v * (maxValue - minValue)
        return (raw / step).rounded() * step
    }

    /// EV 值 → 归一化 v ∈ [0,1]
    static func normalized(_ ev: Double) -> Double {
        (ev - minValue) / (maxValue - minValue)
    }

    /// 极坐标 → 400 坐标系点（圆心 200,200）：CSS 角 θ 的点 = (200 + r·sinθ, 200 − r·cosθ)。
    /// 原型 `fdPoint`；`mirror` 不影响本函数 —— 镜像语义全在 `angle(ofNormalized:)` 里。
    static func point(radius: Double, cssDeg deg: Double) -> CGPoint {
        let a = deg * Double.pi / 180
        return CGPoint(x: 200 + radius * sin(a), y: 200 - radius * cos(a))
    }

    /// 数值框文本（原型 `fmt`）：`+1.5 EV` / `0.0 EV` / `-1.5 EV`
    static func valueText(_ ev: Double) -> String {
        (ev >= 0 ? "+" : "") + String(format: "%.1f", ev) + " EV"
    }

    /// 盘上主刻度数字（原型 `numText`）：0 → "0"，其余带符号一位小数
    static func tickNumberText(_ ev: Double) -> String {
        ev == 0 ? "0" : (ev > 0 ? "+" : "") + String(format: "%.1f", ev)
    }
}

// MARK: - EV 圆盘视图

/// EV 圆盘（曝光补偿 · 模块 #8）：点图标行「曝光补偿」展开的**模态**圆盘。
///
/// ## 形态（原型 `.ev-dial`，1:1）
///
///   - 直径 246，圆心**钉在图标行「曝光补偿」按钮中心**（第 6 格，见 `centerX` 的推导），
///     **右半出屏**（与对焦盘的"左半出屏"互为镜像 —— 参考图本身就是这个裁切）；
///   - 刻度弧只在**左半圈**：0.0 正下 → −3 走左下…+3 在正上（0 在正下、满值在正上）；
///   - 「**刻度动、指针不动**」：指针钉死 9 点，刻度环整体旋转到"当前档位停在指针下"；
///   - 数值框在**盘左**（右缘钉盘左缘外 8pt），绿色描边 + 等宽数字，**点击归零**；
///   - 61 根刻度（主 7 / 中 6 / 副 48）+ 当前值附近的高亮段。
///
/// ## 分工（与刻度条 / EV 滑条同构）
///
/// 本视图只管"跟手 + 0.1 步进"；**值写硬件由 VM 承接** —— 每跨 0.1 回调
/// `onValueChanged(value, true)`，松手回调 `(当前值, false)`。
/// 回调进 `CameraViewModel.evDialValueChanged`，走 `exposureEditingChanged` 的
/// `docs/14` 编辑态闸门（拖动期不回写 + 只接受最后推送值）—— **不是另起炉灶**。
struct ExposureDialView: View {

    /// 当前 EV 值（**硬件真值**，来自 `viewModel.exposureBias`；拖动期由 VM 同步更新）
    let value: Double
    /// 跨 0.1 / 松手回调：`(值, 是否仍在拖动)`
    let onValueChanged: (Double, Bool) -> Void
    /// 数值框点击归零
    let onZeroTapped: () -> Void
    /// 提示条（圆盘打开期间的 toast **在这里显示**）。
    ///
    /// 为什么：toast 常驻位置在底栈上方，而圆盘打开时底栈虽隐藏但占位不变 ——
    /// toast 正好落在盘体后面被盖住。原型同款处理：`.screen.dial-on .toast{ top:38% }`
    /// 把 toast 抬到取景器上半区。
    let toastText: String?

    /// 圆心 X = 图标行第 6 格「曝光补偿」的中心。
    ///
    /// 推导（与 `ToolIconRow` 的布局一致，全部读 Theme 令牌，不写死屏幕数）：
    /// 图标行外有 `md` 横向 padding（cameraContent 容器）、自身又有 `xs` 横向 padding，
    /// 7 格均分 → 第 i 格中心 = md + xs + (i + 0.5) × 格宽。iconEV 是第 6 格（i = 5）。
    private func centerX(containerWidth w: CGFloat) -> CGFloat {
        let cell = (w - 2 * Theme.Spacing.md - 2 * Theme.Spacing.xs) / 7
        return Theme.Spacing.md + Theme.Spacing.xs + 5.5 * cell
    }

    /// 圆心 Y = 底栈里图标行的**竖直中心**（原型 `--fd-center-y` 的推导方式同款：
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

    /// 数值框中心 X = 圆心 − (半径 + 间隙 + 框宽/2)（原型 `right: calc(50% + size/2 + 8px)`：
    /// 框的**右缘**钉在盘左缘外 8pt —— 固定框宽让这条式子不依赖文本测量）
    private func valueBoxCenterX(centerX: CGFloat) -> CGFloat {
        centerX - (Theme.Size.evDialSize / 2
            + Theme.Size.evDialValueBoxGap
            + Theme.Size.evDialValueBoxWidth / 2)
    }

    /// 拖动期最近一次上报的值（0.1 步进只在**跨档**时上报，停在同一档不重复推）
    @State private var lastReported: Double?
    /// 触觉节流（与刻度条同一量级：0.15s）
    @State private var lastTickAt: Date = .distantPast

    var body: some View {
        GeometryReader { proxy in
            let cx = centerX(containerWidth: proxy.size.width)
            let cy = centerY(containerHeight: proxy.size.height)

            ZStack {
                dial
                    .position(x: cx, y: cy)
                    .gesture(dragGesture(center: CGPoint(x: Theme.Size.evDialSize / 2,
                                                         y: Theme.Size.evDialSize / 2)))

                valueBox
                    .position(x: valueBoxCenterX(centerX: cx), y: cy)

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
        .accessibilityLabel("曝光补偿圆盘")
    }

    // MARK: - 盘体

    private var dial: some View {
        let size = Theme.Size.evDialSize
        return ZStack {
            // 盘底（原型 radial-gradient，中心偏上 45%）
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 28 / 255, green: 31 / 255, blue: 37 / 255).opacity(0.78),
                            Color(red: 16 / 255, green: 19 / 255, blue: 23 / 255).opacity(0.84),
                            Color(red: 10 / 255, green: 12 / 255, blue: 15 / 255).opacity(0.88)
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
                    EvDialGeometry.pointerDeg
                        - EvDialGeometry.angle(ofNormalized: EvDialGeometry.normalized(value))
                ))

            // 指针：钉死 9 点 —— "指针不动"
            pointer
                .rotationEffect(.degrees(EvDialGeometry.pointerDeg))

            // 盘心标签（⊖ 图标 + 「曝光补偿」），不接收触摸
            hub
        }
        .frame(width: size, height: size)
        // 内描边（原型 inset 0 0 0 .5px rgba(255,255,255,.08)）
        .overlay(
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// 刻度环：三条粗细各一条 Path（48 副 / 6 中 / 7 主）+ 高亮段 Path + 7 个数字。
    /// 全部在 400 坐标系按各自**绝对角度**画，整体旋转交给外层（见 `dial`）。
    private var tickRing: some View {
        let size = Theme.Size.evDialSize
        let scale = Double(size) / 400
        let n = EvDialGeometry.count - 1
        let currentV = EvDialGeometry.normalized(value)

        func tickPath(_ kinds: EvDialGeometry.TickKind...) -> Path {
            var path = Path()
            for i in 0...n {
                let kind = EvDialGeometry.tickKind(at: i)
                guard kinds.contains(kind) else { continue }
                let len = EvDialGeometry.tickLength[kind] ?? 12
                let deg = EvDialGeometry.angle(ofNormalized: Double(i) / Double(n))
                let outer = EvDialGeometry.point(radius: EvDialGeometry.rOut, cssDeg: deg)
                let inner = EvDialGeometry.point(radius: EvDialGeometry.rOut - len, cssDeg: deg)
                path.move(to: CGPoint(x: outer.x * scale, y: outer.y * scale))
                path.addLine(to: CGPoint(x: inner.x * scale, y: inner.y * scale))
            }
            return path
        }

        func litPath() -> Path {
            var path = Path()
            for i in 0...n {
                guard abs(Double(i) / Double(n) - currentV) <= EvDialGeometry.litSpan else { continue }
                let kind = EvDialGeometry.tickKind(at: i)
                let len = EvDialGeometry.tickLength[kind] ?? 12
                let deg = EvDialGeometry.angle(ofNormalized: Double(i) / Double(n))
                let outer = EvDialGeometry.point(radius: EvDialGeometry.rOut, cssDeg: deg)
                let inner = EvDialGeometry.point(radius: EvDialGeometry.rOut - len, cssDeg: deg)
                path.move(to: CGPoint(x: outer.x * scale, y: outer.y * scale))
                path.addLine(to: CGPoint(x: inner.x * scale, y: inner.y * scale))
            }
            return path
        }

        return ZStack {
            Path(tickPath(.minor))
                .stroke(Color.white.opacity(0.26), lineWidth: 1.1 * scale)
            Path(tickPath(.mid))
                .stroke(Color.white.opacity(0.46), lineWidth: 1.7 * scale)
            Path(tickPath(.major))
                .stroke(Color.white.opacity(0.88), lineWidth: 2.4 * scale)
            // 当前值附近的高亮段：绿色 + 外发光（原型 .fd-lit）
            Path(litPath())
                .stroke(Theme.Palette.dialAccent, lineWidth: 2.6 * scale)
                .shadow(color: Theme.Palette.dialAccent.opacity(0.75), radius: 2.5)

            // 主刻度数字：位置在角度 θ_i 的数字环上，自转 θ_i + 180 = "上指向圆心"
            // （原型两层 transform 的合成等价：绕盘心转 θ_i + 绕自身转 180）
            ForEach(0...n, id: \.self) { i in
                let kind = EvDialGeometry.tickKind(at: i)
                if kind == .major {
                    let deg = EvDialGeometry.angle(ofNormalized: Double(i) / Double(n))
                    let p = EvDialGeometry.point(radius: EvDialGeometry.rNum, cssDeg: deg)
                    let ev = EvDialGeometry.minValue
                        + Double(i) / Double(n) * (EvDialGeometry.maxValue - EvDialGeometry.minValue)
                    Text(EvDialGeometry.tickNumberText(ev))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .position(x: p.x * scale, y: p.y * scale)
                        .rotationEffect(.degrees(deg + EvDialGeometry.numFlip))
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// 指针：绿色三角，尖端朝圆心、贴刻度环外缘（12 点方向画好，整体转到 9 点）
    private var pointer: some View {
        let size = Theme.Size.evDialSize
        let scale = Double(size) / 400
        let tip = CGPoint(x: 200, y: 200 - EvDialGeometry.ptrTip)
        let baseL = CGPoint(x: 200 - EvDialGeometry.ptrHalf, y: 200 - EvDialGeometry.ptrBase)
        let baseR = CGPoint(x: 200 + EvDialGeometry.ptrHalf, y: 200 - EvDialGeometry.ptrBase)
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

    /// 盘心标签：⊖ 图标 + 「曝光补偿」（原型 `.ev-hub`；图标自画 —— SF Symbol 名写错会静默留白）
    private var hub: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.92), lineWidth: 1.7)
                    .frame(width: Theme.Size.evDialHubIconSize - 6,
                           height: Theme.Size.evDialHubIconSize - 6)
                // 横线（⊖ 的减号）：宽 9pt
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 9, height: 1.7)
            }
            .frame(width: Theme.Size.evDialHubIconSize,
                   height: Theme.Size.evDialHubIconSize)

            Text("曝光补偿")
                .font(.system(size: Theme.Size.evDialHubFontSize, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.white.opacity(0.9))
        }
        .allowsHitTesting(false)
    }

    // MARK: - 数值框（盘左 · 点击归零）

    private var valueBox: some View {
        Text(EvDialGeometry.valueText(value))
            .font(.system(size: Theme.Size.evDialValueFontSize,
                          weight: .bold,
                          design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Theme.Palette.dialAccent)
            .frame(width: Theme.Size.evDialValueBoxWidth,
                   height: Theme.Size.evDialValueBoxHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 13 / 255, green: 16 / 255, blue: 19 / 255).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.Palette.dialAccent, lineWidth: 1.5)
            )
            .shadow(color: Theme.Palette.dialAccent.opacity(0.26), radius: 7)
            .onTapGesture { onZeroTapped() }
            .accessibilityLabel("当前曝光补偿，点按归零")
    }

    // MARK: - 拖拽（原型 dialFromPoint 的 mirror 分支，逐行同构）

    private func dragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let v = normalizedValue(from: gesture.location, center: center)
                let ev = EvDialGeometry.evValue(normalized: v)
                guard ev != lastReported else { return }
                lastReported = ev
                onValueChanged(ev, true)
                fireTickThrottled()
            }
            .onEnded { _ in
                defer { lastReported = nil }
                // 松手：把当前值按"结束编辑"再报一次（吸附语义 = 0.1 步进本身就是最近档）
                let ev = lastReported ?? value
                onValueChanged(ev, false)
                fireTickThrottled()
            }
    }

    /// 触摸点 → 归一化 v ∈ [0,1]（原型 `dialFromPoint` 的 **mirror 分支**）：
    /// CSS 角 = atan2(dx, −dy)（0° 在上、顺时针）；有效弧 = 左半圈 [180°, 360°]，
    /// 拖到右半圈（无效区、也是最靠屏外那侧）就近吸到两端。
    private func normalizedValue(from location: CGPoint, center: CGPoint) -> Double {
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        var css = atan2(dx, -dy) * 180 / .pi
        if css < 0 { css += 360 }
        if css >= 180 {
            return (css - 180) / 180
        }
        return css > 90 ? 0 : 1
    }

    /// 带节流的跨档触感（量级与刻度条一致：0.15s）
    private func fireTickThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= 0.15 else { return }
        lastTickAt = now
        Haptics.tick()
    }
}
