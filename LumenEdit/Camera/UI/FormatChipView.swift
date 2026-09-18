import SwiftUI

// MARK: - 格式芯片

/// 视频格式芯片（**顶替**右上三图标，只在视频 / Log 实况模式出现）。
///
/// 版式对齐原型 `.fmt-chip`：胶囊高 24、圆角 12、左右内边距 10、12pt 粗体白字；
/// 展开中变亮（`.fmt-chip.on`）。
///
/// ## ⚠️ 必须钉成 `topBarSideWidth`（73pt）宽 —— 这是几何硬约束
///
/// 顶栏模式条"居中"靠的是**左右两侧等宽**（`Theme.Size.topBarSideWidth`），
/// 芯片自己那颗图标位从 3 颗变 1 条胶囊；不钉宽，模式条的盒中心就会漂
/// （「4K · 30」自然宽约 60 → 会漂 12.6pt）。
///
/// 「Log · 4K · 30」自然宽约 91 > 73 → 会把模式条推左约 9.1pt，
/// **这一处原型已确认接受**（见 `CONTEXT_HOT` 第九轮），所以用 `minWidth` 而不是 `width`。
struct FormatChipView: View {

    /// 芯片文案（由 `CameraViewModel.formatChipText` 组装 —— 文案是业务，View 不拼）
    let text: String
    /// 选择器是否展开（展开中芯片变亮）
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(Theme.Typography.formatChip)
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, Theme.Size.formatChipHorizontalPadding)
                .frame(height: Theme.Size.formatChipHeight)
                .background(
                    Capsule().fill(
                        isExpanded ? Theme.Palette.formatChipFillExpanded : Theme.Palette.formatChipFill
                    )
                )
                .overlay(
                    Capsule().stroke(
                        isExpanded
                            ? Theme.Palette.formatChipStrokeExpanded
                            : Theme.Palette.formatChipStroke,
                        lineWidth: 0.5
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // ⚠️ minWidth = 顶栏单侧宽（73）：模式条居中依赖两侧等宽，见类型注释
        .frame(minWidth: Theme.Size.topBarSideWidth)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .accessibilityLabel("视频格式 \(text)")
        .accessibilityHint("点按选择分辨率与帧率")
    }
}

// MARK: - 格式选择器

/// 格式选择器（点芯片从**右上角**弹出）：分辨率 3 项 + 帧率 4 项 + 一行底注。
///
/// 版式对齐原型 `.fmt-menu`：宽 196、圆角 14、内边距 10/10/8、
/// 从右上角放大出现（`scale .94 → 1` + 上移 6pt，180ms）。
struct FormatSelectorView: View {

    let resolution: VideoResolution
    let frameRate: VideoFrameRate
    let onSelectResolution: (VideoResolution) -> Void
    let onSelectFrameRate: (VideoFrameRate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.formatSelectorGroupSpacing) {
            // ⚠️ 元组**必须带标签**：`[(String, Bool)]` 与 `[(label: String, isSelected: Bool)]`
            // 在 Swift 里是两个类型（标签属于类型），map 里漏标签会编译失败
            group(
                title: "分辨率",
                values: VideoResolution.allCases.map {
                    (label: $0.displayName, isSelected: $0 == resolution)
                }
            ) { index in
                onSelectResolution(VideoResolution.allCases[index])
            }

            group(
                title: "帧率",
                values: VideoFrameRate.ordered.map {
                    (label: $0.displayName, isSelected: $0 == frameRate)
                }
            ) { index in
                onSelectFrameRate(VideoFrameRate.ordered[index])
            }

            note
        }
        .padding(.horizontal, Theme.Size.formatSelectorHorizontalPadding)
        .padding(.top, Theme.Size.formatSelectorTopPadding)
        .padding(.bottom, Theme.Size.formatSelectorBottomPadding)
        .frame(width: Theme.Size.formatSelectorWidth)
        .background(
            RoundedRectangle(cornerRadius: Theme.Size.formatSelectorCornerRadius, style: .continuous)
                .fill(Theme.Palette.functionPanelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Size.formatSelectorCornerRadius, style: .continuous)
                .stroke(Theme.Palette.functionPanelStroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 17, x: 0, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视频格式选择")
    }

    /// 一组 = 标题 + 等宽均分的选项行
    private func group(
        title: String,
        values: [(label: String, isSelected: Bool)],
        onTap: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.Typography.formatGroupLabel)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .padding(.horizontal, 2)
                .padding(.bottom, Theme.Size.formatGroupLabelBottomPadding)

            HStack(spacing: Theme.Size.formatOptionSpacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, item in
                    Button {
                        onTap(index)
                    } label: {
                        Text(item.label)
                            .font(Theme.Typography.formatOption)
                            .foregroundStyle(
                                item.isSelected ? Theme.Palette.textOnLight : Theme.Palette.secondaryText
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Size.formatOptionHeight)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: Theme.Size.formatOptionCornerRadius,
                                    style: .continuous
                                )
                                .fill(
                                    item.isSelected ? Theme.Palette.accent : Theme.Palette.formatOptionFill
                                )
                            )
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: Theme.Size.formatOptionCornerRadius,
                                    style: .continuous
                                )
                                .stroke(
                                    item.isSelected ? Theme.Palette.accent : Theme.Palette.stroke,
                                    lineWidth: 0.5
                                )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(item.label)")
                    .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
                }
            }
        }
    }

    /// 底注：**讲清本件的边界**（原型这行写的是"按码率估算（占位表，真机读自 AVCaptureDevice）"；
    /// Swift 侧还要补一句"重设采集格式属 B 组"，因为选了但格式并不会真的切）
    private var note: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.Palette.formatNoteSeparator)
                .frame(height: 0.5)
                .padding(.bottom, Theme.Size.formatNoteTopPadding)

            Text("剩余时长按码率估算 · 重设采集格式属 B 组")
                .font(Theme.Typography.formatNote)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}
