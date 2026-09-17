import SwiftUI

/// 相机顶栏（浮层 · 常驻 · **两行**）。
///
/// 版式对齐网页原型 `.topbar`（高 56pt = 主行 30 + 副行 26）：
/// ```
/// 主行 = L/R 电平表（左 73pt） + 模式条（中，吃满余量并居中） + 三图标（右 73pt）
/// 副行 = 「影调预览」胶囊（左）                     + 「剩余存储」胶囊（右）
/// ```
///
/// ## 为什么主行必须是「两侧等宽 + 中段吃满」而不是 ZStack 覆盖式
///
/// `ZStack` 里的居中只保证"在容器内居中"；左侧没有等宽占位时，模式条整体会右偏。
/// 真机实测过后果（iPhone 16 Pro / iOS 26.6）：模式条右端 334.7pt 与右上图标组
/// 起点 306.7pt **重叠 28pt**，「视频」二字被盖掉一半。现在左右各 73pt 等宽
/// → 模式条盒中心 = 屏中心。这与原型 `--tb-side-w` 是同一套做法。
///
/// ## 右上三图标的这一格是**预留位**
///
/// | | 现在 | 模块 #10（⠿ 功能面板）落地后 |
/// |---|---|---|
/// | 第 3 个图标 | 设置（齿轮） | ⠿ 功能面板，设置移进面板里 |
///
/// 之所以现在放齿轮而不是直接上 ⠿：面板还没落地，放 ⠿ 就等于让设置页无路可进
/// ——那违反"不做点了没反应"的同一条精神（入口存在但到不了目的地）。
/// 这一格的宽度按 73pt 钉死，所以以后换图标**不会**动模式条的居中。
///
/// ## 副行两颗胶囊的诚实边界
///
/// - 「剩余存储」：**真数据**，读 `DeviceStorage.freeSpaceText()`（约 10 秒刷新一次）。
/// - 「影调预览」：**真开关、假生效**。取景器的调色链路要等 P4 修图引擎，
///   所以现在切换它画面上不会有任何变化 —— 由 `CameraViewModel.tonePreviewTapped`
///   明确弹提示说明，而不是装作已经生效。
struct TopBarView: View {

    let mode: CaptureSessionMode
    let freeSpaceText: String
    let isTonePreviewOn: Bool
    let isGridOn: Bool

    let onModeTap: (CaptureSessionMode) -> Void
    let onFlashTap: () -> Void
    let onGridTap: () -> Void
    let onTonePreviewTap: () -> Void
    let onStorageTap: () -> Void
    let onSettingsTap: () -> Void

