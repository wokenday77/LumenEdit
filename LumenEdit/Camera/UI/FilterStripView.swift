import SwiftUI

/// 滤镜条（浮层 · 默认隐藏，上划取景器呼出，下划收起）。
///
/// 版式对齐网页原型 `.row-filter`（展开 144px）与 `.filter-card`（84×84 卡 + 名字）：
/// ```
/// ┌ 滤镜 · 只叠颜色层（再点一次取消）          冷青暖橙 ┐
/// │  [卡 84][卡 84][卡 84] …（横滑，14 个）              │
/// └────────────────────────────────────────────────────┘
/// ```
/// 位置在底栏最上方（场景·风格条**之上**）。互斥（原型 `setFilter` / `setSS`）：
/// 展开时场景·风格条收起为折叠胶囊、焦段条收起；⤢ 放大态下整条强制隐藏。
/// 状态与呼出/收起手势的决策都在 `CameraViewModel`（`isFilterStripExpanded` / `swiped(up:)`）。
///
/// ## 卡片缩略图（P4 之前的占位）
///
/// 原型的卡 = **实时取景缩略图**（当前画面套该滤镜，"拍到的才是看到的"，不搞静态封面）。
/// P4 之前没有渲染链路，先用**该滤镜自己的 `swatches` 三色渐变**占位 ——
/// 与 `StyleThumbnailView` 同一套做法；hex 解析直接复用 `StyleThumbnailView.color(from:)`，
/// 全工程只有一份。P4 接上渲染后只换 `swatchFace` 这一处画法，调用点不动。
///
/// ## 选中 / 取消
///
/// 选中 = **白色**描边高亮 + 白色泛光（原型 `.filter-card.on`；注意是白描边，
/// 与风格卡的 accent 描边刻意不同 —— 滤镜是"叠加层"不是"成片方案"）。
/// **再点已选中的 = 取消回到原片**（`filterId = nil`，原型 `buildFilters` 的 click 逻辑）。
///
/// ## 渲染边界（诚实边界）
///
/// 滤镜对画面的实际作用在 P4；本件交付"选择状态 + UI"。呼出时由 toast 说明
/// （与「影调预览」同款的边界讲法），不假装画面已经变化。
struct FilterStripView: View {

    /// 当前选中的滤镜 id（nil = 无 / 原片）
    let selectedId: String?
    /// 点卡回调（选中 / 再点取消的判断在 `CameraViewModel.filterTapped`）
    let onTap: (FilterDefinition) -> Void

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            cardStrip
        }
        .padding(.top, Theme.Size.filterStripTopPadding)
        .frame(height: Theme.Size.filterStripExpandedHeight, alignment: .top)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        // 原型 box-shadow: 0 -10px 30px rgba(0,0,0,.35)；CSS blur 30 ≈ SwiftUI radius 15
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: -10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("滤镜条")
    }

    // MARK: - 面板底

    /// 深色渐变面板 + 顶部细描边（原型 `.screen.filter-on .row-filter` 的背景层）。
    ///
    /// ⚠️ 刻意偏离原型的一处：原型面板是**贴屏边的**（顶角 18、底角 0，往下连着整条底栏栈）；
    /// Swift 侧底栏栈整体内缩 16pt（`CameraView.bottomArea` 的既有版式），
    /// 面板悬空时底角留方会像被切掉，所以四角都取 18（`Theme.Radius.lg`），读作一张"浮起的卡"。
    private var panelBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.Palette.filterPanelTop, Theme.Palette.filterPanelBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay(
            // 顶部 0.5pt 描边（原型 border-top: .5px solid rgba(255,255,255,.08)）
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.Palette.filterPanelTopBorder)
                    .frame(height: 0.5)
                Spacer(minLength: 0)
            }
        )
    }

    // MARK: - 标题行

    /// 标题行：与 `SceneStyleStrip.block` 的标题行**同构**（那一处是 private 的）。
    /// 刻意不现在抽共享组件：#6 刚交付、Mac 截图还没回来，动它会让两个待验的东西混在一起；
    /// 等 #10 / #11 出现第三处同构标题时再抽 `StripBlockTitle`（三处规则）。
    private var titleRow: some View {
        HStack(spacing: 0) {
            Text("滤镜")
                .font(Theme.Typography.ssBlockTitle)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.Palette.secondaryText)
            + Text(" · 只叠颜色层（再点一次取消）")
                .font(Theme.Typography.ssBlockTitle)
                .foregroundStyle(Theme.Palette.tertiaryText)

            Spacer(minLength: 0)

            Text(pickedName)
                .font(Theme.Typography.ssBlockTitle)
                .foregroundStyle(Theme.Palette.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Size.stripHorizontalPadding)
        .frame(height: Theme.Size.ssBlockTitleHeight)
        .accessibilityElement(children: .combine)
    }

    /// 当前选中滤镜名（nil = 无），对应原型 `#filterPicked`
    private var pickedName: String {
        guard let selectedId,
              let filter = FilterCatalog.all.first(where: { $0.id == selectedId }) else {
            return "无"
        }
        return filter.displayName
    }

    // MARK: - 卡条

    /// 滤镜卡横滑条：数据驱动（`FilterCatalog.all` 14 项），隐藏滚动条
    private var cardStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Size.stripSpacing) {
                ForEach(FilterCatalog.all) { filter in
                    let isSelected = filter.id == selectedId
                    Button {
                        onTap(filter)
                    } label: {
                        VStack(spacing: Theme.Size.filterCardInnerSpacing) {
                            swatchFace(for: filter, isSelected: isSelected)

                            Text(filter.displayName)
                                .font(Theme.Typography.filterName)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundStyle(
                                    isSelected
                                        ? Theme.Palette.primaryText
                                        : Theme.Palette.secondaryText
                                )
                                .lineLimit(1)
                                // 行高钉死（见 Theme.Size.filterNameHeight）：
                                // 144 的内容深度账不交给字体度量浮动
                                .frame(height: Theme.Size.filterNameHeight)
                        }
                        .frame(width: Theme.Size.filterCardSide)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("滤镜 \(filter.displayName)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, Theme.Size.stripHorizontalPadding)
        }
        // 原型 `.row-filter .strip{ margin-top:9px; align-items:flex-start }`
        .padding(.top, Theme.Size.filterStripCardTopGap)
    }

    /// 卡片缩略面：该滤镜 `swatches` 三色渐变（P4 前的占位）+ 选中白描边。
    private func swatchFace(for filter: FilterDefinition, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Size.filterCardCornerRadius, style: .continuous)
            .fill(placeholderGradient(for: filter))
            .frame(width: Theme.Size.filterCardSide, height: Theme.Size.filterCardSide)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Size.filterCardCornerRadius, style: .continuous)
                    .stroke(
                        isSelected ? Color.white : Theme.Palette.filterCardStroke,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            // 原型选中态的白色泛光：0 0 16px rgba(255,255,255,.28)
            .shadow(
                color: isSelected ? Color.white.opacity(0.28) : .clear,
                radius: 8
            )
            .animation(.easeInOut(duration: 0.16), value: isSelected)
    }

    /// 占位渐变：优先该滤镜自己的 `swatches`，不足两色时退中性灰
    /// （复用 `StyleThumbnailView` 的同一份 hex 解析与兜底色，不维护第二份）。
    private func placeholderGradient(for filter: FilterDefinition) -> LinearGradient {
        let colors = filter.swatches.count >= 2
            ? filter.swatches.map(StyleThumbnailView.color(from:))
            : StyleThumbnailView.fallbackColors
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
