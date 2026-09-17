import SwiftUI

/// 场景 · 风格条（常驻 · 浮层）：折叠态是一行胶囊，展开态是两条横滑（场景 / 风格）。
///
/// 版式对齐网页原型 `.row-scenestyle`（折叠 36px / 展开 147px）：
/// ```
/// 折叠  [ 场景 人像 · 风格 柔暖人像            ] [⌃]
/// 展开  ┌ 场景 · 决定推荐风格与曝光            人像 ┐
///       │  [人像][风景][美食][夜景][街拍]           │
///       ├ 风格 · 一键成片，含参数配方        柔暖人像 ┤
///       │  [缩略图][缩略图]…                        │
///       └──────────────────────────────────────────┘
/// ```
///
/// ## 两态互斥（照原型 `setSS`）
///
/// 展开时同时收起：**折叠胶囊**、滤镜条、参数刻度条、EV 圆盘、**焦段条**。
/// 折叠胶囊必须收起 —— 原型第 5 轮就是被它坑的：胶囊 + 两块内容叠在一起溢出 39px，
/// 压在下面的图标行上。所以这行高度锁定 147，内容深度 145.55，**余量只有 1.5pt**。
///
/// ## 三个入口行为一致
///
/// 折叠胶囊 / 箭头 / 快门排右下角的风格方块，全都走同一个 `onToggle`（原型 `toggleSS`）。
///
/// ## 本件不碰硬件
///
/// 选场景只更新选中状态并提示"建议的白平衡与 EV"，**不把它们推给相机**
/// （守 A 组边界；EV / 白平衡落地属 B 组接线）。
struct SceneStyleStrip: View {

