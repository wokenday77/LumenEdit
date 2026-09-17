import SwiftUI

/// L / R 音频电平表（顶栏主行左侧，两个声道各 8 个点）。
///
/// 版式对齐网页原型 `.levels`：每行 = 声道字母（8pt 粗体，宽 5）+ 8 个点
/// （点径 3.5、间距 2）。**已点亮的点是绿色**（原型 `--ok: #34d058`），
/// **紧跟其后的那一个点是琥珀色**（原型 `--accent`）—— 那是电平前沿的"峰值"标注，
/// 原型 `buildLevels()` 的规则就是 `i < lit → on`、`i === lit → hot`。
///
/// ## ⚠️ 真实电平还没接：这里现在显示的是**静息态**（点全灭）
///
/// 真机要拿到实时电平得走 `AVCaptureAudioChannel.averagePowerLevel`（配合
/// `AVCaptureAudioDataOutput`）或 `AVAudioRecorder` 的 metering，属于
/// **硬件接线批次**（任务书 B 组、交接单第七节第 3 步之后的活）。
///
/// 在那之前**不塞假数据**：假跳动会让人以为电平监测已经工作，
/// 真出现"录出来没声音"时反而失去最直接的线索。点全灭 = 诚实的"未接入"。
/// 组件接口把左右电平收在 `0...1`，接上真实数据源时只换数据、不动版式。
struct AudioLevelMeterView: View {

    /// 左声道电平，0...1（1 = 满刻度）
    var leftLevel: Double = 0
    /// 右声道电平，0...1
    var rightLevel: Double = 0

    private static let dotCount = 8
    private static let rowHeight: CGFloat = 5
    private static let channelLabelWidth: CGFloat = 5
    private static let rowSpacing: CGFloat = 2.5

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            channel("L", level: leftLevel)
            channel("R", level: rightLevel)
        }
        // 与右上图标块**等宽**：模式条的盒中心才等于屏幕中心
        //（原型 `.levels{ min-width: var(--tb-side-w) }`）。
        // 点是左对齐的，多出来的宽度是空白，视觉上没有差别。
        .frame(width: Theme.Size.topBarSideWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音频电平表")
        .accessibilityValue(levelAccessibilityValue)
    }

    // MARK: - 单声道

    private func channel(_ name: String, level: Double) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(Theme.Typography.levelChannel)
                .foregroundStyle(Theme.Palette.secondaryText)
                .frame(width: Self.channelLabelWidth, alignment: .leading)

            HStack(spacing: Theme.Size.levelDotSpacing) {
                ForEach(0..<Self.dotCount, id: \.self) { index in
                    Circle()
                        .fill(color(for: index, level: level))
                        .frame(width: Theme.Size.levelDotSide, height: Theme.Size.levelDotSide)
                }
            }
        }
        .frame(height: Self.rowHeight)
    }

    /// 第 `index` 个点（0 = 最低）的颜色。
    /// 规则对齐原型：已点亮的用绿色，**紧接着的那一个**用琥珀色标出前沿。
    private func color(for index: Int, level: Double) -> Color {
        let clamped = min(max(level, 0), 1)
        let litCount = Int((clamped * Double(Self.dotCount)).rounded())
        if index < litCount {
            return Theme.Palette.ok
        }
        if index == litCount, clamped > 0 {
            return Theme.Palette.accent
        }
        return Theme.Palette.primaryText.opacity(0.20)
    }

    private var levelAccessibilityValue: String {
        guard leftLevel > 0 || rightLevel > 0 else { return "尚未接入实时电平" }
        let lit = { (level: Double) -> Int in
            Int((min(max(level, 0), 1) * Double(Self.dotCount)).rounded())
        }
        return "左 \(lit(leftLevel)) 格，右 \(lit(rightLevel)) 格，每声道 \(Self.dotCount) 格"
    }
}
