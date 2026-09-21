import SwiftUI

/// 参数刻度条几何 —— **纯算术**，自检第 12 组照着这几个式子复算，别在别处再写一遍。
///
/// 原型对应：`.strip-panel` / `.sp-clip{ right:64px }` /
/// `.sp-pointer{ left: calc((100% − 64px) / 2) }` / `SP.pad = 30` / `SP.slot`。
///
/// ⚠️ 批六（复刻飓风）后 `slot` **三条统一 40pt**（见 `ParameterStripCatalog.slot`），
/// 但几何式子本身没变：档距只是个参数，`pointerX` 仍是可视区中点。
struct ParameterStripGeometry {

    let containerWidth: CGFloat
    let stepCount: Int
    let slot: CGFloat
    let padding: CGFloat
    let gutter: CGFloat

    /// 可视区宽（右侧让给开关）
    var visibleWidth: CGFloat { max(0, containerWidth - gutter) }

    /// 指针 X —— **固定在可视区中点**（原型 `left: calc((100% − 64px) / 2)`）
    ///
    /// 批六起它只有一个用途：**气泡的落点**（指针三角与竖线已退场），
    /// 以及"当前档位被拖到哪"的基准 —— 选中刻度会被拖到这个 X 上。
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
/// ## 版式（**2026-09-21 批六：复刻飓风** = 方案 A，用户拍板）
///
/// ```
/// ├───────────────── 面板高 84 ──────────────────┼── 64 ──┤
/// │         气泡（绿底黑字，钉在选中刻度上方）22       │ 开关 47×29 │
/// │                          ↓ 选中刻度 22pt 绿     │  「自动」   │
/// │   普通刻度 14pt / 1.33pt   │  （对齐同一条基线）    │           │
/// │   ─────┼───┼───┼───┼───┼───┼───                 │           │
/// │   ↑ 刻度底 ↔ 标签顶 **13pt**                     │           │
/// │   800   1000  1250  1600  2000  2500   数字 10.5 │           │
/// └────────────────────────────────────────────────┴───────────┘
/// ```
///
/// 竖向账（读令牌复算，自检第 19 组守）：气泡 0–22 / 开关 10–39 /
/// **选中刻度 36.5–58.5**（普通刻度 44.5–58.5）/ 数字 71.5–82 —— 互不重叠。
///
/// ## 与旧口径的差异（批六 · 全部来自用户给的飓风实测对照表）
///
/// | 项 | 旧 | 现在 |
/// |---|---|---|
/// | 档距 | ISO 46 / 快门 56 / WB 26 | **统一 40**（飓风 120px） |
/// | 刻度 | 五档层级（hair/minor/mid/major/preset） | **单档 14pt / 1.33pt，每档同高** |
/// | 当前档指示 | 三角指针 12×8 + 竖线 1.5 | **选中刻度 22pt + 加宽 2pt + 绿** |
/// | 档间细刻度 | 三条都加（批五 `hair`） | **删**（飓风 细:主 = 1:1） |
/// | 标签 | 只有 `labelAt` 的档出数字 | **每档都出**（选中档**不放大**） |
///
/// ## 三个**刻意保留**的偏差（都不在飓风对照表里，属本仓既有取舍）
///
/// 1. **面板高 84**（原型 96）：净可见账卡出来的上限，见 `Theme.Size.paramStripHeight`
/// 2. **触觉节流 0.15s**：沿用 `ParameterSlider` 已验证的量级（白平衡 76 档不加节流会"连响"）
/// 3. **气泡 / 开关 `allowsHitTesting` 语义不变**：拖动必须落到刻度区
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
    /// 手动开关在当前设备上是否可用（`false` = 开关**置灰**；仍可点，点了给原因 ——
    /// 虚拟多摄不支持手动参数，2026-09-19 白平衡 7 连崩后的诚实边界，见 `docs/18`）
    let isManualAvailable: Bool
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

    // ⚠️ 换档"0.75 档滞后"已于 2026-09-20 删除（Mac 复验实锤"回弹一档"）：滞后判上报、
    //    松手按 round 吸附，两个口径不同源 → 停在 0.3~0.74 档时气泡与吸附值差一档。
    //    现为**同源 round**（变化即上报 + 0.15s 节流防连响），见 onChanged 的跨档判定。
    /// **触觉节流**：0.15s（与 `ParameterSlider` 一致；自检第 12 组守这个量级）
    private static let tickThrottle: TimeInterval = 0.15

