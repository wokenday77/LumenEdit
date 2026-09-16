import SwiftUI

/// 参数滑块。
///
/// 相机页的曝光补偿、以及 P2 的 ISO / 快门 / 白平衡全部复用这一个控件，
/// 所以它必须处理好三件事：
///   1. **吸附**：EV 按 1/3 档，ISO 按整档，不能让 0.30000000000000004 这种值进硬件；
///   2. **归位**：点一下数值就回到默认值（比双击更可靠，也不容易误触）；
///   3. **居中填充**：范围是 -2…+2 时，填充条应该从中间的 0 往两边长，
///      而不是从最左边开始——不然用户看不出当前是加还是减。
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
                let x = gesture.location.x.clamped(to: 0...width)
                let travel = max(1, width - thumbDiameter)
                let ratio = Double((x - thumbDiameter / 2) / travel).clamped(to: 0...1)
                let raw = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                // 吸附 + 钳制：任何值进硬件参数前都要过这一关
                let snapped = raw.sanitizedClamped(to: range, step: step)

                if snapped != value {
                    value = snapped
                    Haptics.tick()
                }
                onEditingChanged?(true)
            }
            .onEnded { _ in
                onEditingChanged?(false)
                Haptics.tick()
            }
    }

    private func resetToDefault() {
        guard isEnabled else { return }
        guard value != defaultValue else { return }
        value = defaultValue
        Haptics.tick()
    }
}
