import SwiftUI

/// 曝光控制面板（参数排展开态 · 只有 EV 一条）。
///
/// ## 2026-09-19（B2b）三处改动
///
/// 1. **删掉那句过时的说明**：原写「ISO / 快门 / 白平衡 手动控制将在 P2 加入」——
///    B2 交付后它就是假话。删掉后面板高从 ~108pt 降到 **~72pt**
///    （= 标题行 26 + 间距 6 + 轨道 20 + 上下内边距 20），正好落在净可见账里
///    （`docs/16` 第三.2 节按 72 复算过三机型）。
/// 2. **手动曝光档下整块禁用 + 说明**：EV 与手动档互斥（见下）。
/// 3. 手动档的说明文字**只在手动档出现** —— 它是操作指引，不是占位说明。
///
/// ## 关于 EV 的一个关键事实（`docs/16` 第五节）
///
/// `setExposureTargetBias` **只在自动曝光档生效**。一旦切到 `setExposureModeCustom`
/// （手动 ISO + 快门），EV 会被系统忽略 —— 更糟的是 `CaptureDeviceConfigurator.applyExposureBias`
/// 里那条"顺手回切自动档"的防线会把手动锁定**静默解除**。
/// 所以三层拦：**① 本面板禁用 + 说明**（这里）；② VM 里 `exposureEditingChanged` 的守卫；
/// ③ configurator 的回切保留为最后防线但**打 warn 留痕**。
struct ExposurePanel: View {

    @Binding var exposureBias: Double
    let range: ClosedRange<Float>
    let isEnabled: Bool
    /// 是否处于**手动曝光档**（ISO / 快门 被锁）。默认 `false` → 老调用点不受影响。
    var isManualExposureActive: Bool = false
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
                isEnabled: isEnabled && !isManualExposureActive,
                valueFormatter: { String(format: "%+.1f EV", $0) },
                onEditingChanged: onEditingChanged
            )

            if isManualExposureActive {
                // 只解释"为什么现在调不了" —— 不做"点了没反应"。
                // ⚠️ **必须短到一行**（≤ 20 字）：这句话每多一行，面板就高 12pt，
                // 而 844 机型的净可见余量只有 0.8pp（`docs/16` 第三.2 节的账）。
                // 自检第 12 组⑩ 会核这段文案的长度；"怎么切回来"由 toast 说（更长，不占版面）。
                Text("手动 ISO / 快门 档下不可调")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.panel.opacity(0.78))
        )
    }
}
