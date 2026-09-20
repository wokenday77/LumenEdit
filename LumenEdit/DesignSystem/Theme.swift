import SwiftUI

/// 设计令牌。
///
/// 相机页与修图页都是深色，颜色集中在这里定义，避免各页面各写一套
/// `Color.black.opacity(x)`，改一次要翻遍全工程。
enum Theme {

    // MARK: - 颜色

    enum Palette {
        /// 取景器底色
        static let canvas = Color.black
        /// 浮层面板
        static let panel = Color(white: 0.09)
        /// 面板上的次级按钮/胶囊
        static let panelElevated = Color(white: 0.16)
        /// 分隔线与描边
        static let stroke = Color.white.opacity(0.14)
        static let primaryText = Color.white
        static let secondaryText = Color.white.opacity(0.62)
        static let tertiaryText = Color.white.opacity(0.38)
        /// 主强调色（与 AccentColor 保持一致的金黄）
        static let accent = Color(red: 0.949, green: 0.686, blue: 0.235)
        static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
        /// 对焦方框
        static let focusIndicator = Color(red: 1.0, green: 0.83, blue: 0.25)
        /// 录制指示
        static let recording = Color(red: 1.0, green: 0.23, blue: 0.19)
        /// 成功 / 电平表点亮（原型 `--ok: #34d058`）
        static let ok = Color(red: 0.204, green: 0.816, blue: 0.345)
        /// 圆盘专用绿（原型 `#00E08A`：对焦 / EV 圆盘的指针、高亮段、数值框描边）。
        /// ⚠️ 与 `ok`（`#34D058`）**不是同一个色** —— 原型里刻度条用 ok、圆盘用这个更亮的绿，
        /// 别"顺手统一"成同一个（两处色值都是对标参考图取的）。
        static let dialAccent = Color(red: 0, green: 224 / 255, blue: 138 / 255)
        /// 「自动对焦」开关 on 色（原型 `.sw.on{ background:#30d158 }`）。
        /// ⚠️ 又是第三个绿 —— 原型三处绿各是各的对标值（刻度条 ok / 圆盘 dialAccent /
        /// 通用开关这个），同样别顺手统一。
        static let dialSwitchOn = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
        /// 「自动对焦」开关 off 底色（原型 `.sw{ background:#39393d }`）
        static let dialSwitchOff = Color(red: 57 / 255, green: 57 / 255, blue: 61 / 255)
        /// accent 的低饱和底：用在「已开启」的胶囊上（原型 `--accent-dim: rgba(242,175,60,.20)`）
        static let accentDim = accent.opacity(0.20)
        /// 模式条未选中档位（原型 `.mode-tab{ color: rgba(255,255,255,.5) }`）
        static let modeInactive = Color.white.opacity(0.5)

        /// 焦段药丸：未选中的底 / 描边 / 文字（原型 `rgba(255,255,255,.11)` / `.16` / `.88`）
        static let focalPillFill = Color.white.opacity(0.11)
        static let focalPillStroke = Color.white.opacity(0.16)
        static let focalPillText = Color.white.opacity(0.88)
        /// 场景·风格块之间的分隔线（原型 `border-top: .5px rgba(255,255,255,.07)`）
        static let ssBlockBorder = Color.white.opacity(0.07)
        /// 浅色面上的深色文字（原型 `#15181c`）。
        /// 焦段药丸选中态是**白底**，文字必须转深色 —— 和 accent 黄底上用纯黑是同一类处理。
        static let textOnLight = Color(red: 0.082, green: 0.094, blue: 0.110)

        /// 底部图标行：图标字形色 / 标签色（原型 `rgba(255,255,255,.9)` / `.6`）
        static let toolRowText = Color.white.opacity(0.9)
        static let toolRowLabel = Color.white.opacity(0.6)

        /// 风格预览方块的内层底色（原型 `.style-thumb .inner{ background:#1a1d21 }`）
        static let styleThumbInner = Color(red: 0.102, green: 0.114, blue: 0.129)

        // MARK: 滤镜条（2026-09-18 #7）

        /// 滤镜条面板的渐变底两端（原型
        /// `linear-gradient(180deg, rgba(17,19,23,.94) 0%, rgba(17,19,23,.82) 100%)`）。
        /// 一层深色面板底是必须的：没有它，标题字直接压在取景画面上会发虚（原型注释）。
        static let filterPanelTop = Color(
            red: 17.0 / 255, green: 19.0 / 255, blue: 23.0 / 255
        ).opacity(0.94)
        static let filterPanelBottom = Color(
            red: 17.0 / 255, green: 19.0 / 255, blue: 23.0 / 255
        ).opacity(0.82)

        /// 滤镜卡未选中态的细描边（原型 `.filter-swatch{ box-shadow:0 0 0 1px rgba(255,255,255,.12) }`）
        static let filterCardStroke = Color.white.opacity(0.12)

        /// 滤镜条面板顶部描边（原型 `border-top:.5px solid rgba(255,255,255,.08)`）。
        /// 与场景·风格块的 `ssBlockBorder`（.07）数值不同，是两笔账，别合并。
        static let filterPanelTopBorder = Color.white.opacity(0.08)

        // MARK: 功能面板（#10，2026-09-18）

        /// 面板底（原型 `--panel-solid: rgba(16,19,23,.92)`，几乎不透明的一张卡）
        static let functionPanelFill = Color(
            red: 16.0 / 255, green: 19.0 / 255, blue: 23.0 / 255
        ).opacity(0.92)
        /// 面板描边（原型 `--stroke-2: rgba(255,255,255,.26)`）
        static let functionPanelStroke = Color.white.opacity(0.26)
        /// 圆形图标底 / 描边（原型 `.fn-ic{ background:rgba(255,255,255,.09); border:1px solid rgba(255,255,255,.12) }`）
        static let functionGlyphFill = Color.white.opacity(0.09)
        static let functionGlyphStroke = Color.white.opacity(0.12)
        /// 按下态（原型 `.fn-btn:active .fn-ic{ background:rgba(255,255,255,.16) }`）
        static let functionGlyphFillPressed = Color.white.opacity(0.16)
        /// 开启态（原型 `.fn-btn.on .fn-ic{ background:rgba(52,208,88,.16); border-color:rgba(52,208,88,.6) }`）
        /// —— 复用 `ok` 而不是写第二遍 RGB（`Self.` 是必需的：静态属性初始化器里引用同类型成员）
        static let functionGlyphFillOn = Self.ok.opacity(0.16)
        static let functionGlyphStrokeOn = Self.ok.opacity(0.6)
        /// foot 区上分隔线（原型 `.fn-foot{ border-top:.5px solid rgba(255,255,255,.09) }`）
        static let functionFootSeparator = Color.white.opacity(0.09)

