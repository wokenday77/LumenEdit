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
    }
}
