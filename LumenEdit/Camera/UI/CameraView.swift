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

            // 与预览同一坐标系，直接用视图坐标绘制
            FocusIndicatorView(point: viewModel.focusPoint, token: viewModel.focusToken)

            VStack(spacing: Theme.Spacing.sm) {
                topBar

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

    private var topBar: some View {
        // 左右两侧各留一块**等宽**占位，模式条的盒中心才等于屏幕中心。
        // 照搬网页原型的 `--tb-side-w` 做法（原型注释：「把两侧块钉成同宽，
        // 盒中心回到屏中心，模式条再 justify-content:center 即真正居中」）。
        //
        // 改造前是 ZStack 覆盖式（模式条居中 + 图标组浮在上层），真机实测
        // （iPhone 16 Pro / iOS 26.6，截图像素测量）：模式条右端落在 334.7pt，
        // 与右侧图标组起点 306.7pt 重叠 28pt，把「视频」二字盖掉了一半。
        // 现在 38 + 267 + 38 = 343pt ≤ 可用宽 370pt，模式条真正居中且零重叠。
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Theme.Size.topBarSideWidth)

            ModeSelector(selection: viewModel.mode) { mode in
                viewModel.modeTapped(mode)
            }
            // 中段吃掉全部余量（370 − 38×2 = 294pt），对应原型的 `flex:1 1 auto`。
            // 少了这一步，HStack 会整体收缩到 343pt 再被居中，齿轮就会内缩 13.5pt
            // （真机实测：齿轮右端 372.3pt，应为 386pt）。加上后齿轮贴住右内边距，
            // 而模式条仍在两侧等宽块之间居中 = 真正的屏中心。
            .frame(maxWidth: .infinity)

            Button {
                env.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(Theme.Palette.panel.opacity(0.78))
                    )
                    .overlay(
                        Circle().stroke(Theme.Palette.stroke, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
            .frame(width: Theme.Size.topBarSideWidth, alignment: .trailing)
        }
        .frame(height: Theme.Size.topBarHeight)
    }

    /// Live Photo 生效时的明确信号。
    ///
    /// **为什么居中浮在模式条下方，而不是塞在顶栏右侧**：
    /// 模式条四档宽 267.4pt、顶栏可用宽 370pt，右侧再放一个角标必然与模式条重叠
    /// （真机实测重叠 28pt，把「视频」盖掉一半）。网页原型同样把角标居中放在
    /// 模式条下方（`.live-badge{ position:absolute; left:50%; top:90px; }`）。
    ///
    /// ⚠️ 原型已把角标改成 22×22 的 Live Photo 同心圆图标（原型注释：「已按拍板
    /// 改为 Live Photo 同心圆图标…不再用「实况」文字」）。这里**只修正位置，
    /// 暂时保留文字药丸的观感**，图标化留给 UI 批次统一处理，避免与本批改动混在一起。
    private var liveBadge: some View {
        Text("LIVE")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Theme.Palette.accent))
            .accessibilityLabel("Live Photo 已开启")
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
