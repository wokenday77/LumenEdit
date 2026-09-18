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
    /// 本次拖动是否已经触发过（提前触发后手势仍在继续，防止一次长滑连跨两级）
    @State private var swipeDidTrigger = false

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

    /// 参数排（EV 面板）当前是否真的展开。默认收起（`isExposurePanelExpanded` 初值 false），
    /// ⤢ 放大态强制隐藏（与滤镜条同规则，原型 `.zoom-on` 把参数排整行归零）。
    private var isExposurePanelShown: Bool {
        viewModel.isExposurePanelExpanded && !viewModel.isZoomOn
    }

    /// 手势几何参数（2026-09-18 按真机反馈放宽过一次，别再照着原型原样抄）。
    ///
    /// **为什么放宽**：原型是 24 起手 / 34 位移 / 0.8s / 起点 55% —— 那是浏览器里用鼠标/触屏
    /// 双环境定的口径，搬到真机上偏严。真机反馈"上滑要很用力 + 只有特定位置能触发"，
    /// 算完账发现根因不是"力度"，而是**可用起手带只有约 6pt**：
    ///
    /// ```
    /// iPhone 16 Pro：安全区高 778（上 62 / 下 34）
    ///   顶栏 + 外层 padding ≈ 66
    ///   底栏栈 ≈ 334（EV 面板 108 + 16 + 图标行 44 + 16 + 焦段条 44 + 16 + 快门排 80 + 内边距 10）
    ///   → 底栏栈上沿落在安全区 y ≈ 434
    ///   而起点线 0.55 × 778 = 428
    ///   → 可用窗口 428 ~ 434 = 6pt
    /// ```
    ///
    /// 现在两处一起动：**参数排默认收起**（底栏栈降到约 210，上沿下移到 ≈ 558）
    /// + 起点线降到 25%（= 只排除最上面 25%，用来避开顶栏与调试浮层区）。
    /// 落在底栏控件上的起手仍由**结构**排除（触摸被控件吃掉，到不了这个手势），
    /// 落在底栏各行之间 16pt 空隙上的起手会被正常接受（那是穿透到取景器的）。
    private static let swipeActivationDistance: CGFloat = 10
    /// 位移阈值。18 → **16**（第二轮真机反馈"还是要用力"后再降一档；
    /// 配合"提前触发"（滑够即生效、不等松手），16pt ≈ 1.6mm 已经很跟手，
    /// 且仍大于点按对焦的容差，不会把点按误判成滑动）
    private static let swipeMinTravel: CGFloat = 16
    private static let swipeMaxDuration: TimeInterval = 1.2
    /// 起点必须在容器下方 75% 区域内（= 只排除上 25%：顶栏 66pt + 调试浮层）。
    /// 原为 0.55（只允许下 45%），与底栏上沿只差 6pt，是"上滑不灵敏"的直接原因。
    private static let swipeStartRegionRatio: CGFloat = 0.25
    /// 横向排除的宽容倍数：|dx| > |dy| × 本值 才算"在横滑条上滑动"。
    /// 原型是 1.0（斜一点就拒），真机上斜着上滑很常见，放宽到 1.5。
    private static let swipeHorizontalSlack: CGFloat = 1.5

    /// 上划呼出滤镜条（再上划呼出场景·风格）、下划逐级收起。
    ///
    /// **两条关键实现细节**（2026-09-18 两轮真机反馈后定的）：
    ///
    /// 1. **提前触发**：判定放在 `onChanged` 里，**滑够阈值立刻生效**，不等松手。
    ///    原来只在 `onEnded` 判定 → 必须"滑到位并松手"才有反馈，用户滑到一半看不见变化、
    ///    以为没反应，就会滑得更用力更快 —— 这就是"上滑僵硬、要用力"的体感来源。
    /// 2. **一次拖动只触发一级**（`swipeDidTrigger`）：提前触发后手势还在继续，
    ///    没有这个标记会在一次长滑里连续跨两级（滤镜条 → 场景·风格）。
    ///
    /// 挂载点在 `cameraContent` 的 ZStack 上（原因见那里的注释）。
    private var viewfinderSwipeGesture: some Gesture {
        DragGesture(minimumDistance: Self.swipeActivationDistance)
            .onChanged { value in
                // 记一次起点时刻；同一次拖动只记一次
                if swipeGestureStart == nil { swipeGestureStart = Date() }
                guard !swipeDidTrigger, shouldTriggerSwipe(value) else { return }
                swipeDidTrigger = true
                viewModel.swiped(up: value.translation.height < 0)
            }
            .onEnded { _ in
                // 手势结束只做清理 —— 判定已经在 onChanged 里做完了
                swipeGestureStart = nil
                swipeDidTrigger = false
            }
    }

    /// 是否已达触发条件：起点区 / 时长 / 位移 / 纵向为主，四条全满足。
    private func shouldTriggerSwipe(_ value: DragGesture.Value) -> Bool {
        // 时长守卫（原型"长按后拖动不算滑动"）
        guard let start = swipeGestureStart,
              Date().timeIntervalSince(start) <= Self.swipeMaxDuration else {
            return false
        }
        // 起点必须在取景器下 75% 区（只排除最上面的顶栏 / 调试浮层区）
        guard value.startLocation.y > previewHeight * Self.swipeStartRegionRatio else {
            return false
        }
        let dy = value.translation.height
        // 位移够 + 纵向为主（横向为主 → 是在横滑条上滑动）
        return abs(dy) >= Self.swipeMinTravel
            && abs(value.translation.width) <= abs(dy) * Self.swipeHorizontalSlack
    }

    private var cameraContent: some View {
        ZStack {
            previewLayer
                // 高度读数（起点判定用）。手势**不挂在这上面** —— 见 ZStack 末尾的说明。
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ViewfinderHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                .onPreferenceChange(ViewfinderHeightKey.self) { previewHeight = $0 }

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
        // ⚠️ **上划 / 下划手势挂在整页 ZStack 上**（2026-09-18 第二次真机反馈后改的）。
        //
        // 之前挂在 `previewLayer` 上，有个**结构性缺陷**：底栏栈是在 ZStack 里绘制在上的
        // 兄弟视图，落在它上面的触摸到不了预览层的手势。第一次上划能呼出滤镜条，
        // 但**滤镜条一出现，就把用户上次起手的屏幕下部区域占了** —— 第二次在同一位置起手，
        // 触摸落在滤镜条（标题行 / 横滑卡条）上被吃掉 → 手势收不到 → **第二次上划没反应**，
        // 于是"上划两次只能呼出一个"（真机反馈 ③）。
        //
        // 挂到 ZStack 上后，**落在任何子视图上的拖动都能被同时识别**（`simultaneousGesture`
        // 的语义就是"与子视图手势并存"）：
        //   - 横向拖动由 `|dx| ≤ |dy| × 1.5` 排除 → 横滑条的滚动不受影响
        //   - 落在按钮上的拖动不会触发按钮（移动超过起手门槛后 tap 本来就失败）
        //   - 落在 EV 滑条上的竖向拖动：滑条的方向闸门不接管，这里接管 → 正是期望行为
        // 点按对焦（UIKit 的 tap）与拖动天然不冲突，`simultaneousGesture` 保证两者并存。
        .simultaneousGesture(viewfinderSwipeGesture)
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
                // 底部图标行（常驻）：原型 `.params-closed-bar{ order:1 }` → 图标行在上。
                // 七项（前置/对焦/白平衡/感光/快门速度/曝光补偿/设置）全部有反馈 ——
                // 未实现的给 toast 说明，设置真开设置页。
                ToolIconRow(
                    onFrontCamera: { viewModel.frontCameraTapped() },
                    onFocusHint: { viewModel.focusHintTapped() },
                    onWhiteBalance: { viewModel.whiteBalanceTapped() },
                    onISO: { viewModel.isoTapped() },
                    onShutterSpeed: { viewModel.shutterSpeedTapped() },
                    onExposureCompensation: { viewModel.exposureCompensationTapped() },
                    onSettings: { env.showSettings = true }
                )

                // 参数排（EV 面板）：**默认收起**，点图标行「曝光补偿」展开 / 收起。
                // 顺序对齐原型 `.strip-panel{ order:2 }` —— 图标行在上、面板紧贴其下。
                // （2026-09-18 由常驻改为可收起：常驻时既没有关闭入口，又把常态净可见
                //   压到 50% 以下、还吃掉了上滑手势的起手区，见 `isExposurePanelExpanded` 注释。）
                if isExposurePanelShown {
                    ExposurePanel(
                        exposureBias: $viewModel.exposureBias,
                        // ⚠️ 用「UI 范围 ∩ 设备范围」，**不要直接给设备范围**：
                        // iPhone 报的是 -8…+8（16 EV ÷ 1/3 = 48 档），而滑条可视宽约 338pt
                        // → 每档 7pt，1/3 档的吸附完全感觉不到（2026-09-18 真机反馈）。
                        // 取交集后是 ±2（13 档 / 每档约 28pt），硬件侧仍按设备范围 clamp。
                        range: env.session.exposureBiasRange.intersected(with: Float.evUIRange),
                        isEnabled: env.session.state == .running && !viewModel.isSaving,
                        onEditingChanged: { isEditing in
                            viewModel.exposureEditingChanged(isEditing)
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
        // 滤镜条 / 参数排的插入·移除动画由这三个状态驱动（transition 写在各自组件上）。
        // isZoomOn 也要绑：放大态把两者强制隐藏时同样走过渡，而不是瞬移消失。
        .animation(.easeInOut(duration: 0.22), value: viewModel.isFilterStripExpanded)
        .animation(.easeInOut(duration: 0.22), value: viewModel.isExposurePanelExpanded)
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