    /// **跟手倍率**（2026-09-20 Mac 复验 🟠问题 3，用户拍板 1.5:1；安全边界 ≤2:1）。
    ///
    /// ⚠️ **方向**（批四修正）：这一版是**乘**不是除 ——
    /// 「提高跟手倍率」= 指尖 1pt → 盘面走 1.5pt（走一档只需指尖移动 1/1.5 个档距）。
    /// 批三那版写成 `translation.width / dragGain`，等于指尖要拖 1.5 个档距才走一档
    /// —— **比改前更钝**（Mac 实锤 B：证据是"同一个值重复推 5 次"，指向不灵敏，
    /// 不是注释里误读的"太灵敏"）。
    private static let dragGain: Double = 1.5

    // MARK: - 几何（从令牌推导，不在视图里写死数字）

    /// 刻度**基线**（刻度底）的 y —— 由「标签底距 + 标签字高 + 13pt 间距」反推（读 Theme，不手填）
    private var tickBaselineY: CGFloat {
        Theme.Size.paramStripHeight - Theme.Size.paramStripTickBaselineFromBottom
    }

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
                bubble(geometry: geometry)
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
            // ⚠️ 批六：**档间细分线整层退场**（飓风 细:主 = 1:1 ⇒ 就是没有细刻度）。
            //    批五那层 `hair`（相邻档位中点一条）连同它的 `hasSubTicks` 判据一起删掉 ——
            //    依据是用户 2026-09-21 的勘误：旧参考图（contact sheet）的"9~10 条细刻度"
            //    是**错判**的产物，已作废。
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

