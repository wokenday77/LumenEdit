import SwiftUI

/// 焦段条（常驻 · 浮层）：13 / 24 / 48 / 120mm 四个药丸。
///
/// 版式对齐网页原型 `.row-focal`（44px 高）+ `.focal-pill`（44×30 圆角块：
/// 刻度标记 + 「13 mm」；**选中转白底黑字**）。
///
/// ## B1 已接线（2026-09-18）
///
/// 点击 = 换选中态 + **真推硬件**：按档位换算 `videoZoomFactor`，
/// 再走 `AVCaptureDevice.ramp` 平滑过去（`CaptureDeviceConfigurator.applyZoomRamp`）。
/// **不重建会话** —— 切镜头是虚拟多摄设备内部的事（越过系统切换点时自动换 constituent）。
///
/// 不可用档位（`unavailableIds`）**置灰但仍可点**：点了由 VM 给 toast 说明原因
/// （产品约束是"不做点了没反应"，所以宁可灰 + 可点 + 有解释，也不做灰 + 禁用）。
///
/// ## 与原型的两处刻意偏差（都有理由，不是随手改的）
///
/// 1. **标签字号 8.5 → 10.5**：原型那 8.5px 是在 390px 宽的 CSS 稿上定的，真机偏小
///    —— 与模式条 11.5 → 13 同一个理由。
///
///    ⚠️ **但这不是"零几何代价"，内宽余量只剩 2pt。** 药丸内宽 44pt，
///    真机实测的标签墨迹宽（Mac 侧 · iPhone 16 Pro）：
///
///    | 标签 | 「13 mm」 | 「24 mm」 | 「48 mm」 | **「120 mm」** |
///    |---|---|---|---|---|
///    | 墨迹宽 | 33.0pt | 38.3pt | 34.7pt | **40.0pt** |
///
///    → 最长那一档两侧各只剩约 **2pt**（内宽用到 **91%**）。
///    **字号上探之前必须先加宽药丸**：按同一比例，11.5pt 时「120 mm」≈ 43.8pt 就贴边了。
///    （这里最初写的是"约 32pt" —— 按 0.55em/字符粗估来的，比实测窄 25%。
///      纯拉丁/数字串**别估**，宽度模型见 `docs/08` 三.2。）
/// 2. **触控热区 44×44**：药丸视觉仍是原型的 44×30，热区上下各借 7pt。
///    焦段条本身就是 44pt 高，那 7pt 是**条内空白**，不侵占任何其它控件
///    （和顶栏模式条不同：那边要靠溢出到相邻行才凑得够，这边不用）。
///
/// 药丸宽度 44pt 本身已满足 HIG 的横向下限；四个药丸 + 三个 9pt 间距 = 203pt，
/// 远小于可用宽 370pt，所以这一条**不存在顶栏那种宽度预算问题**。
struct FocalStripView: View {

    let selection: FocalPreset
    /// 当前设备上**不可用**的档位 id（B1 接线后由 `session.unavailableFocalIds` 给出）。
    /// 默认空集合 → 老调用点不受影响。
    var unavailableIds: Set<String> = []
    let onTap: (FocalPreset) -> Void

    /// 刻度标记的高度序列（"波形"图案），逐项对齐原型 `FOCAL_MARK = [4,6,5,7,4,6,5]`。
    /// 四个档位用的是同一套图案 —— 它是**装饰性刻度**，表示"这是焦段刻度"，
    /// 不表示当前档位（真实档位由选中态的白底表达）。
    private static let markHeights: [CGFloat] = [4, 6, 5, 7, 4, 6, 5]

    var body: some View {
        HStack(spacing: Theme.Size.focalStripSpacing) {
            ForEach(FocalCatalog.all) { preset in
                pill(for: preset)
            }
        }
        .frame(height: Theme.Size.focalStripHeight)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 药丸

    private func pill(for preset: FocalPreset) -> some View {
        let isSelected = preset.id == selection.id
        // 不可用档位（B1）：置灰但**仍可点** —— 点了由 VM 给 toast 说明原因。
        // 产品约束是"不做点了没反应"，所以灰 + 可点 + 有解释，而不是灰 + 禁用。
        let isUnavailable = unavailableIds.contains(preset.id)

        return Button {
            onTap(preset)
        } label: {
            VStack(spacing: Theme.Size.focalPillInnerSpacing) {
                marks
                Text("\(preset.displayName) mm")
                    .font(.system(
                        size: Theme.Size.focalLabelSize,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .kerning(0.2)
                    .fixedSize()
            }
            .foregroundStyle(pillForeground(isSelected: isSelected, isUnavailable: isUnavailable))
            // 视觉尺寸 = 原型的 44×30
            .frame(width: Theme.Size.focalPillWidth, height: Theme.Size.focalPillHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(pillFill(isSelected: isSelected, isUnavailable: isUnavailable))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(
                        pillStroke(isSelected: isSelected, isUnavailable: isUnavailable),
                        lineWidth: 0.5
                    )
            )
            // 不可用档位整体压暗一档（但保持可读：仍要看得出它是哪一档）
            .opacity(isUnavailable ? 0.4 : 1)
            // 命中高度 = 条高 44（药丸视觉仍是 30，上下各 7pt 是条内空白）
            .frame(height: Theme.Size.focalStripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.displayName) 毫米焦段")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 刻度标记：7 根小竖条，底对齐。
    /// 用 `.foreground` 跟随上面的 `foregroundStyle` —— 选中态转白底时它自动变深色，
    /// 不需要为标记单开一套颜色（对应原型的 `background: currentColor`）。
    // MARK: - 药丸配色（选中 × 不可用 两维组合）

    /// 文字色：选中 = 白底上转深色；不可用 = 三级灰（不抢视觉，但仍读得出是哪一档）
    private func pillForeground(isSelected: Bool, isUnavailable: Bool) -> Color {
        if isUnavailable { return Theme.Palette.tertiaryText }
        return isSelected ? Theme.Palette.textOnLight : Theme.Palette.focalPillText
    }

    /// 底：选中 = 白底；**不可用时给中性半透明底**（不能给白底 —— 那看起来像选中了）
    private func pillFill(isSelected: Bool, isUnavailable: Bool) -> Color {
        if isUnavailable { return Theme.Palette.focalPillFill.opacity(0.6) }
        return isSelected ? Color.white : Theme.Palette.focalPillFill
    }

    /// 描边：同上口径
    private func pillStroke(isSelected: Bool, isUnavailable: Bool) -> Color {
        if isUnavailable { return Theme.Palette.focalPillStroke.opacity(0.6) }
        return isSelected ? Color.white : Theme.Palette.focalPillStroke
    }

    private var marks: some View {
        HStack(alignment: .bottom, spacing: Theme.Size.focalMarkBarSpacing) {
            ForEach(Array(Self.markHeights.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(.foreground)
                    .frame(width: Theme.Size.focalMarkBarWidth, height: height)
                    .opacity(0.9)
            }
        }
        .frame(height: Theme.Size.focalMarkHeight)
    }
}
