import SwiftUI

/// 底部图标行（常驻 · 浮层）：前置 / 对焦 / 白平衡 / 感光 / 快门速度 / 曝光补偿 / 设置。
///
/// 版式对齐网页原型 `.params-closed-bar`（44px 高）+ `.icon-item`
/// （**纵向**：图标在上、中文小字在下；七项**等宽**均分一行）。
///
/// ⚠️ **「快门速度」用的是 `camera.aperture`（光圈叶片）** —— 语义上是有意借用，不是用错：
/// 符号库里**没有**独立的"快门"图形（`aperture` 不存在，Mac 侧 2026-09-17 实测确认）。
/// 快门与光圈同为"叶片开合"机构，参考图与原型用的就是这张图形；
/// 大众语境里它读作"快门/拍摄"，专业用户才可能读成"光圈" —— 而这一格**有"快门速度"
/// 文字标签兜底**，歧义无害。若将来要零歧义，备选方案是照「感光」的做法改文字字形
/// （如「1/125」，单元宽 51pt 装得下）。
///
/// ## 七项的行为边界（2026-09-17 · 全部有反馈，不允许"点了没反应"）
///
/// | 项 | 本件的行为 | 备注 |
/// |---|---|---|
/// | 前置 | toast | 前后切换要**重建会话输入**（换 `AVCaptureDeviceInput`），P2 硬件批次 |
/// | 对焦 | toast | 对焦**本身已可用**（点取景器任意位置）；手动对焦圆盘是模块 #8 |
/// | 白平衡 | toast | 刻度条是模块 #9（走 `setWhiteBalanceModeLocked`） |
/// | 感光 | toast | 同上（走 `setExposureModeCustom`）；字形就是「ISO」字样，不用符号 |
/// | 快门速度 | toast | 同上 |
/// | 曝光补偿 | toast | **EV 已可用**（上方参数排），所以这一项说"去哪调 + 当前值"，不是"未实现" |
/// | 设置 | **真开设置页** | 与顶栏齿轮进的是同一个 `SettingsSheet` |
///
/// ## 布局账（这一条没有顶栏那种预算压力）
///
/// 七项等宽均分：`(370 − 2×6) / 7 ≈ 51.1pt` —— **本身就 ≥ HIG 的 44pt 下限**，
/// 高度 44 也是整行给的。所以这里**不需要**顶栏那套"溢出借空位"的技巧，
/// 命中区就是完整的一格。
///
/// 标签字号 8.5 → **10.5**（与焦段条同一个理由）；最长四字标签「快门速度」
/// 在 10.5pt 下约 42pt ≤ 51.1pt，放得下。
struct ToolIconRow: View {

    let onFrontCamera: () -> Void
    let onFocusHint: () -> Void
    let onWhiteBalance: () -> Void
    let onISO: () -> Void
    let onShutterSpeed: () -> Void
    let onExposureCompensation: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            cell(symbol: "arrow.triangle.2.circlepath.camera",
                 label: "前置", action: onFrontCamera)
            cell(symbol: "dot.scope",
                 label: "对焦", action: onFocusHint)
            cell(symbol: "thermometer.sun",
                 label: "白平衡", action: onWhiteBalance)
            cell(glyphText: "ISO",
                 label: "感光", action: onISO)
            // ⚠️ 这里不能用 "aperture"：符号库里没有这个名字（只有 camera.aperture，2020）。
            // SwiftUI 对无效 symbol 名**不报错、只留白**——编译器和 CI 都拦不住，
            // 只能靠真机肉眼或符号库索引核对（2026-09-17 真机实测第 5 格空白）。
            cell(symbol: "camera.aperture",
                 label: "快门速度", action: onShutterSpeed)
            cell(symbol: "plus.circle",
                 label: "曝光补偿", isAccent: true, action: onExposureCompensation)
            cell(symbol: "gearshape",
                 label: "设置", action: onSettings)
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .frame(height: Theme.Size.toolRowHeight)
    }

    // MARK: - 单元

    /// 一格 = 图标（或文字字形）+ 中文小字，纵向排列，等宽均分。
    ///
    /// 颜色分两层：图标/字形用 `toolRowText`（白 90%），标签用 `toolRowLabel`（白 60%）
    /// —— 原型就是这样把"图形"和"说明"拉开一档对比度的。
    /// 「曝光补偿」是例外：整格用 accent（原型 `.icon-item.accent`），
    /// 因为它是七项里**当前真正可用**的参数入口，要一眼能认出来。
    private func cell(
        symbol: String? = nil,
        glyphText: String? = nil,
        label: String,
        isAccent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Size.toolRowInnerSpacing) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Theme.Size.toolRowGlyphSize, weight: .medium))
                        .foregroundStyle(isAccent ? Theme.Palette.accent : Theme.Palette.toolRowText)
                }
                if let glyphText {
                    Text(glyphText)
                        .font(.system(
                            size: Theme.Size.toolRowGlyphTextSize,
                            weight: .bold,
                            design: .rounded
                        ))
                        .kerning(0.4)
                        .foregroundStyle(isAccent ? Theme.Palette.accent : Theme.Palette.toolRowText)
                }
                Text(label)
                    .font(.system(size: Theme.Size.toolRowLabelSize))
                    .foregroundStyle(
                        isAccent ? Theme.Palette.accent.opacity(0.85) : Theme.Palette.toolRowLabel
                    )
            }
            // 等宽均分（原型 `flex:1 1 0`）+ 整行高度做命中区 → 每格 ≈51×44，超过 HIG 下限
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Size.toolRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