    /// 单个档位的内容：刻度线 + 数字。都用 `.position` 定位在刻度条坐标系里。
    ///
    /// **批六口径**：刻度线**每档同高**（`paramStripTickHeight` 14pt / 1.33pt 宽），
    /// **选中档**加高到 22pt（向上 +8pt）、加宽 2pt、变绿 —— 它同时就是"当前值指示器"。
    /// 底边全部对齐同一条基线（`tickBaselineY`），所以"加高"表现为**向上长**。
    ///
    /// ⚠️ 选中判据用的是 `currentStepIndex`（按显示值吸附到最近档），与气泡**同源**
    /// —— 硬件回读值（如 ISO 934）不落在档位上时，选中刻度与气泡必须指向同一档。
    @ViewBuilder
    private func tickContent(at index: Int, geometry: ParameterStripGeometry) -> some View {
        let step = steps[index]
        let x = geometry.padding + CGFloat(index) * geometry.slot
        let isUnavailable = unavailableValues.contains(step.value)
        let isSelected = index == currentStepIndex
        let tickHeight = isSelected
            ? Theme.Size.paramStripTickSelectedHeight
            : Theme.Size.paramStripTickHeight
        let tickWidth = isSelected
            ? Theme.Size.paramStripTickWidth + Theme.Size.paramStripTickSelectedExtraWidth
            : Theme.Size.paramStripTickWidth

        RoundedRectangle(cornerRadius: tickWidth / 2, style: .continuous)
            .fill(tickFill(isSelected: isSelected, isPreset: step.isPreset, isUnavailable: isUnavailable))
            .frame(width: tickWidth, height: tickHeight)
            .position(x: x, y: tickBaselineY - tickHeight / 2)

        // 数字挂在**每一档**上（飓风口径：每档带标签）；选中档的标签**不放大、不变色**。
        if step.showsLabel {
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

    /// 刻度线颜色：自动态 / 不可用档压暗 → **选中档（绿）** → 白平衡预设档（琥珀）→ 普通。
    ///
    /// ⚠️ 顺序有讲究：**自动态 / 不可用档优先**（整条压暗是"当前不可调"的统一表达），
    /// 否则自动态下还会冒出一根绿线 / 几根琥珀线，与"整条不可调"矛盾。
    /// 选中档**排在预设档之前**：选中刻度按飓风口径必须是绿的（选中优先于预设）。
    private func tickFill(isSelected: Bool, isPreset: Bool, isUnavailable: Bool) -> Color {
        if isAuto || isUnavailable { return Theme.Palette.stripInactive }
        if isSelected { return Theme.Palette.stripTickSelected }
        if isPreset { return Theme.Palette.stripTickPreset }
        return Theme.Palette.stripTick
    }

    private func numberColor(isUnavailable: Bool) -> Color {
        (isAuto || isUnavailable) ? Theme.Palette.stripInactive : Theme.Palette.stripNumber
    }

    // MARK: - 气泡（固定在可视区中点，且不接收触摸）

    /// 气泡：唯一保留的"当前值"指示（批六：三角指针 + 竖线已退场，选中刻度承担指示）。
    ///
    /// 它落在 `pointerX`（可视区中点）上，而刻度条会把**当前档位**偏移到同一个 X
    /// —— 所以气泡永远正在选中刻度正上方。
    private func bubble(geometry: ParameterStripGeometry) -> some View {
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
            // 原型 `.sp-pointer{ pointer-events:none }` —— 拖动要落到刻度区，气泡不许抢触摸
            .allowsHitTesting(false)
    }

    /// 气泡文本：自动态显示「自动」，否则显示当前档位（原型 `fmt`）。
    ///
    /// ⚠️ **与选中刻度同源**（2026-09-20 Mac 复验 🟠问题 2）：显示值吸附到**最近档**
    /// （`steps[currentStepIndex].value`）—— 硬件回读值（如 ISO 934）不落在档位上时，
    /// 气泡若显示原始值就与选中刻度对不上。拖动期草稿值同理吸附。
    private var bubbleText: String {
        guard !isAuto, displayValue != nil else { return "自动" }
        return ParameterStripCatalog.label(for: kind, value: steps[currentStepIndex].value)
    }

    // MARK: - 右端自动 / 手动开关

    private var autoSwitch: some View {
        VStack(spacing: 6) {
            Button {
                onToggleAuto()
            } label: {
                // 手动不可用 → 开关整体压灰（仍可点，点了由 VM 给 toast 说明原因）
                let switchOn = isAuto && isManualAvailable
                let switchOff = !isAuto && isManualAvailable
                ZStack(alignment: isAuto ? .trailing : .leading) {
                    Capsule()
                        .fill(
                            switchOn
                                ? Theme.Palette.stripAccent
                                : (switchOff ? Theme.Palette.stripSwitchOff : Theme.Palette.stripInactive)
                        )
                        .frame(
                            width: Theme.Size.paramStripSwitchWidth,
                            height: Theme.Size.paramStripSwitchHeight
                        )
                    Circle()
                        .fill(Color.white.opacity(isManualAvailable ? 1 : 0.75))
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
                    // 起手：从"当前档位"开始跟手，并记住起始下标（上报判定以此为基准）
                    dragStartOffset = geometry.offset(forStep: currentStepIndex)
                    dragOffset = dragStartOffset
                    lastReportedIndex = currentStepIndex
                }

                let range = geometry.offsetRange
                // 跟手倍率（2026-09-20 批四修正方向：**乘**，用户拍板 1.5:1，安全边界 ≤2:1）：
                // 指尖移 1pt → 盘面走 1.5pt ⇒ 走一档只需指尖移动 1/1.5 个档距（更跟手）。
                // ⚠️ 批三是 `/ Self.dragGain`（指尖要拖 1.5 个档距才走一档 = 更钝），
                //    那是 Mac 实锤 B 的方向写反，别改回去。
                let raw = dragStartOffset + gesture.translation.width * Self.dragGain
                dragOffset = min(max(raw, range.lowerBound), range.upperBound)

                // 跨档判定（**与松手吸附同源**：都用 `round(position)`，2026-09-20 修"回弹一档"）：
                // 旧实现用 0.75 档滞后判上报、松手却按 round 吸附 —— 两个口径不同源，
                // 停在 0.3~0.74 档时气泡显示旧值、松手吸附到相邻档（实锤：ISO 800 拖到松手变 640）。
                // 现在"变化即上报"（每跨一档立即上报 + `tickThrottle` 0.15s 防连响），
                // 上报值与松手吸附值**永远一致**。
                let position = geometry.stepPosition(forOffset: dragOffset ?? 0)
                let index = min(max(Int(position.rounded()), 0), steps.count - 1)
                if index == lastReportedIndex {
                    return
                }
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
