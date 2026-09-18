import SwiftUI

/// 参数滑块。
///
/// 相机页的曝光补偿、以及 P2 的 ISO / 快门 / 白平衡全部复用这一个控件，
/// 所以它必须处理好四件事：
///   1. **吸附**：EV 按 1/3 档，ISO 按整档，不能让 0.30000000000000004 这种值进硬件；
///   2. **归位**：点一下数值就回到默认值（比双击更可靠，也不容易误触）；
///   3. **居中填充**：范围是 -2…+2 时，填充条应该从中间的 0 往两边长，
///      而不是从最左边开始——不然用户看不出当前是加还是减；
///   4. **方向闸门**：只接**横向**拖动。这条是 2026-09-18 按真机反馈补的 ——
///      原来用 `DragGesture(minimumDistance: 0)`，任何落手（包括想上滑呼出浮层的竖向滑动）
///      都会被滑条接管，EV 会**跳到手指 x 处对应的值**并写进硬件。
///      用户的体感就是"曝光补偿条一直在干扰，想上滑却改了 EV"。
///      现在的行为：落手后先判方向，竖向为主（含斜向但不是横向为主）一律不接管、不改值。
struct ParameterSlider: View {

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    var isCentered: Bool = false
    var isEnabled: Bool = true
    var valueFormatter: (Double) -> String = { String(format: "%.1f", $0) }
    var onEditingChanged: ((Bool) -> Void)?

    private let trackHeight: CGFloat = 4
    private let thumbDiameter: CGFloat = 20

    /// 本次拖动是否已被判定为"横向接管"。nil = 还没判出来（见 `dragGesture`）。
    @State private var isHorizontalDrag: Bool?

    /// 上次"跨档"触觉的时刻（节流用，见 `fireTickThrottled()`）
    @State private var lastTickAt: Date = .distantPast

    /// 判定死区：位移不超过它时不判方向（避免手抖就把一次点按判成拖动）
    private static let directionDeadZone: CGFloat = 6

    /// **换档滞后**：手指要从当前档位挪开**超过 step 的这个比例**，才换到下一档。
    ///
    /// 为什么必须有它（2026-09-18 真机反馈"拉到部分数值时一直触发咔"）：
    /// 档位边界是**一个点** —— 手指停在那附近时，亚像素抖动会让
    /// `roundedToStep` 在相邻两档之间反复翻转，于是"值变了 → 响一下"每帧成立，触觉连响。
    /// 滞后把边界变成**一段过渡带**，停在边界上不再是"来回换档"。
    ///
    /// **0.6 → 0.75（2026-09-18 真机复验）**：0.6 那版的过渡带只有 0.2 档宽，抖动余量不够。
    /// 0.75 之后边界周围有成档的"不回弹区"，抗抖更强。手感代价：从静止档位起手时
    /// 要让值变化需要移动 0.75 档（28.8pt × 0.75 ≈ 21.6pt）而不是 0.6 档 —— 略"粘"，
    /// 但换来边界绝对稳定（复验口径要求：停在两档之间不响）。
    private static let hysteresisRatio: Double = 0.75

