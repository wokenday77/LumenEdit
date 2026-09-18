import SwiftUI

/// 相机主页。
///
/// 布局说明（为什么不用 `.ignoresSafeArea()` 做全屏取景）：
/// 如果让预览层铺到屏幕物理边缘，它和上面浮层控件的坐标系就不一致了，
/// 对焦方框会整体偏掉一个安全区高度——而且这个偏差在刘海/灵动岛机型上各不相同。
/// 现在的做法是：**背景纯黑铺满屏幕，预览占安全区**，对焦方框与预览处于同一坐标系，
/// 一一对应不会有偏差。代价是上下各留一条黑边，在深色相机界面里观感自然。
struct CameraView: View {

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var viewModel = CameraViewModel()
    @State private var isHUDExpanded = false

    // MARK: 上划 / 下划手势状态（#7 滤镜条）

    /// 取景器容器高度（几何判定用，经 PreferenceKey 读出，不参与布局）
    @State private var previewHeight: CGFloat = 0
    /// 本次拖动的起点时刻（原型 dt ≤ 800ms 的"长按后拖动不算滑动"守卫）
    @State private var swipeGestureStart: Date?

    var body: some View {
        ZStack {
            Theme.Palette.canvas
                .ignoresSafeArea()

            switch env.permissions.camera {
            case .notDetermined:
                PermissionPromptContent {
                    Task { await viewModel.requestCameraPermission() }
                }

            case .authorized, .limited:
                cameraContent

            case .denied, .restricted:
                PermissionDeniedContent {
                    viewModel.openSystemSettings()
                }
            }
        }
        .onAppear {
            viewModel.attach(env)
            Task { await viewModel.onAppear() }
        }
        .onDisappear {
            viewModel.onDisappear()
        }
    }

    // MARK: - 取景器

