import SwiftUI

/// 参数刻度条几何 —— **纯算术**，自检第 12 组照着这几个式子复算，别在别处再写一遍。
///
/// 原型对应：`.strip-panel` / `.sp-clip{ right:64px }` /
/// `.sp-pointer{ left: calc((100% − 64px) / 2) }` / `SP.pad = 30` / `SP.slot`。
struct ParameterStripGeometry {

    let containerWidth: CGFloat
    let stepCount: Int
    let slot: CGFloat
    let padding: CGFloat
    let gutter: CGFloat

    /// 可视区宽（右侧让给开关）
    var visibleWidth: CGFloat { max(0, containerWidth - gutter) }

    /// 指针 X —— **固定在可视区中点**（原型 `left: calc((100% − 64px) / 2)`）
    var pointerX: CGFloat { visibleWidth / 2 }

    /// 刻度条总宽（原型 `SP.pad × 2 + (len − 1) × slot`）
    var scaleWidth: CGFloat {
        stepCount > 1 ? padding * 2 + CGFloat(stepCount - 1) * slot : padding * 2
    }

    /// 第 `index` 档停在指针下时的 translateX
    func offset(forStep index: Int) -> CGFloat {
        pointerX - padding - CGFloat(index) * slot
    }

    /// translateX → **连续**档位下标（拖动中是小数）
    func stepPosition(forOffset offset: CGFloat) -> Double {
        guard slot > 0 else { return 0 }
        return Double((pointerX - padding - offset) / slot)
    }

    /// translateX → 吸附后的档位下标（含上下限钳制）
    func snappedIndex(forOffset offset: CGFloat) -> Int {
        let raw = Int(stepPosition(forOffset: offset).rounded())
        return min(max(raw, 0), max(0, stepCount - 1))
    }

    /// translateX 的合法区间（拖到两端就停住，不会把刻度条拖飞）
    var offsetRange: ClosedRange<CGFloat> {
        let first = offset(forStep: 0)
        let last = offset(forStep: max(0, stepCount - 1))
        return min(first, last)...max(first, last)
    }
}

/// 参数刻度条（B2b · 模块 #9）：ISO / 快门 / 白平衡 **一次只显示一条**。
///
/// ## 版式（对齐原型，见 `docs/16` 第四.1 节）
///
/// ```
/// ├───────────────── 面板高 88 ──────────────────┼── 64 ──┤
/// │         气泡（绿底黑字，钉在指针上方）22        │ 开关 47×29 │
/// │             ▼ 指针三角 6×8                  30 │  「自动」   │
/// │             │ 竖线 1.5                         │           │
/// │  刻度 48–70（普通 10 / 主刻度 22 / WB 预设琥珀）  │           │
/// │  数字 73–86                                    │           │
/// └────────────────────────────────────────────────┴───────────┘
/// ```
///
/// ## 三个**刻意偏离原型**的点（都有理由）
///
/// 1. **面板高 88（原型 96）**：净可见账卡出来的上限，见 `Theme.Size.paramStripHeight`
/// 2. **加触觉 + 换档滞后**（原型的 `pointermove` **没有任何节流**）：沿用 `ParameterSlider`
///    已验证的 `0.15s` / `0.75` 档（用户 2026-09-19 拍板 ⑤）。白平衡有 76 档、
///    每档 26pt，不加滞后在边界上必然"连响"（`docs/11` 第七节踩过同一坑）
/// 3. **指针与气泡 `allowsHitTesting(false)`**：拖动必须落到刻度区，指针不许抢触摸
///   （原型 `.sp-pointer{ pointer-events:none }`）
///
/// ## 分工
///
/// 本视图只管"跟手 + 吸附"；**值写硬件由 VM 承接** —— 每次跨档回调
/// `onValueChanged(value, true)`，松手回调 `onValueChanged(snapped, false)`。
/// 自动态禁止滑动（原型 `stripIsAuto` 同款），并把刻度与数字压暗。
struct ParameterStripView: View {

