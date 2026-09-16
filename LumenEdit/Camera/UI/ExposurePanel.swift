import SwiftUI

/// 曝光控制面板。
///
/// P1a 只提供曝光补偿（EV）。ISO / 快门 / 白平衡需要先确定"自动档 / 手动档"的互斥 UI，
/// 那是 P2 的事——这里先给一句说明，不做假控件。
///
/// 关于 EV 的一个关键事实（P2 做手动档时必须处理）：
/// `setExposureTargetBias` 只在**自动曝光**模式下生效。一旦切到 `setExposureModeCustom`
/// （手动 ISO + 快门），EV 会被系统忽略。两者互斥，不能同时可调。
struct ExposurePanel: View {

    @Binding var exposureBias: Double
    let range: ClosedRange<Float>
    let isEnabled: Bool
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ParameterSlider(
                title: "曝光补偿",
                value: $exposureBias,
                range: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(Float.evStep),
                defaultValue: 0,
                isCentered: true,
                isEnabled: isEnabled,
                valueFormatter: { String(format: "%+.1f EV", $0) },
                onEditingChanged: onEditingChanged
            )

            Text("ISO / 快门 / 白平衡 手动控制将在 P2 加入（自动档与手动档互斥，不能同时可调）")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.panel.opacity(0.78))
        )
    }
}
