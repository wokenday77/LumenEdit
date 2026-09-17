import SwiftUI

/// 焦段条（常驻 · 浮层）：13 / 24 / 48 / 120mm 四个药丸。
///
/// 版式对齐网页原型 `.row-focal`（44px 高）+ `.focal-pill`（44×30 圆角块：
/// 刻度标记 + 「13 mm」；**选中转白底黑字**）。
///
/// ## 本件只做 UI
///
/// 点击只有「换选中态 + 提示条」。真正的**镜头切换与变焦**
/// （`applyZoomLocked` 扩成按档切镜头 + `Ramp` 平滑）属于任务书 B 组接线，
/// 单独一轮做 —— 那要碰 `CaptureSessionController`，而版式可以先靠真机截图验收。
///
/// ## 与原型的两处刻意偏差（都有理由，不是随手改的）
///
/// 1. **标签字号 8.5 → 10.5**：原型那 8.5px 是在 390px 宽的 CSS 稿上定的，真机偏小
///    —— 与模式条 11.5 → 13 同一个理由。药丸内宽 44pt，最长的「120 mm」在 10.5pt 下
///    约 32pt，**放得下**，所以这是**零几何代价**的可读性提升（不像模式条要动宽度预算）。
/// 2. **触控热区 44×44**：药丸视觉仍是原型的 44×30，热区上下各借 7pt。
///    焦段条本身就是 44pt 高，那 7pt 是**条内空白**，不侵占任何其它控件
///    （和顶栏模式条不同：那边要靠溢出到相邻行才凑得够，这边不用）。
///
/// 药丸宽度 44pt 本身已满足 HIG 的横向下限；四个药丸 + 三个 9pt 间距 = 203pt，
/// 远小于可用宽 370pt，所以这一条**不存在顶栏那种宽度预算问题**。
struct FocalStripView: View {

    let selection: FocalPreset
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
            .foregroundStyle(isSelected ? Theme.Palette.textOnLight : Theme.Palette.focalPillText)
            // 视觉尺寸 = 原型的 44×30
            .frame(width: Theme.Size.focalPillWidth, height: Theme.Size.focalPillHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(isSelected ? Color.white : Theme.Palette.focalPillFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(
                        isSelected ? Color.white : Theme.Palette.focalPillStroke,
                        lineWidth: 0.5
                    )
            )
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