    let kind: ParameterStripKind
    let steps: [ParameterStripStep]
    /// 当前显示值（`nil` = 自动态）。由 VM 给：拖动期是本地草稿、其余时刻是**硬件真值**
    let displayValue: Double?
    /// 是否自动档（右端开关状态）
    let isAuto: Bool
    /// 这台设备上**不可用**的档位值（置灰；**灰但仍可点** —— 点了由 VM 给 toast 说明）
    let unavailableValues: Set<Double>
    let onToggleAuto: () -> Void
    /// 跨档 / 松手回调：`(值, 是否仍在拖动)`
    let onValueChanged: (Double, Bool) -> Void

    /// 拖动期的 translateX；`nil` = 没在拖（此时按显示值定位）
    @State private var dragOffset: CGFloat?
    @State private var dragStartOffset: CGFloat = 0
    @State private var lastReportedIndex: Int?
    /// 方向闸门（与 `ParameterSlider` 同一套）：一次拖动只在最初 6pt 定一次主轴
    @State private var isHorizontalDrag: Bool?
    /// 触觉节流（量级与 `ParameterSlider` 一致）
    @State private var lastTickAt: Date = .distantPast

    /// **换档滞后**：离当前档位不足 0.75 档就不换（与 `ParameterSlider` 的 0.75 一致）
    private static let hysteresisRatio: Double = 0.75
    /// **触觉节流**：0.15s（与 `ParameterSlider` 一致；自检第 12 组守这个量级）
    private static let tickThrottle: TimeInterval = 0.15

    // MARK: - 几何（从令牌推导，不在视图里写死数字）

    /// 指针竖线上端 = 三角下沿
    private var pointerLineTop: CGFloat {
        Theme.Size.paramStripPointerTopInset + Theme.Size.paramStripPointerTriangleHeight
    }
    /// 指针竖线下端（原型 `bottom:6px`）
    private var pointerLineBottom: CGFloat { Theme.Size.paramStripHeight - 6 }
    private var pointerLineHeight: CGFloat { max(1, pointerLineBottom - pointerLineTop) }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ParameterStripGeometry(
                containerWidth: proxy.size.width,
                stepCount: steps.count,
                slot: ParameterStripCatalog.slot(for: kind),
                padding: Theme.Size.paramStripEdgePadding,
                gutter: Theme.Size.paramStripSwitchGutter
            )