    /// 预览层：预览 + 三分线 + 对焦框，**三者同一坐标系**。
    ///
    /// ⤢ 放大态时整层"卡片化"：上下收（顶到顶栏下沿、底到快门排上沿）、圆角 18，
    /// **左右不内缩**（用户反馈过"卡片比常态窄"）。原型 `.zoom-on .viewport` 规则。
    ///
    /// ⚠️ 三分线与对焦框在同一个被裁剪的容器里，坐标系随之收缩 ——
    /// 所以**不要**单独给它们加 inset（那会让对焦框整体偏）。
    private var previewLayer: some View {
        ZStack {
            PreviewView(
                session: env.session.session,
                onFocusTap: { viewPoint, devicePoint in
                    viewModel.focusTapped(viewPoint: viewPoint, devicePoint: devicePoint)
                },
                onHardwareShutter: {
                    viewModel.shutterTapped()
                },
                isShutterEnabled: !viewModel.isSaving
            )
            .accessibilityLabel("取景器")
            .accessibilityHint("点按画面任意位置对焦")

            // 三分构图线：顶栏「网格」图标控制。与预览同一坐标系、不接收触摸，
            // 所以"点按画面任意位置对焦"照样穿透过去。
            if env.showGrid {
                GridOverlayView()
            }

            // 与预览同一坐标系，直接用视图坐标绘制
            FocusIndicatorView(point: viewModel.focusPoint, token: viewModel.focusToken)
        }
        .clipShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
        .padding(.top, previewTopInset)
        .padding(.bottom, previewBottomInset)
        // 用弹簧动画而不是 .transition(.move)：后者会在动画期间挤压预览（docs/03 §7.3）
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.isZoomOn)
    }

    private var previewCornerRadius: CGFloat {
        viewModel.isZoomOn ? Theme.Size.previewCardRadius : 0
    }

    /// 卡片顶 = 顶栏下沿（内容距安全区 10 + 顶栏 56）
    private var previewTopInset: CGFloat {
        viewModel.isZoomOn ? Theme.Spacing.sm + Theme.Size.topBarHeight : 0
    }

    /// 卡片底 = 快门排上沿（放大态快门排 106 + 底栏下内边距**两层**共 20）
    ///
    /// ⚠️ **必须用 `bottomStackBottomPadding`，不要自己写 `+ Spacing.sm`**：
    /// 底栏到安全区之间有两层各 10pt 的内边距（外层 `VStack` 的 `.padding(.vertical, _)`
    /// + `bottomArea` 自己的 `.padding(.bottom, _)`）。2-5b 只算了其中一层，
    /// 卡片底比快门排上沿低了 10pt（整张卡片多出 10pt 高）。
    private var previewBottomInset: CGFloat {
        viewModel.isZoomOn ? Theme.Size.shutterRowZoomHeight + Theme.Size.bottomStackBottomPadding : 0
    }

    // MARK: - 滤镜条（#7）与上划 / 下划手势

    /// 滤镜条当前是否真的展开。
    ///
    /// ⤢ 放大态**强制隐藏**（原型 `.screen.zoom-on .row-filter{ height:0 }`，否则会
    /// 在放大卡片上叠出鬼影）：状态保留、只隐藏 —— 退出放大态即恢复，不重置选择。
    private var isFilterStripShown: Bool {
        viewModel.isFilterStripExpanded && !viewModel.isZoomOn
    }

    /// 手势几何参数 —— 对齐原型 `bindSwipe` 的实测口径，不要凭感觉改：
    /// `minimumDistance` 24（SwiftUI 侧起手门槛，低于它就是点按对焦）；
    /// 位移 34 / 时长 0.8s / 起点 55% 以下 / 纵向为主，全是原型踩坑后定的数。
    private static let swipeActivationDistance: CGFloat = 24
    private static let swipeMinTravel: CGFloat = 34
    private static let swipeMaxDuration: TimeInterval = 0.8
    /// 起点必须在容器下方 45% 区域内（原型 `clientY > height × 0.55`）——
    /// 上半屏的纵向拖动（比如擦一下画面）不该呼出浮层。
    private static let swipeStartRegionRatio: CGFloat = 0.55

    /// 上划呼出滤镜条（再上划呼出场景·风格）、下划逐级收起。
    ///
    /// ⚠️ 挂在 **previewLayer** 上而不是整个页面：底栏栈是 ZStack 里绘制在上的兄弟视图，
    /// 从横滑条 / 药丸 / 图标行上起手的拖动根本到不了这个手势 ——
    /// 原型靠元素排除清单（`.strip` / `.focal-strip` / …）解决的误触，这里结构上就不存在。
    private var viewfinderSwipeGesture: some Gesture {
        DragGesture(minimumDistance: Self.swipeActivationDistance)
            .onChanged { _ in
                // 记一次起点时刻；同一次拖动只记一次
                if swipeGestureStart == nil { swipeGestureStart = Date() }
            }
            .onEnded { value in
                defer { swipeGestureStart = nil }

                // 长按后拖动不算滑动（原型 dt ≤ 800ms）
                guard let start = swipeGestureStart,
                      Date().timeIntervalSince(start) <= Self.swipeMaxDuration else { return }

                // 起点必须在取景器下半区（原型同款 55% 线）
                guard value.startLocation.y > previewHeight * Self.swipeStartRegionRatio else { return }

                let dy = value.translation.height
                // 位移不够，或**横向为主**（是在横滑条上滑动）→ 不算呼出 / 收起
                guard abs(dy) >= Self.swipeMinTravel,
                      abs(value.translation.width) <= abs(dy) else { return }

                viewModel.swiped(up: dy < 0)
            }
    }

    private var cameraContent: some View {
        ZStack {
            previewLayer
                // 高度读数（起点 55% 判定用）+ 上划呼出 / 下划收起手势（#7）。
                // ⚠️ simultaneousGesture 而不是 gesture：预览层内部是 UIKit 的
                // 点按对焦（UITapGestureRecognizer），要两条手势并存，
                // 点按（tap）与拖动（drag）天然不冲突 —— 原型"拖完补 click 误收浮层"的坑
                // 在这里结构上不存在（tap 手势不会由一次 34pt 的拖动触发）。
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ViewfinderHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                .onPreferenceChange(ViewfinderHeightKey.self) { previewHeight = $0 }
                .simultaneousGesture(viewfinderSwipeGesture)

            VStack(spacing: Theme.Spacing.sm) {
                TopBarView(
                    mode: viewModel.mode,
                    freeSpaceText: env.session.freeSpaceText,
                    isTonePreviewOn: env.showTonePreview,
                    isGridOn: env.showGrid,
                    onModeTap: { tapped in
                        viewModel.modeTapped(tapped)
                    },
                    onFlashTap: { viewModel.flashTapped() },
                    onGridTap: { viewModel.gridTapped() },
                    onTonePreviewTap: { viewModel.tonePreviewTapped() },
                    onStorageTap: { viewModel.storageTapped() },
                    onSettingsTap: { env.showSettings = true }
                )

                if env.showDebugHUD {
                    HStack(alignment: .top) {
                        DebugHUDView(
                            snapshot: env.session.debugSnapshot,
                            log: DebugLog.shared,
                            isExpanded: $isHUDExpanded
                        )
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)
                }

                Spacer(minLength: 0)

                if let toast = viewModel.toast {
                    toastView(toast)
                }

                if case .failed(let message) = env.session.state {
                    SessionFailureBanner(message: message) {
                        env.session.stop()
                        env.session.start()
                    }
                }

                bottomArea
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .animation(.easeInOut(duration: 0.18), value: viewModel.toast)
        }
        // 顶部浮层槽位（模式条正下方）：**录制计时** 与 **实况角标** 共用，二者互斥 ——
        // 录制只发生在视频 / Log 实况模式，实况角标只在实况模式。
        // 录制徽标从快门上方挪到这里（2026-09-17：2-3 加焦段条后，原位置会盖住药丸）。
        // 两者都不参与布局（不挤压下方 HUD），也不接收触摸。
        .overlay(alignment: .top) {
            if viewModel.isRecording {
                RecordingBadge(seconds: viewModel.recordingSeconds)
                    .offset(y: Theme.Spacing.sm + Theme.Size.topBarHeight + 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if viewModel.mode == .livePhoto {
                liveBadge
                    .offset(y: Theme.Spacing.sm + Theme.Size.topBarHeight + 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.mode)
        .animation(.easeInOut(duration: 0.18), value: viewModel.isRecording)
    }

    // MARK: - 顶栏
    //
    // 顶栏（两行：电平表 + 模式条 + 三图标 / 影调预览 + 剩余存储）已抽成
    // `TopBarView`（`Camera/UI/TopBarView.swift`）。
    // 抽出去的原因：它自己是"两侧等宽 + 中段吃满"的一套版式，还有上缘渐隐，
    // 混在本文件的取景器 + 底栏里看不清楚；而 2-2 之后的模块 #10（⠿ 面板）、
    // 模块 #11（格式芯片顶替三图标）都要动它。

    /// Live Photo 生效时的明确信号。
    ///
    /// **为什么居中浮在模式条下方，而不是塞在顶栏右侧**：
    /// 模式条四档宽 267.4pt、顶栏可用宽 370pt，右侧再放一个角标必然与模式条重叠
    /// （真机实测重叠 28pt，把「视频」盖掉一半）。网页原型同样把角标居中放在
    /// 模式条下方（`.live-badge{ position:absolute; left:50%; top:90px; }`）。
    ///
    /// **为什么是同心圆图标而不是「LIVE」文字**：原型已按拍板统一成
    /// Live Photo 同心圆（与系统相机的 LIVE 标、模式条「实况」档同一套图标语言），
    /// 保留黄底 + 深色图标，保证在明亮取景画面上依然醒目。
    /// 图形本身复用 `LivePhotoCircleIcon`（模式条「实况」档用的是同一个组件，
    /// 不重复维护第二份画法）。
    private var liveBadge: some View {
        LivePhotoCircleIcon(size: Theme.Size.liveBadgeIconSize)
            // 深色图标压在 accent 黄底上。原型这里写的是 `#111`（纯黑偏灰一档），
            // Swift 侧沿用工程既有做法用纯黑（`GuideLayout` 的主按钮、
            // `ModeSelector` 选中态同样如此），避免为一个肉眼不可辨的差值新增色令牌。
            .foregroundStyle(Color.black)
            .frame(width: Theme.Size.liveBadgeSide, height: Theme.Size.liveBadgeSide)
            .background(Circle().fill(Theme.Palette.accent))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("实况已开启")
    }

    // MARK: - 底部控制区

    private var bottomArea: some View {
        VStack(spacing: Theme.Spacing.md) {
            // 滤镜条（#7）：底栏最上方（场景·风格条之上），上划取景器呼出。
            // ⚠️ 用**条件插入**而不是"常驻 + height 0"：VStack 的 spacing 在 0 高的
            // 子视图上依然生效，会留一条 16pt 的幽灵空隙顶起场景·风格条。
            // ⤢ 放大态下整条强制隐藏（原型 `.screen.zoom-on .row-filter{ height:0 }`）；
            // 状态保留，退出放大态即恢复 —— 与原型"只隐藏不重置"一致。
            if isFilterStripShown {
                FilterStripView(
                    selectedId: viewModel.filterId,
                    onTap: { viewModel.filterTapped($0) }
                )
                // 插入 = 从底栏栈后面滑上来（bottom-anchored，面板从控件身后升起）；
                // 移除 = 滑回去并淡出。原型是 height 0→144 + opacity，观感同类。
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 场景 · 风格条（#6）：原型里它排在**参数排之上**，
            // 是"选场景直接拍"这条主线的入口（一级视觉权重）。
            SceneStyleStrip(
                scene: viewModel.scene,
                style: viewModel.style,
                filterName: viewModel.filterName,
                isExpanded: viewModel.isSceneStyleExpanded,
                onToggle: { viewModel.toggleSceneStyle() },
                onSceneTap: { viewModel.sceneTapped($0) },
                onStyleTap: { viewModel.styleTapped($0) }
            )

            // ⤢ 放大态：参数排与图标行**整行让位**（原型 `.zoom-on` 把三条归零）。
            // 前置 / 设置的入口由快门排的镜像按钮顶上，不会丢功能。
            // ⚠️ 焦段条**不在让位之列** —— 它顺序往下走、正好落在取景器卡片的内底边，
            // 这就是原型 `.zoom-on .row-focal` 的效果（见下方它的注释）。
            if !viewModel.isZoomOn {
                ExposurePanel(
                    exposureBias: $viewModel.exposureBias,
                    range: env.session.exposureBiasRange,
                    isEnabled: env.session.state == .running && !viewModel.isSaving,
                    onEditingChanged: { isEditing in
                        viewModel.exposureEditingChanged(isEditing)
                    }
                )

                // 底部图标行：七项（前置/对焦/白平衡/感光/快门速度/曝光补偿/设置），
                // 全部有反馈 —— 未实现的给 toast 说明，设置真开设置页。
                ToolIconRow(
                    onFrontCamera: { viewModel.frontCameraTapped() },
                    onFocusHint: { viewModel.focusHintTapped() },
                    onWhiteBalance: { viewModel.whiteBalanceTapped() },
                    onISO: { viewModel.isoTapped() },
                    onShutterSpeed: { viewModel.shutterSpeedTapped() },
                    onExposureCompensation: { viewModel.exposureCompensationTapped() },
                    onSettings: { env.showSettings = true }
                )
            }

            // 焦段条：**底栈里的普通一行**，位置在「图标行之下、快门排之上」
            // —— 原型 HTML 就是这个顺序（`.params-closed-bar` → `.row-focal` → `.shutter-row`），
            // 2-4 的交付版式也是这个顺序（真机截图 `LumenEdit-底部三排-2-3.png`）。
            //
            // ⚠️ **2-5b 曾把它改成"绝对定位到底部"的浮层，这是一次回归**：那个偏移公式
            // （快门排 80 + 内边距 10 + 行距 16 = 106）是 2-3 时代的账，当时底栈里还没有图标行。
            // 2-4 把图标行插进底栈后，那个位置正好落在图标行上 —— 真机上四颗药丸直接压在
            // 「对焦 / 白平衡 / 快门速度 / 曝光补偿」的文字上（2026-09-17 Mac 侧截图取证）。
            //
            // 现在回到"它就是一行"：常态自然落在图标行与快门排之间；放大态那两行整行让位后，
            // 它自然落在快门排正上方、也就是取景器卡片的内底边（原型 `.zoom-on .row-focal`
            // 想要的效果）—— **不需要任何绝对定位、也就不需要维护两套偏移**。
            //
            // 代价（如实记录）：放大态下它与卡片底边的间隙是 16pt（底栈统一行距），
            // 原型写的是 12pt；差 4pt，为此再引入一层绝对定位不划算。
            //
            // ⚠️ 场景·风格展开**或**滤镜条展开时**整行收起**（#6 / #7，原型
            // `.ss-on/.filter-on .row-focal`）：那两条要占 147 / 144pt，
            // 焦段条再占一行会把底部栈撑得过高。放大态下滤镜条本来就隐藏
            //（`isFilterStripShown` 为 false），焦段条照常落进卡片内底边。
            if !viewModel.isSceneStyleExpanded && !isFilterStripShown {
                FocalStripView(selection: viewModel.focal) { preset in
                    viewModel.focalTapped(preset)
                }
            }

            // 快门排四件套：缩略图 · 快门（绝对居中）· ⤢ · 风格方块（docs/09）。
            // ⚠️ 录制计时徽标**不在这里** —— 它原来的位置（快门上方上浮）自 2-3 起被
            // 焦段条占了，徽标已挪到取景器顶部居中（见上方 overlay，Apple 相机的做法）。
            ShutterRowView(
                thumbnailImage: env.thumbnails.lastThumbnail,
                onThumbnailTap: { viewModel.openSystemPhotos() },
                isShutterBusy: viewModel.isSaving,
                isRecording: viewModel.isRecording,
                // ⚠️ 录制中快门**必须保持可用** —— 那是唯一的"停止录制"入口，
                // 禁用掉就会出现"录上了停不下来"。
                isShutterEnabled: viewModel.isRecording
                    || (env.session.state == .running && !viewModel.isSaving),
                onShutterTap: { viewModel.shutterTapped() },
                isZoomOn: viewModel.isZoomOn,
                onZoomTap: { viewModel.zoomTapped() },
                style: viewModel.style,
                // 风格方块 = 第三个展开入口（与折叠胶囊、箭头同一行为）
                onStyleEntryTap: { viewModel.styleThumbTapped() },
                // 放大态镜像按钮：与图标行的「前置 / 设置」同一行为
                onFrontCamera: { viewModel.frontCameraTapped() },
                onSettings: { env.showSettings = true }
            )
        }
        .padding(.bottom, Theme.Spacing.sm)
        // 滤镜条的插入 / 移除动画由这两个状态驱动（transition 写在 FilterStripView 上）。
        // isZoomOn 也要绑：放大态把滤镜条强制隐藏时同样走过渡，而不是瞬移消失。
        .animation(.easeInOut(duration: 0.22), value: viewModel.isFilterStripExpanded)
        .animation(.easeInOut(duration: 0.22), value: viewModel.isZoomOn)
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(Theme.Typography.toast)
            .foregroundStyle(Theme.Palette.primaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                Capsule().fill(Color.black.opacity(0.75))
            )
            .overlay(
                Capsule().stroke(Theme.Palette.stroke, lineWidth: 0.5)
            )
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - 取景器高度读数（#7 手势用）

/// 把取景器容器高度传给手势判定（起点 55% 判定），不参与布局。
/// 手势挂在 previewLayer 上，其坐标空间就是容器的坐标空间，两处天然同系。
private struct ViewfinderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 录制计时徽标

/// 录制中显示的红点 + 计时。
///
/// **2026-09-17 挪了位置**：原来浮在快门上方，但 2-3 把焦段条加进底栈之后，
/// 那个位置被焦段条的药丸占了（录制徽标会盖住药丸的下半截）。
/// 现在挪到**取景器顶部居中**（Apple 相机的做法，见 `body` 上方的 overlay）——
/// 那个槽位与实况角标互斥（录制只发生在视频 / Log 实况模式，实况角标只在实况模式），
/// 不会打架。徽标不参与布局，避免顶动任何控件。
private struct RecordingBadge: View {

    let seconds: Double

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.Palette.recording)
                .frame(width: 7, height: 7)
            Text(Self.format(seconds))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Palette.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .accessibilityLabel("正在录制，已录制 \(Int(seconds)) 秒")
    }

    /// mm:ss；超过一小时显示 h:mm:ss
    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 权限引导

private struct PermissionPromptContent: View {

    let onRequest: () -> Void

    var body: some View {
        GuideLayout(
            icon: "camera.aperture",
            title: "需要相机权限",
            message: "LumenEdit 需要访问相机才能拍摄照片、Live Photo 与视频。\n拍摄内容只会保存到你自己的手机里。",
            primaryTitle: "允许访问相机",
            primaryAction: onRequest
        )
    }
}

private struct PermissionDeniedContent: View {

    let onOpenSettings: () -> Void

    var body: some View {
        GuideLayout(
            icon: "exclamationmark.triangle",
            title: "相机权限已被拒绝",
            message: "请到「设置 → LumenEdit → 相机」中开启权限。\n开启后回到本页面会自动恢复。",
            primaryTitle: "打开系统设置",
            primaryAction: onOpenSettings
        )
    }
}

private struct GuideLayout: View {

    let icon: String
    let title: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.Palette.accent)

            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Palette.primaryText)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .frame(height: 44)
                    .background(
                        Capsule().fill(Theme.Palette.accent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: 340)
    }
}

// MARK: - 会话失败提示

private struct SessionFailureBanner: View {

    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.danger)
                Text("相机启动失败")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Spacer(minLength: 0)
                Button("重试", action: onRetry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .buttonStyle(.plain)
            }

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.panel.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Theme.Palette.danger.opacity(0.5), lineWidth: 0.5)
        )
    }
}