        // MARK: 视频格式芯片（#11，2026-09-18）

        /// 芯片底 / 描边（原型 `.fmt-chip{ background:rgba(255,255,255,.10); border:.5px solid rgba(255,255,255,.16) }`）
        static let formatChipFill = Color.white.opacity(0.10)
        static let formatChipStroke = Color.white.opacity(0.16)
        /// 展开中（原型 `.fmt-chip.on{ background:rgba(255,255,255,.18); border-color:rgba(255,255,255,.3) }`）
        static let formatChipFillExpanded = Color.white.opacity(0.18)
        static let formatChipStrokeExpanded = Color.white.opacity(0.30)
        /// 选择器里的选项按钮（原型 `.fmt-opt{ background:rgba(255,255,255,.05); border:.5px solid var(--stroke) }`）
        static let formatOptionFill = Color.white.opacity(0.05)
        /// 选择器底注上方的分隔线（原型 `.fm-note{ border-top:.5px solid rgba(255,255,255,.07) }`）
        static let formatNoteSeparator = Color.white.opacity(0.07)

        // MARK: 参数刻度条（B2 · 模块 #9）

        /// 刻度条背景（原型 `.screen.strip-on .strip-panel` 的深色渐变；只用底部那档色）
        static let stripPanelBottom = Color(red: 0.039, green: 0.047, blue: 0.059).opacity(0.72)

        /// 普通刻度线（原型 `.sp-tick{ background:rgba(255,255,255,.34) }`）
        static let stripTick = Color.white.opacity(0.34)
        /// **中间档**刻度线（原型 `.sp-tick.mid{ background:rgba(255,255,255,.48) }`）。
        ///
        /// 2026-09-20 批四补：原型 CSS 里**四档刻度**（plain / mid / major / preset）早就定义好了，
        /// 但 JS 渲染只用了 `major`/`preset` 两档 —— Swift 侧于是把"主档之间的细刻度"
        /// 实现成了自创的 1px / 20% 白 / 半高发丝线，**太淡、看不出层级**（用户批三实测
        /// "外形没有变化"）。现改回原型的第二层：15pt 高 / 48% 白 / 1.5pt 宽（见
        /// `paramStripTickMidHeight`），层级从对比度上直接读得出来。
        static let stripTickMid = Color.white.opacity(0.48)
        /// 主刻度线（原型 `.sp-tick.major{ background:rgba(255,255,255,.82) }`）
        static let stripTickMajor = Color.white.opacity(0.82)
        /// 白平衡**预设档**的刻度（原型 `.sp-tick.preset{ background:rgba(242,175,60,.85) }` = `--accent`）
        static let stripTickPreset = Color(red: 0.949, green: 0.686, blue: 0.235).opacity(0.85)
        /// 刻度下的数字（原型 `.sp-num{ color:rgba(255,255,255,.62) }`）
        static let stripNumber = Color.white.opacity(0.62)
        /// **自动态**下刻度与数字整体压暗（原型 `.screen.strip-auto .sp-num{ color:rgba(255,255,255,.34) }`）
        static let stripInactive = Color.white.opacity(0.34)

        /// 气泡底 / 指针 / 开关（开）—— **统一用一个令牌**。
        ///
        /// ⚠️ 原型这里是**两个不同的绿**（指针 `#3ddc84`、开关 `#30d158`）；
        /// 肉眼不可辨，不值得为此新增两个色令牌（与本仓既有的取舍一致）。
        static let stripAccent = ok
        /// 气泡（绿底）上的文字 —— 深色（复用浅底文字色）
        static let stripBubbleText = textOnLight
        /// 开关（关）的底色 —— 与面板底色同族，比它亮一档
        static let stripSwitchOff = panelElevated
    }

