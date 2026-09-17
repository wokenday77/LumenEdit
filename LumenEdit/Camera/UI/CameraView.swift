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

    private var cameraContent: some View {
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
        // 实况角标：居中浮在模式条正下方，不参与布局（不挤压下方 HUD），也不接收触摸
        .overlay(alignment: .top) {
            if viewModel.mode == .livePhoto {
                liveBadge
                    .offset(y: Theme.Spacing.sm + Theme.Size.topBarHeight + 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.mode)
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
            ExposurePanel(
                exposureBias: $viewModel.exposureBias,
                range: env.session.exposureBiasRange,
                isEnabled: env.session.state == .running && !viewModel.isSaving,
                onEditingChanged: { isEditing in
                    viewModel.exposureEditingChanged(isEditing)
                }
            )

            // 焦段条：原型里它排在参数排与快门排之间（快门按钮中心 Y 的推导式里
            // 「焦段条 44」就是这一段）。⤢ 放大态时它会浮进取景器卡片内底边（2-5b）。
            FocalStripView(selection: viewModel.focal) { preset in
                viewModel.focalTapped(preset)
            }

            HStack(spacing: 0) {
                CaptureThumbnail(image: env.thumbnails.lastThumbnail) {
                    viewModel.openSystemPhotos()
                }

                Spacer(minLength: 0)

                ShutterButton(
                    isBusy: viewModel.isSaving,
                    isRecording: viewModel.isRecording,
                    // ⚠️ 录制中快门**必须保持可用** —— 那是唯一的"停止录制"入口，
                    // 禁用掉就会出现"录上了停不下来"。
                    isEnabled: viewModel.isRecording
                        || (env.session.state == .running && !viewModel.isSaving)
                ) {
                    viewModel.shutterTapped()
                }
                .overlay(alignment: .top) {
                    if viewModel.isRecording {
                        RecordingBadge(seconds: viewModel.recordingSeconds)
                            .offset(y: -38)
                    }
                }

                Spacer(minLength: 0)

                // 与缩略图等宽的透明占位，保证快门在屏幕正中而不是被挤偏
                Color.clear
                    .frame(width: Theme.Size.thumbnailSide, height: Theme.Size.thumbnailSide)
            }
        }
        .padding(.bottom, Theme.Spacing.sm)
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

// MARK: - 快门按钮

private struct ShutterButton: View {

    let isBusy: Bool
    /// 是否正在录制视频 —— 录制中内圈变成红色方块（"停止录制"的行业标准形态）
    let isRecording: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: Theme.Size.shutterRingWidth)
                    .frame(width: Theme.Size.shutterDiameter, height: Theme.Size.shutterDiameter)

                if isRecording {
                    // 录制中：红色圆角方块 = 点它停止录制
                    RoundedRectangle(cornerRadius: Theme.Size.shutterDiameter * 0.15, style: .continuous)
                        .fill(Theme.Palette.recording)
                        .frame(
                            width: Theme.Size.shutterDiameter * 0.42,
                            height: Theme.Size.shutterDiameter * 0.42
                        )
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(
                            width: Theme.Size.shutterDiameter - 14,
                            height: Theme.Size.shutterDiameter - 14
                        )
                        // 拍摄/保存时内圈收缩，和系统相机的反馈一致
                        .scaleEffect(isBusy ? 0.68 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: isBusy)

                    if isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.black)
                    }
                }
            }
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.18), value: isRecording)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
        .accessibilityLabel(isRecording ? "停止录制" : "快门")
    }
}

// MARK: - 录制计时徽标

/// 录制中显示的红点 + 计时，浮在快门上方（不参与布局，避免顶动快门）。
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
