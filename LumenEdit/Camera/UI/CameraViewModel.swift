import Combine
import Foundation
import UIKit

/// 相机页状态机。
///
/// 职责边界：
///   - **只管 UI 状态与用户意图**：权限流程、保存中状态、提示条、对焦方框、模式校验；
///   - **不碰 AVFoundation**：所有硬件操作都通过 `CaptureSessionController`；
///   - **不碰文件与相册**：入库统一走 `PhotoLibraryWriter`。
///
/// 这样相机页换一套 UI（比如以后做 iPad 版）不用改任何底层代码。
@MainActor
final class CameraViewModel: ObservableObject {

    // MARK: - 输出给 UI 的状态

    /// 曝光补偿滑块的值。与 session 的双向同步在 `attach(_:)` 里建立。
    @Published var exposureBias: Double = 0

    @Published private(set) var mode: CaptureSessionMode = .photo
    @Published private(set) var isSaving = false

    /// 当前选中的焦段档位。
    /// **不落盘**：原型的「保留设置」只管 场景 / 风格 / 滤镜 / EV 四项，焦段不在其中。
    @Published private(set) var focal: FocalPreset = FocalCatalog.defaultFocal

    /// 是否正在录制视频（P1b-2）
    @Published private(set) var isRecording = false
    /// 已录制秒数，供录制指示器计时
    @Published private(set) var recordingSeconds: Double = 0
    @Published private(set) var toast: String?

    /// 对焦方框位置（视图坐标）与重播令牌
    @Published private(set) var focusPoint: CGPoint = .zero
    @Published private(set) var focusToken: Int = 0

    // MARK: - 依赖

    private weak var environment: AppEnvironment?
    private var cancellables = Set<AnyCancellable>()
    private var isAttached = false
    private var toastTask: Task<Void, Never>?
    private var lastShownError: String?

    // MARK: - 装配

    /// 由视图在 `onAppear` 时调用。`@StateObject` 无法在初始化时拿到 EnvironmentObject，
    /// 所以用这种"后装配"的方式，重复调用是安全的。
    func attach(_ environment: AppEnvironment) {
        guard !isAttached else { return }
        isAttached = true
        self.environment = environment

        // 硬件侧读回来的曝光补偿 → 同步到滑块
        environment.session.$exposureBias
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.exposureBias = Double(value)
            }
            .store(in: &cancellables)