    /// 当前选中的场景
    let scene: ScenePreset
    /// 当前选中的风格
    let style: StylePreset
    /// 当前选中的滤镜名（nil = 无）；由场景推荐带入，滤镜条（#7）也会改它
    let filterName: String?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSceneTap: (ScenePreset) -> Void
    let onStyleTap: (StylePreset) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedContent
            } else {
                collapsedCapsule
            }
        }
        .frame(
            height: isExpanded
                ? Theme.Size.sceneStyleExpandedHeight
                : Theme.Size.sceneStyleCollapsedHeight
        )
        // 高度变化用弹簧动画（docs/03 §7.3）；内容切换期间裁掉溢出，避免动画中露馅
        .clipped()
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isExpanded)
    }

    // MARK: - 折叠态

    /// 折叠胶囊：占满 + 高 28；「场景 X（accent）· 风格 Y」
    private var collapsedCapsule: some View {
        HStack(spacing: Theme.Size.stripSpacing) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Text("场景")
                        .font(Theme.Typography.ssCapsule)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                    Text(scene.displayName)
                        .font(Theme.Typography.ssCapsule)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Palette.accent)
                    if !style.displayName.isEmpty {
                        Text("·")
                            .font(Theme.Typography.ssCapsule)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                        Text("风格")
                            .font(Theme.Typography.ssCapsule)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                        Text(style.displayName)
                            .font(Theme.Typography.ssCapsule)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.Palette.primaryText)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: Theme.Size.sceneStyleCapsuleHeight)
                .background(
                    Capsule().fill(Theme.Palette.panel)
                )
                .overlay(
                    Capsule().stroke(Theme.Palette.stroke, lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("场景 \(scene.displayName)，风格 \(style.displayName)，展开")

            Button(action: onToggle) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .frame(
                        width: Theme.Size.sceneStyleArrowSide,
                        height: Theme.Size.sceneStyleArrowSide
                    )
                    .background(Circle().fill(Theme.Palette.panel))
                    .overlay(Circle().stroke(Theme.Palette.stroke, lineWidth: 0.5))
                    .contentShape(Circle())
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起场景与风格" : "展开场景与风格")
        }
        .padding(.horizontal, Theme.Size.sceneStyleHorizontalPadding)
        .frame(height: Theme.Size.sceneStyleCollapsedHeight)
    }

    // MARK: - 展开态

    private var expandedContent: some View {
        VStack(spacing: 0) {
            block(
                title: "场景",
                subtitle: " · 决定推荐风格与曝光",
                picked: scene.displayName
            ) {
                sceneStrip
            }
            block(
                title: "风格",
                subtitle: " · 一键成片，含参数配方",
                picked: filterName.map { "\(style.displayName) · \($0)" } ?? style.displayName
            ) {
                styleStrip
            }
        }
    }

    /// 一块 = 顶边框 0.5 + 上内边距 2 + 标题 14 + 横滑条
    private func block<Content: View>(
        title: String,
        subtitle: String,
        picked: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.Palette.ssBlockBorder)
                .frame(height: 0.5)
                .padding(.bottom, Theme.Size.ssBlockTopPadding)

            HStack(spacing: 0) {
                Text(title)
                    .font(Theme.Typography.ssBlockTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Palette.secondaryText)
                + Text(subtitle)
                    .font(Theme.Typography.ssBlockTitle)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                Spacer(minLength: 0)
                Text(picked)
                    .font(Theme.Typography.ssBlockTitle)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Size.stripHorizontalPadding)
            .frame(height: Theme.Size.ssBlockTitleHeight)

            content()
        }
    }

    // MARK: - 横滑条

    /// 场景胶囊条：横向滚动（5 项），隐藏滚动条
    private var sceneStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Size.stripSpacing) {
                ForEach(SceneCatalog.all) { item in
                    let isSelected = item.id == scene.id
                    Button {
                        onSceneTap(item)
                    } label: {
                        Text(item.displayName)
                            .font(Theme.Typography.sceneChip)
                            .foregroundStyle(
                                isSelected ? Theme.Palette.textOnLight : Theme.Palette.secondaryText
                            )
                            .padding(.horizontal, Theme.Size.sceneChipHorizontalPadding)
                            .frame(height: Theme.Size.sceneChipHeight)
                            .background(
                                Capsule().fill(
                                    isSelected ? Theme.Palette.accent : Theme.Palette.panel
                                )
                            )
                            .overlay(
                                Capsule().stroke(
                                    isSelected ? Theme.Palette.accent : Theme.Palette.stroke,
                                    lineWidth: 0.5
                                )
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .accessibilityLabel("场景 \(item.displayName)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, Theme.Size.stripHorizontalPadding)
        }
    }

    /// 风格卡条：缩略图 + 名字 + 参数徽标（**一级视觉权重**，原型定的）
    private var styleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Size.stripSpacing) {
                ForEach(StyleCatalog.all) { item in
                    let isSelected = item.id == style.id
                    Button {
                        onStyleTap(item)
                    } label: {
                        VStack(spacing: Theme.Size.styleCardSpacing) {
                            StyleThumbnailView(
                                style: item,
                                size: CGSize(
                                    width: Theme.Size.styleCardWidth,
                                    height: Theme.Size.styleCardThumbHeight
                                ),
                                cornerRadius: Theme.Radius.md,
                                appearance: .filled
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                    .stroke(
                                        isSelected ? Theme.Palette.accent : Theme.Palette.stroke,
                                        lineWidth: isSelected ? 2 : 0.5
                                    )
                            )
                            Text(item.displayName)
                                .font(Theme.Typography.styleName)
                                .foregroundStyle(
                                    isSelected ? Theme.Palette.accent : Theme.Palette.secondaryText
                                )
                                .lineLimit(1)
                                // 行高钉死（见 Theme.Size.styleNameHeight 的注释）：
                                // 展开态 147pt 的内容深度账不能交给字体度量去浮动
                                .frame(height: Theme.Size.styleNameHeight)
                            Text(item.badge)
                                .font(Theme.Typography.styleBadge)
                                .foregroundStyle(
                                    isSelected
                                        ? Theme.Palette.accent.opacity(0.85)
                                        : Theme.Palette.tertiaryText
                                )
                                .lineLimit(2)
                                .frame(height: Theme.Size.styleBadgeHeight)
                        }
                        .frame(width: Theme.Size.styleCardWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("风格 \(item.displayName)，\(item.badge)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, Theme.Size.stripHorizontalPadding)
        }
    }
}
