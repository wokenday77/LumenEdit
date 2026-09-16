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
                showToast("视频已保存")
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
        environment.session.switchMode(to: newMode)
        Haptics.modeChanged()
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