        // 会话侧的模式 → 同步到 UI
        environment.session.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.mode = value
            }
            .store(in: &cancellables)

        // 会话侧的硬件错误 → 提示条（同一个错误只提示一次，避免每秒刷屏）
        environment.session.$lastErrorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self, let message, !message.isEmpty else { return }
                guard self.lastShownError != message else { return }
                self.lastShownError = message
                self.showToast(message)
            }
            .store(in: &cancellables)

        DebugLog.shared.info("ui", "相机页已装配")
    }

    // MARK: - 生命周期

    func onAppear() async {
        guard let environment else { return }

        Haptics.prepareAll()
        await environment.refreshPermissions()

        if environment.permissions.camera.canPrompt {
            _ = await environment.permissions.requestCamera()
        }

        guard environment.permissions.camera.isUsable else {
            DebugLog.shared.warn("ui", "相机权限不可用，停留在引导页")
            return
        }

        environment.session.setVisible(true)

        // 有相册读取权限时把最新一张照片填到左下角；没有权限就等第一次拍摄
        await environment.thumbnails.refreshFromLibraryIfAuthorized()
    }

    func onDisappear() {
        environment?.session.setVisible(false)
    }

    func requestCameraPermission() async {
        guard let environment else { return }
        _ = await environment.permissions.requestCamera()
        if environment.permissions.camera.isUsable {
            environment.session.setVisible(true)
        }
    }

    func openSystemSettings() {
        environment?.permissions.openSystemSettings()
    }

    // MARK: - 快门

    func shutterTapped() {
        guard let environment else { return }

        // 录制类模式（视频 / Log 实况）：快门 = 开始 / 停止录制（不是一次性拍照）。
        // 放在最前面，避免走下面那套"拍一张等保存"的逻辑 —— 录制类模式下 session 里
        // 挂的是 movieOutput、没有 photoOutput，走拍照路径会失败。
        // 判据来自枚举（`isRecordingBased`），新增模式时只改一处。
        if environment.session.mode.isRecordingBased {
            toggleRecording()
            return
        }

        guard !isSaving, !environment.session.isPhotoOutputBusy else {
            DebugLog.shared.debug("ui", "上一次保存尚未结束，忽略快门")
            return
        }
        guard environment.session.state == .running else {
            showToast("相机尚未就绪，请稍候")
            return
        }

        Haptics.shutter()
        isSaving = true
        lastShownError = nil

        environment.session.capture { [weak self] result in
            // 该闭包是非隔离上下文，因此在主线程任务里再处理 UI 状态
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let capture):
                    await self.persist(capture)
                case .failure(let error):
                    self.isSaving = false
                    Haptics.warning()
                    self.showToast("拍摄失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 视频录制（P1b-2）

    /// 视频模式下按快门 = 开始 / 停止录制。
    private func toggleRecording() {
        guard let environment else { return }

        if isRecording {
            Haptics.shutter()
            environment.session.stopRecording()
            return
        }

        guard environment.session.state == .running else {
            showToast("相机尚未就绪，请稍候")
            return
        }
        guard !isSaving else {
            DebugLog.shared.debug("ui", "上一次保存尚未结束，忽略录制请求")
            return
        }

        Haptics.shutter()
        lastShownError = nil
        recordingSeconds = 0

        environment.session.startRecording { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                // 录制结束（正常或失败）都要复位状态
                self.isRecording = false
                self.recordingSeconds = 0
                switch result {
                case .success(let capture):
                    await self.persist(capture)
                case .failure(let error):
                    Haptics.warning()
                    self.showToast("录制失败：\(error.localizedDescription)")
                }
            }
        }

        isRecording = true
        environment.session.onRecordingTick = { [weak self] seconds in
            Task { @MainActor in
                self?.recordingSeconds = seconds
            }
        }
    }

    /// 停止录制（供切模式 / 退到后台时调用）。停止后产物仍会正常保存。
    func stopRecordingIfNeeded() {
        guard isRecording, let environment else { return }
        DebugLog.shared.info("ui", "外部触发停止录制")
        environment.session.stopRecording()
    }

    // MARK: - 保存

    private func persist(_ capture: CaptureResult) async {
        guard let environment else { return }

        // 临时文件在保存结束后统一清理：成功要清，**失败更要清**。
        // 只在成功分支里删的话，每次保存失败都会在 tmp 里留一个文件，
        // Live Photo 的 MOV 单个就是几 MB，堆起来很快。
        var temporaryFileURL: URL?
        defer {
            if let temporaryFileURL, FileManager.default.fileExists(atPath: temporaryFileURL.path) {
                try? FileManager.default.removeItem(at: temporaryFileURL)
                DebugLog.shared.debug("ui", "已清理临时文件 \(temporaryFileURL.lastPathComponent)")
            }
        }

        do {
            switch capture {
            case .photo(let data, _):
                let identifier = try await PhotoLibraryWriter.savePhotoData(data)
                environment.thumbnails.rememberSavedIdentifier(identifier)
                environment.thumbnails.rememberCapturedPhoto(data: data)
                showToast("已保存到相册")

            case .livePhoto(let imageData, let movieURL, _):
                temporaryFileURL = movieURL
                let identifier = try await PhotoLibraryWriter.saveLivePhotoPair(
                    imageData: imageData,
                    movieURL: movieURL
                )
                environment.thumbnails.rememberSavedIdentifier(identifier)
                environment.thumbnails.rememberCapturedPhoto(data: imageData)
                showToast("Live Photo 已保存")

            case .movie(let url):
                temporaryFileURL = url
                let identifier = try await PhotoLibraryWriter.saveVideoFile(at: url)
                environment.thumbnails.rememberSavedIdentifier(identifier)
                environment.thumbnails.rememberCapturedFile(at: url)
                // 提示语按拍摄模式区分：Log 实况当前的产物就是一段普通视频，
                // 谎称"实况照片已保存"会让人去相册里长按却发现播不动。
                showToast(mode == .logLive
                    ? "Log 视频已保存到相册（LUT 导出实况照片在 P5）"
                    : "视频已保存")
            }

            Haptics.success()
        } catch {
            Haptics.warning()
            showToast("保存失败：\(error.localizedDescription)")
            DebugLog.shared.error("ui", "保存失败：\(error.localizedDescription)")
        }

        isSaving = false
    }

    // MARK: - 对焦

    func focusTapped(viewPoint: CGPoint, devicePoint: CGPoint) {
        environment?.session.focus(atDevicePoint: devicePoint)
        focusPoint = viewPoint
        focusToken &+= 1
        Haptics.focus()
    }

    // MARK: - 曝光

    func exposureEditingChanged(_ isEditing: Bool) {
        environment?.session.setExposureBias(Float(exposureBias))
    }

    // MARK: - 模式

    func modeTapped(_ newMode: CaptureSessionMode) {
        guard let environment else { return }
        guard newMode != mode else { return }

        guard newMode.isImplemented else {
            // 明确告知原因，不做"点了没反应"
            showToast(newMode.unavailableReason ?? "该模式暂不可用")
            return
        }

        // 需要麦克风的模式先确保权限，再切模式——否则会出现
        // "录制成功但没有声音"，而且很难联想到是权限问题
        if newMode.requiresMicrophone, !environment.permissions.microphone.isUsable {
            Task { @MainActor in
                let granted = await environment.permissions.requestMicrophone()
                if granted {
                    self.applyMode(newMode, on: environment)
                } else {
                    self.showToast("需要麦克风权限才能使用\(newMode.displayName)")
                }
            }
            return
        }

        applyMode(newMode, on: environment)
    }

    private func applyMode(_ newMode: CaptureSessionMode, on environment: AppEnvironment) {
        // **不在这里乐观地改 mode。**
        // switchMode 有可能被拒绝（例如当前采集格式不支持 Live Photo），
        // 拒绝后 session 的 mode 不变，也就不会发出 $mode ——
        // 之前那版会让 UI 停在"看着像切了、实际没切"的状态：
        // 模式条高亮 Live、顶栏亮起 LIVE 角标，拍出来却是普通静态照片，
        // 且相册里没有 Live 角标。让 session 成为模式的唯一真源。
        //
        // Log 实况本阶段复用录制链路（见 `CaptureSessionMode.logLive` 的说明）：
        // 进入时先把边界讲清楚，免得用户以为拍完就能在相册里长按播放动图。
        // 若紧接着被 session 拒绝，下面的错误提示会覆盖这条（错误信息优先级更高）。
        if newMode == .logLive {
            showToast("Log 实况：当前录制 Log 视频，套用 LUT 导出实况照片在 P5 交付")
        }
        environment.session.switchMode(to: newMode)
        Haptics.modeChanged()
    }

    // MARK: - 顶栏交互

    /// 顶栏「闪光灯」图标。
    ///
    /// 硬件侧要改 `AVCaptureDevice.torchMode` 与 `AVCapturePhotoSettings.flashMode`
    /// （后者现在被 `PhotoCaptureService.capture()` 固定成 `.off`），属于 P2 参数批次。
    /// 在那之前**不假装切换**：不记住任何"闪光灯已开"的状态，只把边界说清楚
    /// ——记住一个不生效的状态，比不记住更容易让人误判。
    func flashTapped() {
        DebugLog.shared.debug("ui", "闪光灯图标点击（硬件未接入）")
        showToast("闪光灯：切换与常亮在 P2 参数批次接入（AVCaptureDevice.torchMode），当前固定关闭")
    }

    /// 顶栏「网格」图标：**真开关**，与设置页共用 `AppEnvironment.showGrid`
    func gridTapped() {
        guard let environment else { return }
        environment.showGrid.toggle()
        Haptics.tick()
        showToast(environment.showGrid ? "网格线已开" : "网格线已关")
    }

    /// 顶栏副行「影调预览」：真开关，但**当前不改变画面**，必须说明
    func tonePreviewTapped() {
        guard let environment else { return }
        environment.showTonePreview.toggle()
        Haptics.tick()
        showToast(environment.showTonePreview
            ? "影调预览已开：P4 之后取景器会实时叠上风格与滤镜（现在画面还不会变）"
            : "影调预览已关：成片仍按所选风格与滤镜保存")
    }

    /// 顶栏副行「剩余存储」：真数据（约 10 秒刷新一次）
    func storageTapped() {
        guard let environment else { return }
        showToast("剩余可用存储 \(environment.session.freeSpaceText)")
    }

    /// 焦段条点档位。
    ///
    /// **本件只切 UI 状态**：真正的镜头切换与变焦（`applyZoomLocked` 扩成按档切镜头
    /// + `Ramp` 平滑）属于任务书 B 组接线，单独一轮 —— 所以这里明确说明，
    /// 不假装"已经切到 48mm 镜头了"。装成生效比不生效更容易让人误判。
    func focalTapped(_ preset: FocalPreset) {
        guard preset.id != focal.id else {
            // 点已选中的档位：原型是**静默 return**。这里补一次轻触感 ——
            // "点到了、只是本来就选中"应该有个物理反馈，但不必弹提示条刷屏。
            Haptics.tick()
            return
        }
        focal = preset
        Haptics.tick()
        showToast("焦段 \(preset.displayName)mm · 镜头切换与变焦将在 P2 接硬件")
    }

    // MARK: - 相册

    func openSystemPhotos() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url) { success in
            if !success {
                DebugLog.shared.warn("ui", "系统未响应相册跳转（photos-redirect://）")
            }
        }
    }

    // MARK: - 提示条

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            // 用 for: 而不是 nanoseconds:，后者在新 SDK 上已标记弃用
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