            ZStack(alignment: .topLeading) {
                scaleArea(geometry: geometry)
                pointer(geometry: geometry)
                // 开关贴右：占满容器宽再右对齐（开关槽宽 64 由 `.frame(width:)` 定死）
                autoSwitch
                    .frame(width: proxy.size.width, alignment: .trailing)
                    .padding(.trailing, 8)
            }
            .frame(
                width: proxy.size.width,
                height: Theme.Size.paramStripHeight,
                alignment: .topLeading
            )
        }
        .frame(height: Theme.Size.paramStripHeight)
        .background(
            LinearGradient(
                colors: [Color.clear, Theme.Palette.stripPanelBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.displayName) 刻度条")
    }

    // MARK: - 刻度区（可拖动）

    private func scaleArea(geometry: ParameterStripGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(steps.indices, id: \.self) { index in
                tickContent(at: index, geometry: geometry)
            }
        }
        .frame(
            width: geometry.scaleWidth,
            height: Theme.Size.paramStripHeight,
            alignment: .topLeading
        )
        .offset(x: renderedOffset(geometry: geometry))
        // 把 translateX 之后的刻度条收进"可视区"这一层
        .frame(
            width: geometry.visibleWidth,
            height: Theme.Size.paramStripHeight,
            alignment: .topLeading
        )
        // 两端渐隐（原型 `mask-image: linear-gradient(90deg, transparent 0, #000 40px, #000 calc(100% − 40px), transparent 100%)`）
        .mask(
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.clear, Color.black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: Theme.Size.paramStripEdgeMask)
                Rectangle().fill(Color.black)
                LinearGradient(
                    colors: [Color.black, Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: Theme.Size.paramStripEdgeMask)
            }
        )
        .contentShape(Rectangle())
        .gesture(dragGesture(geometry: geometry))
        .opacity(isAuto ? 0.55 : 1)
    }

    /// 单个档位的内容：刻度线 + （可选）数字。都用 `.position` 定位在刻度条坐标系里。
    @ViewBuilder
    private func tickContent(at index: Int, geometry: ParameterStripGeometry) -> some View {
        let step = steps[index]
        let x = geometry.padding + CGFloat(index) * geometry.slot
        let isMajor = step.showsLabel
        let tickHeight = isMajor
            ? Theme.Size.paramStripTickMajorHeight
            : Theme.Size.paramStripTickHeight
        let isUnavailable = unavailableValues.contains(step.value)

        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(tickColor(step: step, isMajor: isMajor, isUnavailable: isUnavailable))
            .frame(width: Theme.Size.paramStripTickWidth, height: tickHeight)
            .position(
                x: x,
                y: Theme.Size.paramStripHeight
                    - Theme.Size.paramStripTickBottomInset
                    - tickHeight / 2
            )

        if isMajor {
            Text(step.label)
                .font(.system(size: Theme.Size.paramStripNumberFontSize, design: .rounded))
                .foregroundStyle(numberColor(isUnavailable: isUnavailable))
                .monospacedDigit()
                .fixedSize()
                .position(
                    x: x,
                    y: Theme.Size.paramStripHeight
                        - Theme.Size.paramStripNumberBottomInset
                        - Theme.Size.paramStripNumberFontSize / 2
                )
        }
    }

    /// 刻度线颜色：自动态压暗 → 不可用档压暗 → 白平衡预设档（琥珀）→ 主刻度 → 普通
    private func tickColor(step: ParameterStripStep, isMajor: Bool, isUnavailable: Bool) -> Color {
        if isAuto || isUnavailable { return Theme.Palette.stripInactive }
        if step.isPreset { return Theme.Palette.stripTickPreset }
        return isMajor ? Theme.Palette.stripTickMajor : Theme.Palette.stripTick
    }

    private func numberColor(isUnavailable: Bool) -> Color {
        (isAuto || isUnavailable) ? Theme.Palette.stripInactive : Theme.Palette.stripNumber
    }

    // MARK: - 指针 + 气泡（都固定在指针 X 上，且不接收触摸）

    private func pointer(geometry: ParameterStripGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            // 竖线
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.Palette.stripAccent)
                .frame(width: Theme.Size.paramStripPointerLineWidth, height: pointerLineHeight)
                .position(x: geometry.pointerX, y: pointerLineTop + pointerLineHeight / 2)

            // 三角（朝下）
            DownTriangle()
                .fill(Theme.Palette.stripAccent)
                .frame(
                    width: Theme.Size.paramStripPointerTriangleHalfWidth * 2,
                    height: Theme.Size.paramStripPointerTriangleHeight
                )
                .position(
                    x: geometry.pointerX,
                    y: Theme.Size.paramStripPointerTopInset
                        + Theme.Size.paramStripPointerTriangleHeight / 2
                )

            // 气泡（在指针正上方）
            Text(bubbleText)
                .font(.system(
                    size: Theme.Size.paramStripBubbleFontSize,
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundStyle(Theme.Palette.stripBubbleText)
                .monospacedDigit()
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: Theme.Size.paramStripBubbleHeight)
                .background(Capsule().fill(Theme.Palette.stripAccent))
                .position(x: geometry.pointerX, y: Theme.Size.paramStripBubbleHeight / 2)
        }
        // 原型 `.sp-pointer{ pointer-events:none }` —— 拖动要落到刻度区，指针不许抢触摸
        .allowsHitTesting(false)
    }

    /// 气泡文本：自动态显示「自动」，否则显示当前档位（原型 `fmt`）
    private var bubbleText: String {
        guard !isAuto, let value = displayValue else { return "自动" }
        return ParameterStripCatalog.label(for: kind, value: value)
    }

    // MARK: - 右端自动 / 手动开关

    private var autoSwitch: some View {
        VStack(spacing: 6) {
            Button {
                onToggleAuto()
            } label: {
                ZStack(alignment: isAuto ? .trailing : .leading) {
                    Capsule()
                        .fill(isAuto ? Theme.Palette.stripAccent : Theme.Palette.stripSwitchOff)
                        .frame(
                            width: Theme.Size.paramStripSwitchWidth,
                            height: Theme.Size.paramStripSwitchHeight
                        )
                    Circle()
                        .fill(Color.white)
                        .frame(
                            width: Theme.Size.paramStripSwitchKnob,
                            height: Theme.Size.paramStripSwitchKnob
                        )
                        .padding(.horizontal, 2)
                }
                .frame(
                    width: Theme.Size.paramStripSwitchWidth,
                    height: Theme.Size.paramStripSwitchHeight
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kind.displayName) 自动 / 手动开关")
            .accessibilityValue(isAuto ? "自动" : "手动")

            // 标签恒为「自动」、**不跟开关变色**（原型 `.sp-auto .t` 的注释）
            Text("自动")
                .font(.system(size: Theme.Size.paramStripSwitchLabelFontSize))
                .foregroundStyle(Theme.Palette.secondaryText)
        }
        .frame(width: Theme.Size.paramStripSwitchGutter, alignment: .top)
        .padding(.top, Theme.Size.paramStripSwitchTopInset)
    }

    // MARK: - 位置计算

    /// 当前档位下标（按**显示值**取最近档 —— 设备回读值不会正好落在档位上）
    private var currentStepIndex: Int {
        guard let value = displayValue, !steps.isEmpty else { return 0 }
        return steps.indices.min {
            abs(steps[$0].value - value) < abs(steps[$1].value - value)
        } ?? 0
    }

    /// 刻度条实际渲染用的 translateX：拖动中跟手，否则按显示值定位
    private func renderedOffset(geometry: ParameterStripGeometry) -> CGFloat {
        dragOffset ?? geometry.offset(forStep: currentStepIndex)
    }

    // MARK: - 拖动

    private func dragGesture(geometry: ParameterStripGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                // 自动态禁止滑动（原型 `if (stripIsAuto) return`）
                guard !isAuto, !steps.isEmpty else { return }

                // 方向闸门（与 `ParameterSlider` 同一套）：先判主轴，横向为主才接管。
                // 判出来之前**什么都不做** —— 否则竖向滑动会被读成"手指 x 处的值"。
                if isHorizontalDrag == nil {
                    let dx = abs(gesture.translation.width)
                    let dy = abs(gesture.translation.height)
                    if dx < Theme.Size.paramStripDirectionDeadZone
                        && dy < Theme.Size.paramStripDirectionDeadZone { return }
                    isHorizontalDrag = dx > dy
                }
                guard isHorizontalDrag == true else { return }

                if dragOffset == nil {
                    // 起手：从"当前档位"开始跟手，并记住起始下标（滞后判定以此为基准）
                    dragStartOffset = geometry.offset(forStep: currentStepIndex)
                    dragOffset = dragStartOffset
                    lastReportedIndex = currentStepIndex
                }

                let range = geometry.offsetRange
                let raw = dragStartOffset + gesture.translation.width
                dragOffset = min(max(raw, range.lowerBound), range.upperBound)

                // 跨档判定（带滞后）：离"上次上报的档"不足 0.75 档就不换 —— 边界不连响
                let position = geometry.stepPosition(forOffset: dragOffset ?? 0)
                if let last = lastReportedIndex,
                   abs(position - Double(last)) < Self.hysteresisRatio {
                    return
                }
                let index = min(max(Int(position.rounded()), 0), steps.count - 1)
                lastReportedIndex = index
                onValueChanged(steps[index].value, true)
                fireTickThrottled()
            }
            .onEnded { _ in
                // 被方向闸门判为竖向的那次拖动：整个生命周期都不碰值，也不发编辑事件
                defer {
                    isHorizontalDrag = nil
                    dragOffset = nil
                    lastReportedIndex = nil
                }
                guard isHorizontalDrag == true, !steps.isEmpty else { return }
                let offset = dragOffset ?? geometry.offset(forStep: currentStepIndex)
                let index = geometry.snappedIndex(forOffset: offset)
                onValueChanged(steps[index].value, false)   // 松手**吸附**到最近档
                fireTickThrottled()
            }
    }

    /// 带节流的跨档触感（量级见 `tickThrottle`）
    private func fireTickThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= Self.tickThrottle else { return }
        lastTickAt = now
        Haptics.tick()
    }
}

/// 朝下的实心三角（指针头）。
///
/// 用 `Path` 画而不是 `Image(systemName:)` —— 本项目踩过"SF Symbol 名写错**静默留白**"的坑
/// （编译器和自检都拦不住），指针这种小图形自己画最稳。
private struct DownTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