    /// **触觉节流**：两次"跨档"触感之间的最小间隔。
    ///
    /// ⚠️ **0.055 → 0.15（2026-09-18 真机复验）**：55ms 那版**形同虚设** ——
    /// 匀速拖动 100pt/s 时每档 28.8pt / 每档 288ms 跨一次，55ms 的窗口根本拦不住，
    /// 快扫时约 17 声/秒（连成一片）。
    ///
    /// 0.15s 的账：**快扫**最多 6.7 声/秒（一段快扫通常 2~3 声）；
    /// **慢拖**每档间隔通常 >0.15s → **照响，零精度损失**（棘轮手感保留）。
    ///
    /// 教训：触觉节流的量级必须与"每档耗时"同量级才有意义 ——
    /// 短于 1/4 档耗时的节流等于没做。
    private static let tickThrottle: TimeInterval = 0.15

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.secondaryText)

                Spacer(minLength: Theme.Spacing.xs)

                Button {
                    resetToDefault()
                } label: {
                    Text(valueFormatter(value))
                        .font(Theme.Typography.value)
                        .foregroundStyle(isEnabled ? Theme.Palette.accent : Theme.Palette.tertiaryText)
                        .monospacedDigit()
                        // 数值本身的点击区域太小，撑一下更跟手
                        .frame(minWidth: 56, minHeight: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                let thumbCenter = thumbCenterX(width: width)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Palette.panelElevated)
                        .frame(height: trackHeight)

                    if isCentered {
                        // 中间的 0 刻度线，给用户一个参照
                        Rectangle()
                            .fill(Theme.Palette.stroke)
                            .frame(width: 1, height: 10)
                            .offset(x: width / 2 - 0.5)
                    }

                    Capsule()
                        .fill(Theme.Palette.accent.opacity(isEnabled ? 1.0 : 0.3))
                        .frame(width: max(0, fillWidth(width: width, thumbCenter: thumbCenter)), height: trackHeight)
                        .offset(x: fillOffset(width: width, thumbCenter: thumbCenter))

                    Circle()
                        .fill(isEnabled ? Theme.Palette.primaryText : Theme.Palette.tertiaryText)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .offset(x: thumbCenter - thumbDiameter / 2)
                }
                .frame(height: thumbDiameter)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { resetToDefault() }
                )
            }
            .frame(height: thumbDiameter)
            .opacity(isEnabled ? 1.0 : 0.55)
        }
    }

    // MARK: - 计算

    private func normalized(_ raw: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((raw - range.lowerBound) / span).clamped(to: 0...1)
    }

    /// 拇指中心 X —— **唯一的渲染源是 `value`**（填充条与数字同样派生自它）。
    ///
    /// ⚠️ **不要改成跟随 `gesture.location.x`**（2026-09-18 排查"EV 条反复跳动"时讨论过）：
    /// 那会制造**真正的**不同步 —— thumb 跟手指（连续）而填充/数字跟 `value`（吸附后离散），
    /// 两者必然错位。
    /// 而且当时的跳动**真因不是渲染源**：是 `value` 被硬件回写擅自改写（环路，见 `docs/14`）。
    /// 三者同源是本控件的既定不变量，自检第 8 组 l) 条守着它。
    private func thumbCenterX(width: CGFloat) -> CGFloat {
        let travel = max(0, width - thumbDiameter)
        return thumbDiameter / 2 + CGFloat(normalized(value)) * travel
    }

    private func fillWidth(width: CGFloat, thumbCenter: CGFloat) -> CGFloat {
        if isCentered {
            return abs(thumbCenter - width / 2)
        }
        return thumbCenter
    }

    private func fillOffset(width: CGFloat, thumbCenter: CGFloat) -> CGFloat {
        if isCentered {
            return min(thumbCenter, width / 2)
        }
        return 0
    }

    // MARK: - 交互

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled, width > 0 else { return }

                // 方向闸门（见类型注释第 4 条）：先判方向，横向为主才接管。
                // 判不出来之前**不改值** —— 否则竖向滑动会被读成"手指 x 处的值"。
                if isHorizontalDrag == nil {
                    let dx = abs(gesture.translation.width)
                    let dy = abs(gesture.translation.height)
                    if dx < Self.directionDeadZone && dy < Self.directionDeadZone { return }
                    isHorizontalDrag = dx > dy
                }
                guard isHorizontalDrag == true else { return }

                // ⚠️ 编辑态**先上报**：它同时是 `CameraView` 整页手势的闸门
                //（`isExposureEditing`）。放在"是否换档"判定之前 ——
                // 否则手指小幅移动（未跨档）时闸门不生效，横拖仍可能被整页手势误判。
                onEditingChanged?(true)

                let x = gesture.location.x.clamped(to: 0...width)
                let travel = max(1, width - thumbDiameter)
                let ratio = Double((x - thumbDiameter / 2) / travel).clamped(to: 0...1)
                let raw = range.lowerBound + ratio * (range.upperBound - range.lowerBound)

                // 滞后换档（见 `hysteresisRatio`）：离当前档位不够远就不换。
                // 这里比的是**连续索引**，不是吸附后的相等 —— 后者正是
                // "边界抖动导致触觉连响"的来源。
                let rawIndex = (raw - range.lowerBound) / step
                let currentIndex = (value - range.lowerBound) / step
                guard abs(rawIndex - currentIndex) >= Self.hysteresisRatio else { return }

                // 吸附 + 钳制：任何值进硬件参数前都要过这一关
                let snapped = raw.sanitizedClamped(to: range, step: step)

                if snapped != value {
                    value = snapped
                    fireTickThrottled()
                }
            }
            .onEnded { _ in
                // 被方向闸门判为竖向的那次拖动：整个生命周期都不碰值，也不发编辑事件。
                // ⚠️ 这里**不需要**"无条件复位编辑态"：`isHorizontalDrag` 在同一次拖动里
                // 只会从 nil 判定一次，所以"发过 `true` 就一定走到这里的 `false`"，
                // 不可能出现"闸门卡在拖动中导致整页手势永久禁言"。
                // （那个闸门是 `CameraViewModel.isExposureEditing`，见其注释。）
                defer { isHorizontalDrag = nil }
                guard isHorizontalDrag == true else { return }
                onEditingChanged?(false)
                fireTickThrottled()
            }
    }

    /// 带节流的跨档触感（见 `tickThrottle`）
    private func fireTickThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= Self.tickThrottle else { return }
        lastTickAt = now
        Haptics.tick()
    }

    private func resetToDefault() {
        guard isEnabled else { return }
        guard value != defaultValue else { return }
        value = defaultValue
        Haptics.tick()
    }
}