    // MARK: - 间距

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 34
    }

    // MARK: - 圆角

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: - 尺寸

    enum Size {
        // MARK: 快门排（原型 `.shutter-row` 80px + `.shutter` 60）—— 2026-09-17 按 docs/09 修正

        /// 快门直径。⚠️ 原来是 74，`docs/09` 尺寸修正表定为 **60**（原型 `.shutter-d: 60px`）
        static let shutterDiameter: CGFloat = 60
        /// 快门环宽。⚠️ 原来是 5，修正为 **3.5**（原型 `border: 3.5px`）
        static let shutterRingWidth: CGFloat = 3.5
        /// 快门内芯（白圆 / 拍照态）。
        /// 原型 `.shutter .core{ width:46px }` —— **固定值**，不再用"直径 − 14"推
        /// （那次是巧合等于 46；直径改成 60 后再推就错了）。
        static let shutterCoreSize: CGFloat = 46

        /// 录制态内芯（红色圆角方块）：**26pt**，圆角 **6pt**。
        ///
        /// ⚠️ **必须比拍照态内芯小一圈**，而且这不是审美问题，是几何硬约束：
        /// 圆角方块的**对角线**比圆长得多 —— 给它 46pt 时，四角到中心约 29.7pt，
        /// 而环带从 28.25pt 就开始 → 四个角会插进白色环带里（2026-09-17 真机 bug）。
        ///
        /// 26pt 的依据：
        ///   1. 沿用迁移前的比例 `直径 × 0.42`（60 × 0.42 = 25.2 → 取 26）
        ///   2. 半对角线 18.4pt，离环内沿（28.25）还有约 10pt 余量
        ///   3. 是拍照态内芯（46）的 57% —— 与系统相机"录制态明显小一圈"的观感一致
        ///
        /// 上限参考：30–32pt 仍安全；**≥40pt 必撞环**（半对角线 = 环内沿 28.25 时边长 39.95）。
        static let shutterRecordingCoreSize: CGFloat = 26
        /// 录制态内芯圆角：约边长的 23%（仍一眼是方块，不是球角）
        static let shutterRecordingCoreRadius: CGFloat = 6

        // MARK: 场景 · 风格条（原型 `.row-scenestyle`：折叠 36 / 展开 147）

        /// 折叠态 / 展开态整行高度。
        /// 展开的 147 是原型**第 5 轮修正**后的值：原 144 装不下内容（溢出 39px 压到图标行），
        /// 收起折叠胶囊后改为 147。内容深度 145.55 ≤ 147，余量只有 1.5pt —— 别再往上加内容。
        static let sceneStyleCollapsedHeight: CGFloat = 36
        static let sceneStyleExpandedHeight: CGFloat = 147

        /// 折叠态：胶囊（占满、高 28、圆角 14）+ 箭头按钮（28×28）
        static let sceneStyleCapsuleHeight: CGFloat = 28
        static let sceneStyleArrowSide: CGFloat = 28
        static let sceneStyleHorizontalPadding: CGFloat = 14

        /// 展开态：块 = 顶边框 0.5 + 上内边距 2 + 标题 14（两块）
        static let ssBlockTitleHeight: CGFloat = 14
        static let ssBlockTopPadding: CGFloat = 2
        /// 横滑条：间距 8、左右内边距 14（原型 `.strip`）
        static let stripSpacing: CGFloat = 8
        static let stripHorizontalPadding: CGFloat = 14
        /// 场景胶囊：高 28、左右内边距 14、圆角 14
        static let sceneChipHeight: CGFloat = 28
        static let sceneChipHorizontalPadding: CGFloat = 14
        /// 风格卡：宽 74 = 缩略图 74×50 + 名字 + 徽标（高 17）
        static let styleCardWidth: CGFloat = 74
        static let styleCardThumbHeight: CGFloat = 50
        static let styleCardSpacing: CGFloat = 3
        static let styleBadgeHeight: CGFloat = 17

        /// 风格名字的**钉死行高**。
        ///
        /// 为什么钉死：展开态 147pt 的内容深度账是
        /// `2 × (边框 0.5 + 上内边距 2 + 标题 14) + 场景胶囊 28 + 风格卡 86 = 147` —— **恰好贴合**。
        /// 名字的行高若交给字体度量（10.5pt 在 SwiftUI 里约 12.6pt，且随字体版本浮动），
        /// 这 1pt 上下的误差就可能把徽标顶出行外。钉死后整行是确定值，
        /// `tools/check_swift.js` 第 5 组按同一批令牌复算，恒等式不再漂。
        static let styleNameHeight: CGFloat = 13

        // MARK: 滤镜条（原型 `.row-filter`：展开 144px）—— 2026-09-18 #7

        /// 展开态整行高度（原型 `.screen.filter-on .row-filter{ height:144px }`）。
        ///
        /// ⚠️ **144 不是随便定的**（原型注释）：150px 时滤镜展开态的净可见取景只有
        /// 49.9%、破 50% 底线（自检抓的），144 → 50.6% ✓。别再往上加内容。
        ///
        /// 内容深度账（自检第 7 组按同批令牌复算）：
        /// `顶内边距 7 + 标题 14 + 间距 9 + 卡 84 + 卡内距 4 + 名字 11 = 129 ≤ 144`（余 15）。
        static let filterStripExpandedHeight: CGFloat = 144
        /// 面板顶部内边距（原型 `.row-filter .ss-block-title{ padding-top:7px }`）
        static let filterStripTopPadding: CGFloat = 7
        /// 标题行与卡条的间距（原型 `.row-filter .strip{ margin-top:9px }`）
        static let filterStripCardTopGap: CGFloat = 9
        /// 滤镜卡：缩略面 84×84、圆角 12（原型 `.filter-swatch{ 84px; radius:12px }`）
        static let filterCardSide: CGFloat = 84
        static let filterCardCornerRadius: CGFloat = 12
        /// 卡内：缩略面与名字的间距（原型 `.filter-card{ gap:4px }`）
        static let filterCardInnerSpacing: CGFloat = 4

        /// 滤镜名字的**钉死行高**（原型 `.filter-name{ font-size:10px; line-height:1.1 }` = 11px）。
        /// 钉死理由与 `styleNameHeight` 相同：144 的深度账不交给字体度量浮动。
        static let filterNameHeight: CGFloat = 11

        // MARK: 功能面板（原型 `.fn-panel` / `.fn-btn` / `.fn-link`）—— 2026-09-18 #10

        /// 面板贴边距离（原型 `left:8px; right:8px; bottom:8px`）
        static let functionPanelEdgeInset: CGFloat = 8
        /// 面板圆角（原型 `border-radius:22px`）
        static let functionPanelCornerRadius: CGFloat = 22
        /// 面板内边距（原型 `padding:16px 10px 6px`）
        static let functionPanelTopPadding: CGFloat = 16
        static let functionPanelHorizontalPadding: CGFloat = 10
        static let functionPanelBottomPadding: CGFloat = 6

        /// 网格：4 列，格宽 64，行距 14 / 列距 4（原型 `.fn-grid{ repeat(4,1fr); gap:14px 4px }`）
        static let functionGridColumns: Int = 4
        static let functionCellWidth: CGFloat = 64
        static let functionGridRowSpacing: CGFloat = 14
        static let functionGridColumnSpacing: CGFloat = 4

        /// 圆形图标底（原型 `.fn-ic{ width:54px; height:54px; border-radius:50% }`）
        static let functionGlyphCircleSide: CGFloat = 54
        /// 图标字形（原型 `.fn-ic svg{ 20px }` / `.fn-ic-text{ 11.5px }`）
        static let functionGlyphSize: CGFloat = 20
        static let functionGlyphTextSize: CGFloat = 11.5
        /// 圆形图标与标签的间距（原型 `.fn-btn{ gap:7px }`）
        static let functionCellInnerSpacing: CGFloat = 7

        /// 标签**钉死行高**（10.5pt ≈ 13）。
        /// 钉死理由同 `styleNameHeight`：面板高度账（自检第 9 组复算）不交给字体度量浮动。
        static let functionLabelHeight: CGFloat = 13

        /// foot 区：上间距 14、内边距 2/6/8（原型 `.fn-foot{ margin-top:14px; padding:2px 6px 8px }`）
        static let functionFootTopSpacing: CGFloat = 14
        static let functionFootTopPadding: CGFloat = 2
        static let functionFootBottomPadding: CGFloat = 8
        static let functionLinkHorizontalPadding: CGFloat = 6
        /// 链接行高（原型 `padding:9px 6px` × 2 + 12.5pt 行高 ≈ 15 → 33）
        static let functionLinkHeight: CGFloat = 33

        /// 功能面板总高（**派生值**，自检第 9 组按同一批令牌复算，与这里必须一致）：
        /// `上内边距 16 + 网格 (2 行 × (54 + 7 + 13) + 行距 14) + foot(14 + 0.5 + 2 + 33 + 8) + 下内边距 6`
        /// = 16 + 162 + 57.5 + 6 = **241.5**
        static var functionPanelHeight: CGFloat {
            let cellHeight = functionGlyphCircleSide + functionCellInnerSpacing + functionLabelHeight
            let grid = 2 * cellHeight + functionGridRowSpacing
            let foot = functionFootTopSpacing + 0.5 + functionFootTopPadding
                + functionLinkHeight + functionFootBottomPadding
            return functionPanelTopPadding + grid + foot + functionPanelBottomPadding
        }

        // MARK: 视频格式芯片与选择器（原型 `.fmt-chip` / `.fmt-menu` / `.fmt-opt`）—— #11

        /// 芯片：高 24 / 圆角 12 / 左右内边距 10（原型 `.fmt-chip{ height:24px; border-radius:12px; padding:0 10px }`）
        static let formatChipHeight: CGFloat = 24
        static let formatChipCornerRadius: CGFloat = 12
        static let formatChipHorizontalPadding: CGFloat = 10

        /// 选择器：宽 196 / 圆角 14 / 内边距 10,10,8（原型 `.fmt-menu{ width:196px; border-radius:14px; padding:10px 10px 8px }`）
        static let formatSelectorWidth: CGFloat = 196
        static let formatSelectorCornerRadius: CGFloat = 14
        static let formatSelectorHorizontalPadding: CGFloat = 10
        static let formatSelectorTopPadding: CGFloat = 10
        static let formatSelectorBottomPadding: CGFloat = 8
        /// 两组之间的间距（原型 `.fmt-menu{ gap:10px }`）
        static let formatSelectorGroupSpacing: CGFloat = 10
        /// 同一组内选项之间的间距（原型 `.fm-opts{ gap:5px }`）
        static let formatOptionSpacing: CGFloat = 5
        /// 选项按钮：高 28 / 圆角 9（原型 `.fmt-opt{ height:28px; border-radius:9px }`）
        static let formatOptionHeight: CGFloat = 28
        static let formatOptionCornerRadius: CGFloat = 9
        /// 分组标题的下内边距（原型 `.fm-label{ padding:0 2px 4px }`）
        static let formatGroupLabelBottomPadding: CGFloat = 4
        /// 底注：上分隔线 + 上内边距 7（原型 `.fm-note{ border-top:.5px solid; padding-top:7px }`）
        static let formatNoteTopPadding: CGFloat = 7

        /// 选择器定位：顶栏下沿 + **6**，距右 **14**（原型 `right:14px; top:92px`；
        /// 92 = 状态栏 30 + 顶栏 56 + 6。Swift 侧用"顶栏下沿 + gap"表达，不写死 92）
        static let formatSelectorTopGap: CGFloat = 6
        static let formatSelectorTrailingInset: CGFloat = 14

        /// ⤢ 放大态的「前置 / 设置」镜像按钮（原型 `.icon-item.mirror{ 50×44 }`，图标 19px）

        /// 放大态的快门排高度（80 → **106**）
        static let shutterRowZoomHeight: CGFloat = 106
        /// 放大态的快门缩放（1 → **1.3**；原型 `--shutter-scale`）
        static let shutterZoomScale: CGFloat = 1.3
        /// 放大态取景器卡片的圆角（原型 `viewport{ border-radius:18px }`）
        static let previewCardRadius: CGFloat = 18

        /// 底栏**最下沿到安全区之间**的总内边距 = **20pt（两层各 10）**。
        ///
        /// ⚠️ **这个数是两层内边距之和，不是一层**：
        ///   1. `CameraView.cameraContent` 外层 `VStack` 的 `.padding(.vertical, Spacing.sm)` → 10
        ///   2. `CameraView.bottomArea` 自己的 `.padding(.bottom, Spacing.sm)` → 10
        ///
        /// 为什么单独立一个令牌：任何"从底部往上量"的浮层（放大态取景器卡片的底边）
        /// 都必须吃这一整份，而不是自己写 `+ Spacing.sm`。
        /// 2-5b 就是按"只有一层 10pt"算的，卡片底边比快门排上沿低了 10pt；
        /// 更早那次则是焦段条浮层漏算了整条图标行（2026-09-17 真机截图取证，见 `CameraView`）。
        /// 自检第 7 组会校验它 = 2 × `Theme.Spacing.sm`，改内边距时不会漏改这里。
        static let bottomStackBottomPadding: CGFloat = 20

        /// 放大态的「前置 / 设置」镜像按钮（原型 `.icon-item.mirror{ 50×44 }`，图标 19px）
        static let mirrorButtonWidth: CGFloat = 50
        static let mirrorButtonHeight: CGFloat = 44
        static let mirrorGlyphSize: CGFloat = 19
        /// 快门排整条高度（原型 `.shutter-row{ height:80px }`）
        static let shutterRowHeight: CGFloat = 80
        /// 快门排左右内边距（原型 `padding: 0 18px`）
        static let shutterRowHorizontalPadding: CGFloat = 18

        /// 相册缩略图边长。⚠️ 原来是 52，修正为 **50**（原型 `.thumb{ 50px }`）
        static let thumbnailSide: CGFloat = 50

        /// ⤢ 放大布局按钮：36×36 圆（原型 `.zoom-btn{ width:36px }`），字形 15px
        static let zoomButtonSide: CGFloat = 36
        static let zoomGlyphSize: CGFloat = 15
        /// ⤢ 与快门视觉边缘的间距（原型 `--zoom-gap: 12px`）。
        /// 位置公式：`屏幕中线 + 快门视觉半径 + 本值 + 自身半径` —— 全用令牌表达，
        /// 2-5b 把快门放大 1.3 倍时把半径乘上 scale，⤢ 自动右移（与快门同曲线）。
        static let zoomGap: CGFloat = 12

        /// 风格预览方块：50×50、外圈圆角 10、渐变描边内衬 2、内层圆角 8
        /// （原型 `.style-thumb{ 50px; radius:10px; padding:2px }` + `.inner{ radius:11px }`；
        ///  内层圆角按几何应为 10 − 2 = 8，原型的 11 视觉上与 8 无差，取几何正确值）
        static let styleThumbSide: CGFloat = 50
        static let styleThumbCornerRadius: CGFloat = 10
        static let styleThumbInnerCornerRadius: CGFloat = 8
        static let styleThumbBorderPadding: CGFloat = 2

        // MARK: 模式条（原型 `.mode-tab` 26px）—— 2026-09-17 第九轮定稿

        /// 模式条单档的**视觉**高度（原型 `.mode-tab{ height:26px }`，此前用的是 34）
        static let modeSelectorHeight: CGFloat = 26

        /// 模式条相邻两档的**视觉**间距 = 每档两端各一半的透明内边距。
        ///
        /// 原型是 `.mode-tabs{ gap:10px }` 且档位 `padding: 0`；这里把间距改由**热区内边距**
        /// 产生（`padding(.horizontal, 间距/2)`），因为原型那种写法在真机上可点区域只剩
        /// 文字本身（「照片」约 23×26pt）。
        ///
        /// ⚠️ **别把"档间距"和"内边距"叠加**。曾经因为写成"内边距 5 + `HStack` spacing 10"，
        /// 实际视觉间距变成 20pt 而文档里记的是 10pt —— 算宽度时整笔账都对不上。
        /// 现在 `HStack` 的 spacing 固定为 0，间距只有这一个来源。
        static let modeSelectorSpacing: CGFloat = 18

        /// 窄屏降档时的档间距（375pt 机型用）
        static let modeSelectorCompactSpacing: CGFloat = 12

        /// 模式条单档的**命中下限**（HIG 44×44）。
        ///
        /// 高度 44 靠"行高 30 + 上下各溢出 7pt"实现（顶栏行高是固定的，子视图溢出不影响布局）：
        ///   - **上溢 7pt** 只到「安全区下沿 + 3pt」（顶栏内容距安全区还有 10pt padding）
        ///     → 碰不到状态栏，也不会与系统的下拉手势打架
        ///   - **下溢 7pt** 落在副行**中段的空白**里（副行只有左右两颗胶囊，中段约 230pt 全空；
        ///     模式条热区跨度约 202pt ⊂ 那段空白）
        /// 所以这个溢出**不抢任何控件的点击**。
        ///
        /// ⚠️ **但几何上确实与副行的胶囊重叠，当前靠绘制顺序侥幸无害。**
        /// 真机实测（iPhone 16 Pro / iOS 26.6，2026-09-17）：
        ///   模式条热区 `x[100, 302] × y[65, 109]`
        ///   存储胶囊   `x[290, 385] × y[103, 127]`
        ///   重叠       `x[290, 302] × y[103, 109]` = **12 × 6pt**
        ///   左侧「影调预览」胶囊右端 99.0 vs 热区左边界 100.0 → **仅差 1.0pt**
        /// 之所以现在没出事：副行在 `TopBarView` 里排在主行**之后**绘制，重叠区归胶囊 ——
        /// 也就是说用户点到的、看到的是一致的。
        /// **下面任一改动都会把它变成真 bug**（表现为"点存储胶囊却切了拍摄模式"）：
        ///   ① 把 `secondaryRow` 挪到 `mainRow` 之前绘制
        ///   ② 给任意一行加 `.zIndex(...)`
        ///   ③ 把两行拆进不同容器 / 改用 `overlay` 叠加
        /// 改这些之前**必须重测这一块**。（另一个彻底解法：把下溢改成 0、上溢 14，
        /// 代价是最上面 4pt 探进状态栏区域 —— 需要时再评估。）
        static let modeTabMinHitWidth: CGFloat = 44
        static let modeTabHitHeight: CGFloat = 44

        /// 顶栏主行 `HStack` 的间距。
        ///
        /// **必须是 0**，且做成令牌是为了让自检能读到它 —— 中段可用宽度的公式是
        /// `屏宽 − 两侧内边距 − 两侧块宽 − 两侧行间距`，这个值一旦不是 0，
        /// 中段就会少掉 2 倍它，393/390pt 机型会当场溢出（2026-09-17 真实踩过）。
        /// 视觉间距不靠它，靠两侧块**自己内部的空白**（电平表点左对齐、三图标右对齐）。
        static let topBarMainRowSpacing: CGFloat = 0

        /// 模式条「实况」档的同心圆图标尺寸。
        /// 原型是 18（配 11.5pt 文字）；字号提到 13 之后按比例提到 **20**，视觉重量才配得上。
        static let modeSelectorGlyphSize: CGFloat = 20

        // MARK: 焦段条（原型 `.row-focal` 44px + `.focal-pill` 44×30）

        /// 焦段条整条高度（原型 `.row-focal{ height:44px }`）
        static let focalStripHeight: CGFloat = 44
        /// 药丸视觉尺寸（原型 `.focal-pill{ width:44px; height:30px }`）
        static let focalPillWidth: CGFloat = 44
        static let focalPillHeight: CGFloat = 30
        /// 药丸之间的间距（原型 `.focal-strip{ gap:9px }`）
        static let focalStripSpacing: CGFloat = 9
        /// 药丸内部：刻度标记高 7、标记与文字间距 2（原型 `gap:2px`）
        static let focalMarkHeight: CGFloat = 7
        static let focalPillInnerSpacing: CGFloat = 2
        /// 刻度标记里每根小竖条的宽与间距（原型 `.mark i{ width:1.5px }` + `gap:1.5px`）
        static let focalMarkBarWidth: CGFloat = 1.5
        static let focalMarkBarSpacing: CGFloat = 1.5

        /// 药丸标签字号。
        ///
        /// ⚠️ **刻意偏离原型**：原型是 `8.5px`（在 390px 宽的 CSS 稿上定的），真机上偏小
        /// —— 与模式条 11.5 → 13 是同一个理由。
        ///
        /// ⚠️ **但内宽只剩 2pt，不宽裕**：药丸内宽 44pt，真机实测最长的「120 mm」
        /// 墨迹宽 **40.0pt**（其余三档 33.0 / 38.3 / 34.7），内宽已用到 **91%**。
        /// **再往上调字号之前必须先加宽药丸** —— 11.5pt 时「120 mm」≈ 43.8pt 就贴边了。
        /// 实测表见 `Camera/UI/FocalStripView.swift` 的类型注释。
        static let focalLabelSize: CGFloat = 10.5

        // MARK: 底部图标行（原型 `.params-closed-bar` 44px + `.icon-item`）

        /// 图标行整条高度（原型 `.params-closed-bar{ height:44px }`）
        static let toolRowHeight: CGFloat = 44
        /// 图标字形尺寸（原型 `.icon-item svg{ width:17px }`）
        static let toolRowGlyphSize: CGFloat = 17
        /// 「感光」档的文字字形尺寸（原型 `.icon-item .glyph{ font-size:11px; font-weight:700 }`）
        static let toolRowGlyphTextSize: CGFloat = 11
        /// 图标与文字的间距（原型 `.icon-item{ gap:3px }`）
        static let toolRowInnerSpacing: CGFloat = 3

        /// 图标行标签字号。
        ///
        /// ⚠️ **刻意偏离原型**（8.5 → 10.5），理由与焦段条标签相同。
        /// 单元宽 = (370 − 2×6) / 7 ≈ 51.1pt，最长的四字标签「快门速度」「曝光补偿」
        /// 在 10.5pt 下约 42pt —— 放得下，且单元宽本身已 ≥ HIG 的 44pt 下限。
        static let toolRowLabelSize: CGFloat = 10.5

        // MARK: 参数刻度条（B2 · 模块 #9）
        //
        // 原型：`.strip-panel` + `.sp-bubble` / `.sp-tick` / `.sp-pointer` / `.sp-auto`（B2b 落地）

        /// 刻度条面板高度。
        ///
        /// ⚠️ **84pt，不是原型的 96** —— 净值是**净可见账卡出来的上限**（`docs/16` 第三.2 节，
        /// 分母取**安全区高**，用户 2026-09-19 拍板 ①）。
        ///
        /// 为什么是 84 而不是 88（初稿）：`check_swift` 第 12 组⑩ 逐机型复算后，
        /// **844 机型**（iPhone 14）在"刻度条展开"态只剩 **50.3%（≈2pt 余量）** ——
        /// 本项目在 2pt 余量上吃过亏（`docs/11` 那个 50.2%），所以主动压到 84 换 **6pt 余量**。
        /// 三个机型在刻度条展开态的净可见：874 → 53.7% / 852 → 52.3% / 844 → 51.5%。
        ///
        /// 内部按比例上移：气泡 0–22 / 开关 10–39 / 刻度 46–68 / 数字 69–82（不重叠）。
        static let paramStripHeight: CGFloat = 84
        /// 气泡高（原型 `.sp-bubble{ height:22px }`）
        static let paramStripBubbleHeight: CGFloat = 22
        /// 气泡字号（原型 `font-size:12.5px`）
        static let paramStripBubbleFontSize: CGFloat = 12.5
        /// 刻度线宽（原型 `.sp-tick{ width:1.5px }`）
        static let paramStripTickWidth: CGFloat = 1.5
        /// 普通刻度线高（原型 `height:10px`）
        static let paramStripTickHeight: CGFloat = 10
        /// **中间档**刻度线高（原型 `.sp-tick.mid{ height:15px }`）
        ///
        /// 三档高度 10 / 15 / 22 全部来自原型 CSS；刻度**底边对齐**（共用
        /// `paramStripTickBottomInset` 那条基线），所以"高"直接表达层级。
        static let paramStripTickMidHeight: CGFloat = 15
        /// 主刻度 / 预设刻度高（原型 `.sp-tick.major` / `.preset{ height:22px }`）
        static let paramStripTickMajorHeight: CGFloat = 22
        /// 刻度线距面板底部（原型 `bottom:20px`；压到 84 高后取 16）
        static let paramStripTickBottomInset: CGFloat = 16
        /// 刻度下的数字：字号（原型 `font-size:10.5px`）+ 距底（原型 `bottom:2px`）
        static let paramStripNumberFontSize: CGFloat = 10.5
        static let paramStripNumberBottomInset: CGFloat = 2
        /// 指针：三角半宽 6 × 高 8（原型 `::before`）+ 竖线 1.5（原型 `::after`）
        static let paramStripPointerTriangleHalfWidth: CGFloat = 6
        static let paramStripPointerTriangleHeight: CGFloat = 8
        static let paramStripPointerLineWidth: CGFloat = 1.5
        /// 指针三角距面板顶部（原型 `top:24px`；88 高版取 22）
        static let paramStripPointerTopInset: CGFloat = 22
        /// 两端渐隐遮罩宽（原型 `mask-image: … 40px …`）
        static let paramStripEdgeMask: CGFloat = 40
        /// 刻度条两端留白（原型 `SP.pad = 30`）
        static let paramStripEdgePadding: CGFloat = 30
        /// 右端开关：让位槽宽（原型 `.sp-clip{ right:64px }` —— **指针与气泡的定位基准**，别在别处再写一遍）
        static let paramStripSwitchGutter: CGFloat = 64
        /// 开关本体（原型 `.sw{ width:47px; height:29px }` + 滑块 `25px`）
        static let paramStripSwitchWidth: CGFloat = 47
        static let paramStripSwitchHeight: CGFloat = 29
        static let paramStripSwitchKnob: CGFloat = 25
        /// 开关下方标签：字号（原型 `.sp-auto .t{ font-size:10px }`）+ 距顶（原型 `top:18px` → 88 版取 10）
        static let paramStripSwitchLabelFontSize: CGFloat = 10
        static let paramStripSwitchTopInset: CGFloat = 10
        /// 拖动方向闸门死区（与 `ParameterSlider` 同量级）
        static let paramStripDirectionDeadZone: CGFloat = 6

        // MARK: 圆盘（EV / 对焦两盘共用 · #8 · B3b 起改名 dial*）
        //
        // 原型 `--fd-*` 那组（对焦盘与 EV 盘共用一套组件，两盘互为反向镜像）。
        // ⚠️ 半径体系写在 400 坐标系（原型 SVG viewBox 400），随容器等比缩放 ——
        //    改 `dialSize` 一个值，刻度/数字/指针/高亮段自动同步（原型同款防脱节设计）。

        /// 圆盘直径（原型 `--fd-size: 246px`；246 是"圆盘组留在屏内"的上限）
        static let dialSize: CGFloat = 246
        /// 数值框宽（**固定宽**：`+3.0 EV` / `0.56` / `∞` 各形态都能放下且不跳宽 ——
        /// 固定宽让"靠盘缘钉 8pt"的定位不依赖文本测量）
        static let dialValueBoxWidth: CGFloat = 92
        /// 数值框与圆盘边缘的间隙（原型 `calc(50% + size/2 + 8px)` 里的 8）
        static let dialValueBoxGap: CGFloat = 8
        /// 数值框高（原型 padding 4×2 + 字 ≈ 29，取 30）
        static let dialValueBoxHeight: CGFloat = 30
        /// 数值框字号（原型 `.ev-val{ font-size:16px }`，等宽数字）。
        /// ⚠️ 2026-09-19 用户拍板缩小到 **13**（截图反馈"+0.0 EV 偏大"；同轮刻度数字
        /// 修回原型口径 ≈8pt = 13×246/400）—— 需要再调只动这一个数。
        static let dialValueFontSize: CGFloat = 13
        /// 盘心标签字号（原型 `.ev-hub .t{ font-size:13px }`）
        static let dialHubFontSize: CGFloat = 13
        /// 盘心图标框（22pt，自画 ⊖ / ◎）
        static let dialHubIconSize: CGFloat = 22

        /// 盘下「自动对焦」开关行与圆盘的间距（原型 `--fd-gap:12px`）
        static let dialAutoSwitchGap: CGFloat = 12
        /// 开关行高（原型 `--fd-auto-h:29px`，即 `.sw` 通用开关的高）
        static let dialAutoSwitchHeight: CGFloat = 29
        /// 开关宽（原型 `.sw{ width:47px }`）
        static let dialAutoSwitchWidth: CGFloat = 47
        /// 开关滑块直径（原型 `.sw` 内圆钮）
        static let dialAutoSwitchKnob: CGFloat = 25
        /// 开关行标签字号（原型 `.fd-auto{ font-size:12.5px }`）
        static let dialAutoSwitchLabelFontSize: CGFloat = 12.5

        /// 全手动档退出 → 切回虚拟多摄的**防抖时长**（`docs/20` 2.2b，量级守卫 [1,5]s）
        static let dialRevertDebounce: CGFloat = 2.0

        /// 换设备模糊转场：**淡入**时长（预检 ⑧ 顺序触发第一段；量级守卫 [0.1,0.5]s）。
        /// 🔴5 拍板 A2（极短转场）：0.15 → **0.10**（下限）—— 手动参数切换"瞬发"体验；
        /// ⚠️ 换设备硬耗时 ~0.6-0.75s（AVFoundation input 切换）被模糊盖住，压不进 0.3-0.5s。
        static let dialBlurIn: CGFloat = 0.10
        /// 换设备模糊转场：**淡出**时长（A2 压缩：0.25 → 0.15）
        static let dialBlurOut: CGFloat = 0.15

        // MARK: 取景器辅助线（三分构图线）

        /// 三分线粗细。
        ///
        /// ⚠️ **0.5 → 1.0（2026-09-17 真机反馈"网格线太细"）**。
        /// 0.5pt 在 3x 屏上是 1.5 物理像素，被抗锯齿摊成两条半透明的边，
        /// 在明亮画面上几乎看不见（真机截图核对过）。1.0pt 恰好落在 3 物理像素上，
        /// 边缘清晰，同时透明度和原来同档，不会抢戏。
        static let gridLineWidth: CGFloat = 1.0

        // MARK: 顶栏（两行）
        //
        // 2026-09-17 起顶栏是**两行**（原型 `.topbar{ height:56px }`）：
        //   主行 30 = L/R 电平表 + 模式条 + 右上三图标
        //   副行 26 = 「影调预览」胶囊 + 右「剩余存储」胶囊

        static let topBarRow1Height: CGFloat = 30
        static let topBarRow2Height: CGFloat = 26
        static let topBarHeight: CGFloat = 56
        /// 顶栏两行内、以及行内各块之间的间距（原型 `.tb-row1{ gap:8px }`）
        static let topBarRowSpacing: CGFloat = 8

        /// 顶栏单侧宽度 = 右上三图标的自然宽 = 3 × 24.33 ≈ 73（原型 `--tb-side-w: 73px`）。
        ///
        /// **左右必须等宽**，模式条的盒中心才等于屏幕中心 —— 这是网页原型
        /// `--tb-side-w` 的做法（原型注释：「把两侧块钉成同宽，盒中心回到屏中心」）。
        ///
        /// 真机实测与推算（iPhone 16 Pro / iOS 26.6，屏宽 402pt、顶栏可用宽 370pt）：
        ///   - 左侧电平表块与右侧图标块各 73pt → 中段 370 − 146 = **224pt**
        ///     （前提：主行 `HStack` 的 `spacing` 必须为 **0**，见 `TopBarView.mainRow`；
        ///      给了间距就不止 224 了，393/390 机型会当场溢出）
        ///   - 模式条 **202pt**（字号 13、档间距 18、每档命中下限 44×44）
        ///     → 中段 224 装得下，**两侧各余约 11pt**
        ///
        /// 模式条宽度的拆解（模型见 `docs/08` 三.2，已用两处实测标定、误差 <1%）：
        ///   照片 44 + 实况 44 + Log 实况 70 + 视频 44 = 202
        ///   其中「Log 实况」的 70 不是命中下限 44，而是内容（52pt）+ 两端各 9pt
        ///   —— 它本来就比 44 宽，热区跟着内容走。
        ///
        /// 窄屏：375pt 机型（SE / mini）中段只有 197pt → `ModeSelector` 用 `ViewThatFits`
        /// 自动降到字号 12 + 档间距 12（总宽 191.6pt）。**这是 ModeSelector 内部的事，
        /// 两侧 73pt 不跟着变**，所以模式条在任何机型上都保持居中。
        ///
        /// ⚠️ **73 / 224 / 140 这组数字是「4 档、三图标、iPhone 16 Pro」这个形态下的结论。**
        /// 三件事会让它失效，改完必须重新测量并更新本注释：
        ///   1. 档位数变化（加第 5 档），或档位字号/图标尺寸变化；
        ///   2. 右上图标数量变化（模块 #10 的 ⠿ 面板、模块 #11 的格式芯片都会动这一格
        ///      —— 格式芯片顶替三图标时同样要钉成 73pt 宽，否则模式条会跟着漂）；
        ///   3. 换机型（iPhone SE 375pt 宽 → 可用 343 → 中段 197，仍容得下 140，可以，但要重测）。
        ///
        /// ⚠️ 顺带记一条**几何上的硬约束**：Apple HIG 建议 44×44pt 触控目标，
        /// 而这里每个图标只有约 24pt 宽。想做到 44pt 就要把单侧加到 132pt（3×44），
        /// 中段只剩 370 − 264 = 106pt < 模式条 140pt → **必然溢出**。
        /// 也就是说「模式条居中」与「三图标各 44pt」在 402pt 屏宽上不可兼得，
        /// 现在选的是保版式、把命中区从原型的 17×17 提到 24.33×30（且互不重叠）。
        static let topBarSideWidth: CGFloat = 73

        /// 顶栏图标按钮的单元宽度 = 73 / 3 ≈ 24.33。
        /// 三个单元**间距为 0** 地拼起来正好等于侧宽 —— 这样命中区各自独立、互不重叠
        /// （用负间距或 `contentShape` 外扩都会让相邻按钮的命中区交叠，点谁都可能错）。
        static let topBarIconCellWidth: CGFloat = topBarSideWidth / 3
        /// 顶栏图标字形尺寸（原型 `.tb-icon svg{ width:15px }`）
        static let topBarIconGlyphSize: CGFloat = 15

        /// 副行胶囊（原型 `.chip{ height:24px; padding:0 10px; font-size:11px; gap:6px }`）
        static let chipHeight: CGFloat = 24
        static let chipGlyphSize: CGFloat = 11
        static let chipHorizontalPadding: CGFloat = 10
        static let chipIconSpacing: CGFloat = 6

        /// 副行 L/R 电平表：每声道 8 个点（原型 `.levels .dots i{ 3.5px; gap:2px }`）
        static let levelDotSide: CGFloat = 3.5
        static let levelDotSpacing: CGFloat = 2

        /// Live Photo 角标（黄底同心圆）本体的边长与其中图标的边长。
        ///
        /// 对齐网页原型 `.live-badge`：22×22 黄底圆 + 14×14 图标（图标由
        /// `LivePhotoCircleIcon` 自绘，设计坐标系 24 单位，按 size/24 等比缩放）。
        static let liveBadgeSide: CGFloat = 22
        static let liveBadgeIconSize: CGFloat = 14
    }

    // MARK: - 字体

    enum Typography {
        static let value = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let label = Font.system(size: 11, weight: .medium, design: .rounded)
        static let toast = Font.system(size: 13, weight: .medium, design: .rounded)
        static let mono = Font.system(size: 11, design: .monospaced)

        /// 模式条档位文字。原型 `.mode-tab{ font-size:11.5px; font-weight:600 }`、
        /// 选中态 `.on{ font-weight:700 }`。做成函数是因为"选中加粗"没法用同一个 Font 表达。
        ///
        /// **2026-09-17 由 11.5 提到 13。** 11.5 是原型在 390px 宽的 CSS 稿上定的数，
        /// 真机上偏小。13pt 是能在**所有现行机型**（屏宽 ≥390pt）都放下的最大档：
        /// 宽度模型（`docs/08` 三.2）算出 402pt 机型其实能容到 15pt、393/390 机型到 14pt，
        /// 但 14 在 390 机型只剩 2.4pt 余量，太紧 —— 取 13 给窄屏留余量。
        static let modeTitleSize: CGFloat = 13
        /// 窄屏降档用：375pt 机型（SE / mini）的中段只有 197pt，13pt 那版 202pt 放不下。
        static let modeTitleCompactSize: CGFloat = 12

        static func modeTitle(selected: Bool, compact: Bool = false) -> Font {
            .system(
                size: compact ? modeTitleCompactSize : modeTitleSize,
                weight: selected ? .bold : .semibold,
                design: .rounded
            )
        }

        /// 顶栏副行胶囊文字（原型 `.chip{ font-size:11px; font-weight:600 }`）
        static let chip = Font.system(size: 11, weight: .semibold, design: .rounded)
        /// 电平表的声道字母 L / R（原型 `.levels .ch{ font-size:8px; font-weight:700 }`）
        static let levelChannel = Font.system(size: 8, weight: .bold, design: .rounded)

        // MARK: 场景 · 风格条（2026-09-17 #6）

        /// 折叠胶囊文字（原型 `.ss-capsule{ font-size:11.5px }`）
        static let ssCapsule = Font.system(size: 11.5, weight: .regular, design: .rounded)
        /// 块标题（原型 `9.5px` → **11**；9.5 在真机上看不清，这是本件唯一的字号上调之一）
        static let ssBlockTitle = Font.system(size: 11, weight: .regular, design: .rounded)
        /// 场景胶囊（原型 `.scene-chip{ font-size:12px }`）
        static let sceneChip = Font.system(size: 12, weight: .regular, design: .rounded)
        /// 风格卡名字（原型 `.style-name{ font-size:10.5px; font-weight:600 }`）
        static let styleName = Font.system(size: 10.5, weight: .semibold, design: .rounded)
        /// 风格卡参数徽标（原型 `8.5px` → **10**）
        static let styleBadge = Font.system(size: 10, weight: .regular, design: .rounded)

        // MARK: 滤镜条（2026-09-18 #7）

        /// 滤镜卡名字（原型 `.filter-name{ font-size:10px }`；选中态由调用点 `.fontWeight(.semibold)`）
        static let filterName = Font.system(size: 10, weight: .regular, design: .rounded)

        // MARK: 功能面板（#10，2026-09-18）

        /// 面板格标签（原型 `.fn-t{ font-size:10.5px }`）
        static let functionLabel = Font.system(size: 10.5, weight: .regular, design: .rounded)
        /// 圆形图标里的**文字字形**（原型 `.fn-ic.fn-ic-text{ font-size:11.5px; font-weight:700 }`）
        /// —— 用于「画幅比」（`4:3`）、「倒计时」（`关`）这类没有合适符号的格子
        static let functionGlyphText = Font.system(size: 11.5, weight: .bold, design: .rounded)
        /// foot 区的「简易模式」链接（原型 `.fn-link{ font-size:12.5px }`）
        static let functionLink = Font.system(size: 12.5, weight: .regular, design: .rounded)
        /// foot 区右侧箭头（原型 `.fn-arr{ font-size:14px }`）
        static let functionLinkArrow = Font.system(size: 14, weight: .regular, design: .rounded)

        // MARK: 视频格式芯片与选择器（#11）

        /// 芯片文字（原型 `.fmt-chip{ font-size:12px; font-weight:700 }`）
        static let formatChip = Font.system(size: 12, weight: .bold, design: .rounded)
        /// 选择器分组标题（原型 `.fm-label{ font-size:10px }`）
        static let formatGroupLabel = Font.system(size: 10, weight: .regular, design: .rounded)
        /// 选项按钮（原型 `.fmt-opt{ font-size:11.5px; font-weight:600 }`）
        static let formatOption = Font.system(size: 11.5, weight: .semibold, design: .rounded)
        /// 底注（原型 `.fm-note{ font-size:9.5px }`）
        static let formatNote = Font.system(size: 9.5, weight: .regular, design: .rounded)
    }
}
