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
    /// 存储胶囊文本（`CameraViewModel.storageChipText`）：照片/实况模式是剩余空间；
    /// 视频 / Log 实况模式是"剩余可录时长 + 空间"（拍摄关键信息）。
    let storageText: String
    let isTonePreviewOn: Bool
    let isGridOn: Bool

    let onModeTap: (CaptureSessionMode) -> Void
    let onFlashTap: () -> Void
    let onGridTap: () -> Void
    let onTonePreviewTap: () -> Void
    let onStorageTap: () -> Void
    /// 右上第三颗图标：**⠿ 功能面板**（#10，2026-09-18 由齿轮改成 ⠿）。
    ///
    /// 「设置」不再占顶栏，收进面板第 6 格（原型同款：一个 ⠿ 只有一个行为，
    /// 原「更多」下拉菜单整块被功能面板取代）。
    let onFunctionPanelTap: () -> Void

    // MARK: 格式芯片（#11）

    /// 芯片文案（`CameraViewModel.formatChipText`）
    let formatChipText: String
    /// 格式选择器是否展开（展开中芯片变亮）
    let isFormatSelectorExpanded: Bool
    let onFormatChipTap: () -> Void

    /// 上缘渐隐黑向上多伸出的高度（覆盖状态栏区域）
    private static let scrimOverhang: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            secondaryRow
        }
        .frame(height: Theme.Size.topBarHeight)
        // ⚠️ **两行的绘制顺序是有语义的，不要调换。**
        // 模式条热区为了凑满 44pt，向下溢出了 7pt，与副行的「剩余存储」胶囊有
        // 12×6pt 的几何重叠（实测值见 `Theme.Size.modeTabHitHeight` 的注释）。
        // 现在没出事，正是因为副行画在主行**之后**、重叠区归胶囊 —— 用户点到的和看到的一致。
        // 一旦调换顺序 / 加 `.zIndex` / 把两行拆进不同容器，重叠区就会变成
        // 「点存储胶囊却切了拍摄模式」。改这些之前必须重测。
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
        // 用令牌而不是字面量 0：自检要按这个值复算中段可用宽度（见 tools/check_swift.js 第 5 组）。
        HStack(spacing: Theme.Size.topBarMainRowSpacing) {
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

    /// 右上角那一格：**照片 / 实况模式是三图标；视频 / Log 实况模式换成格式芯片**。
    ///
    /// 两组是**顶替关系**（原型 `.screen.mode-video .tb-icons{display:none}` +
    /// `.fmt-chip{display:inline-flex}`），不是并列；两者都钉在 `topBarSideWidth`(73)
    /// 这一格里，所以模式条的居中不受影响。
    @ViewBuilder
    private var iconCluster: some View {
        if mode.isRecordingBased {
            FormatChipView(
                text: formatChipText,
                isExpanded: isFormatSelectorExpanded,
                onTap: onFormatChipTap
            )
            .frame(width: Theme.Size.topBarSideWidth, alignment: .trailing)
        } else {
            topBarIcons
        }
    }

    private var topBarIcons: some View {
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
                glyph: "circle.grid.3x3.fill",
                label: "功能面板",
                isOn: false,
                action: onFunctionPanelTap
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
                storageValue
            }
            .foregroundStyle(Theme.Palette.primaryText)
            .padding(.horizontal, Theme.Size.chipHorizontalPadding)
            .frame(height: Theme.Size.chipHeight)
            .background(Capsule().fill(Theme.Palette.panel.opacity(0.76)))
            .overlay(Capsule().stroke(Theme.Palette.stroke, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("存储：\(storageText)")
        .accessibilityHint("点按查看存储详情")
    }

    /// 存储数值区：**按"最宽可能文本"预留宽度，首屏即定宽**。
    ///
    /// 为什么要预留：容量是节流查询的（约 10 秒一次），启动后前几秒只能显示占位「—」。
    /// 不预留的话，真实数值到达时胶囊会**突然变宽、位置左移**（实测 73pt → 95pt）。
    ///
    /// 这不只是观感问题 —— 2026-09-17 Mac 侧就是拿"加载中的胶囊"量了几何，
    /// 结果**漏掉了模式条热区与胶囊那 12×6pt 的重叠**。定宽之后，同一处几何任何时刻量都一样。
    ///
    /// 用"隐形同宽兄弟"而不是硬编码 `minWidth`：字号一变预留宽度自动跟着变，
    /// 不会留下一个需要人工同步的魔法数字；如果将来真出现更长的文本，ZStack 会自动撑开、不裁字。
    private var storageValue: some View {
        ZStack(alignment: .trailing) {
            Text(storageWidthReservation)
                .font(Theme.Typography.chip)
                .monospacedDigit()
                .opacity(0)
                .accessibilityHidden(true)
            Text(storageText)
                .font(Theme.Typography.chip)
                .monospacedDigit()
        }
    }

    /// 宽度预留文本：取**当前模式下**"最宽可能值"的量级。
    ///
    /// - 照片 / 实况模式：`FormatText.fileSize` 用 `ByteCountFormatter` 且 `allowedUnits` 只有 MB / GB
    ///   （没有 TB、也不会出现 4 位整数），上界就是「999.99 GB」这一档 —— 9 个字符留足。
    /// - **视频 / Log 实况模式**（#11）：文本变成 `≈ 85m · 31 GB` 这种**更长的形态**
    ///   （`≈ 时长 · 空间`）。⚠️ **这里必须跟着换**，否则预留不够 ——
    ///   数值到达时胶囊会突然变宽（2026-09-17 Mac 侧实测过的 73 → 95pt 跳变会原样复发，
    ///   而那次跳变还害得它把几何量错）。
    ///   上界取「≈ 23h 59m · 999.99 GB」：999 GB 空间 ÷ 96 Mbps（4K120）≈ 23 小时。
    ///
    /// 用"隐形同宽兄弟"而不是硬编码 `minWidth`：字号一变预留宽度自动跟着变，
    /// 不留需要人工同步的魔法数字；真出现更长的文本时 ZStack 会自动撑开、不裁字。
    private var storageWidthReservation: String {
        mode.isRecordingBased ? "≈ 23h 59m · 999.99 GB" : "999.99 GB"
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