    /// 上缘渐隐黑向上多伸出的高度（覆盖状态栏区域）
    private static let scrimOverhang: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            secondaryRow
        }
        .frame(height: Theme.Size.topBarHeight)
        // 底对齐 + 超高：让渐隐从顶栏上缘再往上 60pt 开始，到顶栏下缘刚好淡到全透明。
        // 它只保证白色文字在明亮天空下可读，所以是"背景"而不是"面板"
        // ——看得见的画面没有被遮住，不算挤压取景器。
        .background(alignment: .bottom) { topScrim }
    }

    // MARK: - 主行

    private var mainRow: some View {
        // ⚠️ **spacing 必须是 0**：中段要给模式条留出「370 − 73×2 = 224pt」的完整盒子，
        // 一旦这里给 8（原型 `.tb-row1{ gap:8px }` 的值），中段就只剩 208pt ——
        // 393/390pt 宽的机型（iPhone 16/15/14）当场溢出。
        //
        // 那视觉间距从哪来？两侧块自己就有：
        //   - 电平表块 73pt 宽、点是**左对齐**的 → 右边约 23pt 是空白
        //   - 三图标块 73pt 宽、图标是**右对齐**的 → 左边约 23pt 是空白
        // 于是模式条两侧实际各有 23 + 11 ≈ 34pt 的呼吸空间，与原型（≈39pt）基本一致。
        HStack(spacing: 0) {
            AudioLevelMeterView()

            // 中段吃满余量（224pt），模式条在它内部居中 → 模式条的盒中心 = 屏中心。
            // 少了 `frame(maxWidth: .infinity)`，HStack 会先收缩到自然宽再被居中，
            // 右侧图标就会内缩（真机实测过：齿轮右端 372.3pt，应为 386pt）。
            ModeSelector(selection: mode) { tapped in
                onModeTap(tapped)
            }
            .frame(maxWidth: .infinity)

            iconCluster
        }
        .frame(height: Theme.Size.topBarRow1Height)
    }

    private var iconCluster: some View {
        // 三个按钮**间距为 0** 地拼满 73pt（每个 73/3 ≈ 24.33）。
        // 不用负间距、也不用 contentShape 外扩：那两种做法都会让相邻按钮的命中区交叠，
        // 点「网格」可能落到「闪光灯」上。
        HStack(spacing: 0) {
            TopBarIconButton(
                glyph: "bolt.fill",
                label: "闪光灯",
                isOn: false,
                action: onFlashTap
            )
            TopBarIconButton(
                glyph: "grid",
                label: "网格线",
                isOn: isGridOn,
                action: onGridTap
            )
            TopBarIconButton(
                glyph: "gearshape",
                label: "设置",
                isOn: false,
                action: onSettingsTap
            )
        }
        .frame(width: Theme.Size.topBarSideWidth, alignment: .trailing)
    }

    // MARK: - 副行

    private var secondaryRow: some View {
        HStack(spacing: Theme.Size.topBarRowSpacing) {
            tonePreviewChip
            Spacer(minLength: 0)
            storageChip
        }
        .frame(height: Theme.Size.topBarRow2Height)
    }

    /// 「影调预览」：开 = 琥珀高亮（原型 `.chip.accent`），关 = 普通深色胶囊
    private var tonePreviewChip: some View {
        Button(action: onTonePreviewTap) {
            HStack(spacing: Theme.Size.chipIconSpacing) {
                // 半圆图标，对应原型那颗"明暗对半"的图形
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: Theme.Size.chipGlyphSize))
                Text("影调预览")
                    .font(Theme.Typography.chip)
            }
            .foregroundStyle(isTonePreviewOn ? Theme.Palette.accent : Theme.Palette.primaryText)
            .padding(.horizontal, Theme.Size.chipHorizontalPadding)
            .frame(height: Theme.Size.chipHeight)
            .background(
                Capsule().fill(
                    isTonePreviewOn
                        ? Theme.Palette.accentDim
                        : Theme.Palette.panel.opacity(0.76)
                )
            )
            .overlay(
                Capsule().stroke(
                    isTonePreviewOn
                        ? Theme.Palette.accent.opacity(0.45)
                        : Theme.Palette.stroke,
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("影调预览")
        .accessibilityValue(isTonePreviewOn ? "已开" : "已关")
    }

    /// 「剩余存储」：真数据。图标沿用原型的电池形（它在原型里就是拿来表示存储余量的）
    private var storageChip: some View {
        Button(action: onStorageTap) {
            HStack(spacing: Theme.Size.chipIconSpacing) {
                Image(systemName: "battery.100")
                    .font(.system(size: Theme.Size.chipGlyphSize))
                Text(freeSpaceText)
                    .font(Theme.Typography.chip)
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.Palette.primaryText)
            .padding(.horizontal, Theme.Size.chipHorizontalPadding)
            .frame(height: Theme.Size.chipHeight)
            .background(Capsule().fill(Theme.Palette.panel.opacity(0.76)))
            .overlay(Capsule().stroke(Theme.Palette.stroke, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("剩余可用存储 \(freeSpaceText)")
        .accessibilityHint("点按查看存储详情")
    }

    // MARK: - 上缘渐隐

    private var topScrim: some View {
        LinearGradient(
            colors: [
                Theme.Palette.canvas.opacity(0.55),
                Theme.Palette.canvas.opacity(0.30),
                Theme.Palette.canvas.opacity(0.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Theme.Size.topBarHeight + Self.scrimOverhang)
        .allowsHitTesting(false)
    }
}

// MARK: - 顶栏图标按钮

/// 顶栏主行右侧的图标按钮。
///
/// 命中区 = 24.33 × 30pt（顶栏侧宽三等分），**比原型的 17×17 大**，
/// 但仍小于 Apple HIG 建议的 44×44 —— 这是"模式条居中"与"三图标 44pt"
/// 在 402pt 屏宽上不可兼得时做的取舍，账算在 `Theme.Size.topBarSideWidth` 的注释里。
private struct TopBarIconButton: View {

    let glyph: String
    let label: String
    /// 是否处于"开启"态：原型 `.tb-icon.on{ color:#fff }`，关态是 88% 白
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: Theme.Size.topBarIconGlyphSize, weight: .semibold))
                .foregroundStyle(
                    isOn
                        ? Theme.Palette.primaryText
                        : Theme.Palette.primaryText.opacity(0.88)
                )
                .frame(
                    width: Theme.Size.topBarIconCellWidth,
                    height: Theme.Size.topBarRow1Height
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
