import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 会话配置错误

enum SessionConfigurationError: LocalizedError {
    case noBackCamera
    case inputCreationFailed(String)
    case cannotAddInput
    case cannotAddOutput
    case notRunning

    var errorDescription: String? {
        switch self {
        case .noBackCamera:
            return "找不到可用的后置摄像头（模拟器上没有相机硬件，请用真机运行）"
        case .inputCreationFailed(let message):
            return "创建摄像头输入失败：\(message)"
        case .cannotAddInput:
            return "无法把摄像头输入加入会话"
        case .cannotAddOutput:
            return "无法把输出加入会话"
        case .notRunning:
            return "相机会话尚未就绪"
        }
    }
}

/// 相机会话控制器：`AVCaptureSession` 的生命周期、模式切换、参数入口。
///
/// ## 配置顺序（写死，不可调整）
/// ```
/// 1. session.beginConfiguration()
/// 2. session.sessionPreset = .inputPriority   ← 关键
/// 3. 探测设备 → AVCaptureDeviceInput
/// 4. session.addInput(video)                  ← 必须在设置 activeFormat 之前
/// 5. 按模式 addOutput(...)
/// 6. session.commitConfiguration()
/// 7. 提交之后，才通过 CaptureDeviceConfigurator 写 activeFormat / 帧率
/// ```
///
/// **第 2 步为什么必须是 `.inputPriority`**：`AVCaptureSession` 默认 preset 是 `.high`，
/// 它会替你做格式决策。你在第 7 步写进 `device.activeFormat` 的值，会在会话重新选格式时
/// 被无提示地覆盖掉——表现就是"代码明明设了 30fps，实际还是 60fps"。
/// 切成 `.inputPriority` 后会话完全服从 input 设备的格式，第 7 步的设置才作数。
///
/// **第 7 步为什么必须在 commit 之后**：配置区间内的任何 input/output 变动都可能触发
/// 会话重新协商格式，把之前的设置冲掉。所以格式与帧率一定放在提交之后写。
///
/// ## 线程约定
/// 本类**不加 `@MainActor`**：`startRunning()` 是阻塞调用，绝不能在主线程执行；
/// 会话的配置与启停全部走私有串行队列。所有 `@Published` 属性的写入都通过
/// `publish(_:)` 统一回到主线程，避免 SwiftUI 的"后台线程更新状态"告警。
final class CaptureSessionController: ObservableObject {

    // MARK: - 对外状态

    enum State: Equatable {
        case idle
        case configuring
        case running
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "待机"
            case .configuring: return "配置中"
            case .running: return "运行中"
            case .failed: return "失败"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var mode: CaptureSessionMode = .photo
    @Published private(set) var deviceState = CaptureDeviceState()
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = -2...2
    @Published private(set) var isLivePhotoSupported = false
    @Published private(set) var shutterCount = 0
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var debugSnapshot = CameraDebugSnapshot()

    // MARK: - 会话与设备

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.lumenedit.capture.session", qos: .userInitiated)
    private let configurator = CaptureDeviceConfigurator()
    private let photoService = PhotoCaptureService()
    private let audioSession = AudioSessionManager()

    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private var isConfigured = false
    /// 只在 sessionQueue 上读写的配置完成标志。
    /// 不能直接用 `isConfigured`（@Published）做流程判断——那个值是通过 `publish`
    /// **异步**回到主线程才更新的，在 sessionQueue 上立刻读到可能还是 false。
    private var configurationSucceeded = false
    private var isAppActive = true
    private var isVisible = false
    private var snapshotTimer: Timer?
    private var snapshotTick = 0
    private var lastFreeSpaceText = "—"

    // MARK: - 生命周期

    /// 页面是否可见。只有"可见 + App 在前台"才跑流——
    /// 相机页退到后台还在采集，既耗电又会被系统强杀。
    func setVisible(_ visible: Bool) {
        publish { self.isVisible = visible }
        updateRunState()
    }

    func setAppActive(_ active: Bool) {
        publish { self.isAppActive = active }
        updateRunState()
    }

    private func updateRunState() {
        if isVisible && isAppActive {
            start()
        } else {
            stop()
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            self?.startInternal()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.stopInternal()
        }
    }

    // MARK: - 模式切换

    /// 切模式时**动态增删输出**，而不是让三种输出全部常驻。
    ///
    /// 原因：Live Photo 拍摄与视频录制在底层互斥，全部常驻会出现"某个模式下拍摄静默失败"，
    /// 而且几乎无法从现象定位。按模式重配输出只是一次 `beginConfiguration` 的开销。
    func switchMode(to newMode: CaptureSessionMode) {
        guard newMode != mode else { return }
        guard newMode.isImplemented else {
            let reason = newMode.unavailableReason ?? "该模式暂不可用"
            DebugLog.shared.warn("session", "模式 \(newMode.displayName) 未实现：\(reason)")
            publish { self.lastErrorMessage = reason }
            return
        }

        // Live Photo 还要过设备能力这一关（不是所有设备/格式都支持）。
        // 只在会话已经跑起来、能力值可信时才拒绝——配置完成前这个值是 false，
        // 用它拦会误杀"一进页面就切 Live"的正常操作。
        if newMode == .livePhoto, state == .running, !isLivePhotoSupported {
            let reason = "当前设备或采集格式不支持 Live Photo"
            DebugLog.shared.warn("session", reason)
            publish { self.lastErrorMessage = reason }
            return
        }

        DebugLog.shared.info("session", "切换模式 \(mode.displayName) → \(newMode.displayName)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configureAudioInputLocked(for: newMode)
            self.reconfigureOutputsLocked(for: newMode)
            self.session.commitConfiguration()

            self.photoService.prepareTemplate()
            self.publish { self.mode = newMode }
            self.refreshSnapshot()
        }
    }

    // MARK: - 参数

    func setExposureBias(_ value: Float) {
        guard let device else { return }
        let safeValue = value.sanitized(or: 0).clamped(to: exposureBiasRange)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.applyExposureBias(safeValue, to: device)
                self.publish { self.exposureBias = safeValue }
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "设置曝光补偿失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    /// 点按对焦 / 测光。参数是预览层换算出来的**设备归一化坐标**。
    func focus(atDevicePoint point: CGPoint) {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.setFocusAndExposurePoint(point, on: device)
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "设置对焦点失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    /// 重新应用一份完整预设（P2 的"修图页预设 → 相机"主链路会调它）
    func applyPreset(_ preset: CapturePreset) {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.apply(preset: preset, to: device)
                self.publish {
                    self.exposureBias = preset.exposureBias
                }
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "应用预设失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: - 拍摄

    /// 触发一次拍摄。`completion` 在主线程回调。
    ///
    /// 按当前模式分派：照片模式走静态照片路径；Live Photo 模式走配对路径
    /// （静态照片 + 配对视频两半到齐才产出结果）。
    func capture(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        guard state == .running else {
            let error = SessionConfigurationError.notRunning
            DebugLog.shared.warn("session", "会话未就绪就按了快门")
            publish { self.lastErrorMessage = error.localizedDescription }
            completion(.failure(error))
            return
        }

        publish { self.shutterCount += 1 }

        // 失败时统一在这里把信息推到浮层，两条路径共用
        let handler: (Result<CaptureResult, Error>) -> Void = { [weak self] result in
            if case .failure(let error) = result {
                self?.publish { self?.lastErrorMessage = error.localizedDescription }
            }
            completion(result)
        }

        if mode == .livePhoto {
            photoService.captureLivePhoto(completion: handler)
        } else {
            photoService.capture(completion: handler)
        }
    }

    var isPhotoOutputBusy: Bool { photoService.isBusy }

    // MARK: - 调试快照

    /// 刷新调试快照。
    ///
    /// 整个组装过程**只在主线程执行**：它会读设备属性、查磁盘空间、写 `@Published`。
    /// 从 sessionQueue 调用时自动转到主线程——它只服务于 UI 展示，早一帧晚一帧没关系。
    func refreshSnapshot() {
        if Thread.isMainThread {
            buildSnapshot()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.buildSnapshot()
            }
        }
    }

    private func buildSnapshot() {
        snapshotTick += 1

        var snapshot = CameraDebugSnapshot()
        snapshot.modeText = mode.displayName
        snapshot.sessionStateText = state.text
        snapshot.shutterCountText = "\(shutterCount)"
        snapshot.lastErrorText = lastErrorMessage

        if let device {
            let deviceInfo = configurator.snapshot(of: device)
            snapshot.deviceName = deviceInfo.deviceName
            snapshot.formatText = deviceInfo.formatText
            snapshot.frameRateText = deviceInfo.frameRateText
            snapshot.exposureText = deviceInfo.exposureText
            snapshot.focusText = deviceInfo.focusText
            snapshot.whiteBalanceText = deviceInfo.whiteBalanceText
            deviceState = deviceInfo
        } else {
            snapshot.deviceName = CaptureCapabilities.backCamera() == nil ? "无后置摄像头" : "未连接"
        }
        snapshot.audioText = audioSession.debugDescription()

        // 磁盘空间查询相对昂贵，每 10 次刷新才真正查一次
        if snapshotTick % 10 == 1 {
            lastFreeSpaceText = DeviceStorage.freeSpaceText()
        }
        snapshot.freeSpaceText = lastFreeSpaceText

        debugSnapshot = snapshot
    }

    // MARK: - 私有：会话配置

    private func startInternal() {
        // 用同步标志判断，不能用 @Published 的 isConfigured：
        // 后者是异步回主线程才更新的，在 sessionQueue 上读到可能仍是 false，
        // 会导致重复走一遍配置流程，把已经加好的 input 再加一次而失败。
        if !configurationSucceeded {
            let result = buildSession()
            switch result {
            case .failure(let error):
                DebugLog.shared.error("session", "会话配置失败：\(error.localizedDescription)")
                publish {
                    self.state = .failed(error.localizedDescription)
                    self.lastErrorMessage = error.localizedDescription
                }
                return
            case .success(let device):
                // 提交之后再应用格式与帧率（见类注释的顺序说明）
                applyPreferredFormatLocked(to: device)

                // ⚠️ 必须在格式定下来之后**重新刷新一次 Live Photo 开关**。
                // SDK 头文件 `AVCapturePhotoOutput.h` 写得很明确：
                //   "When this property changes from YES to NO, livePhotoCaptureEnabled
                //    also reverts to NO. If you've previously opted in for Live Photo
                //    capture and then change configurations, you may need to set
                //    livePhotoCaptureEnabled = YES again."
                // 原先只在 beginConfiguration 区间内读过一次能力值，那时设备还是默认格式，
                // 读到的 false 被一路带到了运行期。
                session.beginConfiguration()
                photoService.configure(for: mode)
                session.commitConfiguration()

                photoService.prepareTemplate()

                let livePhotoSupported = photoService.output.isLivePhotoCaptureSupported
                let rangeLower = device.minExposureTargetBias
                let rangeUpper = device.maxExposureTargetBias
                let currentBias = device.exposureTargetBias

                // 同步标志：后续流程判断用它，不能等 @Published 的那次异步回主线程
                configurationSucceeded = true

                publish {
                    self.isConfigured = true
                    self.isLivePhotoSupported = livePhotoSupported
                    self.exposureBiasRange = rangeLower <= rangeUpper ? rangeLower...rangeUpper : -2...2
                    self.exposureBias = currentBias
                }
                DebugLog.shared.info("session", "会话配置完成，Live Photo 支持=\(livePhotoSupported)")
            }
        }

        guard configurationSucceeded else { return }

        // ⚠️ 回到相机页时，如果当前模式需要麦克风，必须把音频会话重新激活。
        //
        // 为什么这里会漏：`stopInternal()`（离开相机页 / 切后台）会
        // `audioSession.deactivate()` 释放音频；但再回来时 `configurationSucceeded`
        // 已经是 true，`buildSession()` 被整个跳过，而 `configureAudioInputLocked`
        // 又因为 `audioInput` 已存在直接 return —— 结果就是**麦克风输入还挂在会话上、
        // 音频会话却是未激活状态**，录出来的 Live Photo 动图没有声音。
        //
        // 真机日志实证（2026-09-16）：14:12–14:17 的 8 张 Live Photo 全部是在
        // 「音频未激活」状态下拍摄的，而 14:22 那批（未离开过页面）音频正常。
        //
        // `mode` 需要麦克风 ⟹ `audioInput != nil`：进入这类模式必经 `switchMode`
        // → `configureAudioInputLocked` 添加输入；而移除输入时模式也必然已经切走。
        if mode.requiresMicrophone, audioInput != nil, !audioSession.isActive {
            do {
                try audioSession.activateForRecording()
            } catch {
                DebugLog.shared.error(
                    "session",
                    "回到相机页时重新激活音频会话失败（Live Photo 可能无声）：\(error.localizedDescription)"
                )
            }
        }

        if !session.isRunning {
            DebugLog.shared.info("session", "startRunning()")
            session.startRunning()
        }

        publish {
            self.state = .running
            self.lastErrorMessage = nil
        }
        refreshSnapshot()
        startSnapshotTimer()
    }

    private func stopInternal() {
        if session.isRunning {
            DebugLog.shared.info("session", "stopRunning()")
            session.stopRunning()
        }
        // 必须释放音频会话：否则退出相机页后，其它 App 的音频仍然被我们占着
        audioSession.deactivate()
        publish { self.state = .idle }
        refreshSnapshot()
        stopSnapshotTimer()
    }

    /// 在 begin/commit 区间内构建会话。返回可作为"格式写入目标"的设备。
    ///
    /// **本方法是幂等的**：入口处会先清空已有的 input / output。
    /// 因为"配置失败 → 用户点重试"的场景下会再进来一次，
    /// 如果上一次已经加进去了一部分（例如 input 成功、output 失败），
    /// 直接再 add 会命中 `canAddInput == false` 而永远修不好。
    private func buildSession() -> Result<AVCaptureDevice, Error> {
        session.beginConfiguration()
        // 关键顺序 1：必须先设 preset，且必须是 .inputPriority
        session.sessionPreset = .inputPriority

        // 幂等清理
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        videoInput = nil
        audioInput = nil
        device = nil

        var outcome: Result<AVCaptureDevice, Error> = .failure(SessionConfigurationError.noBackCamera)

        if let device = CaptureCapabilities.backCamera() {
            do {
                // 关键顺序 2：input 必须在设置 activeFormat 之前加入
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    videoInput = input
                    self.device = device
                    outcome = .success(device)
                } else {
                    outcome = .failure(SessionConfigurationError.cannotAddInput)
                }
            } catch {
                outcome = .failure(SessionConfigurationError.inputCreationFailed(error.localizedDescription))
            }
        }

        if case .success = outcome {
            configureAudioInputLocked(for: mode)
            let outputsOK = reconfigureOutputsLocked(for: mode)
            if !outputsOK {
                outcome = .failure(SessionConfigurationError.cannotAddOutput)
            }
        }

        session.commitConfiguration()
        return outcome
    }

    /// 挑选并应用采集格式（必须在 commitConfiguration 之后调用）。
    ///
    /// **为什么不能直接拿候选里的第一个**：
    /// `AVCaptureDeviceFormat` 不暴露任何"支不支持 Live Photo"的属性，
    /// 唯一可信的判据是格式应用到设备之后读
    /// `AVCapturePhotoOutput.isLivePhotoCaptureSupported`。
    ///
    /// 真机实测（iPhone 16 Pro / iOS 26.6）：原先按"4:3 → 面积最小"选中的
    /// `1920x1440` 是视频向格式，它的 Live Photo 能力为 `false`，
    /// 于是切「Live」被 `switchMode` 拦下、拍出来的只有静态照片，
    /// 相册里自然没有 Live 角标、也放不出动图。
    ///
    /// 所以这里按候选顺序逐个应用，**取第一个 Live Photo 能力为 true 的**；
    /// 若全都不支持（或探测本身不可靠），退回第一个候选，
    /// 行为与改动前一致，不影响普通拍照。
    private func applyPreferredFormatLocked(to device: AVCaptureDevice) {
        let candidates = CaptureCapabilities.formatCandidates(
            for: device,
            minimumWidth: 1920,
            targetFrameRate: 30
        )

        guard !candidates.isEmpty else {
            DebugLog.shared.warn("session", "没有找到满足条件的采集格式，沿用设备默认格式")
            return
        }

        var fallback: AVCaptureDevice.Format?
        var chosen: AVCaptureDevice.Format?

        for candidate in candidates {
            do {
                try configurator.applyFormat(candidate, frameRate: 30, to: device)
            } catch {
                DebugLog.shared.error("session", "应用采集格式失败：\(error.localizedDescription)")
                continue
            }
            if fallback == nil { fallback = candidate }
            if photoService.output.isLivePhotoCaptureSupported {
                chosen = candidate
                break
            }
        }

        // 兜底路径下循环可能停在"最后一个试过且不支持 Live Photo"的格式上，
        // 这里把设备还原到第一个候选，保证普通拍照用的是最小的那一档。
        let final = chosen ?? fallback
        if let final, final !== device.activeFormat {
            do {
                try configurator.applyFormat(final, frameRate: 30, to: device)
            } catch {
                DebugLog.shared.error("session", "回退采集格式失败：\(error.localizedDescription)")
            }
        }

        guard let final else { return }
        DebugLog.shared.info(
            "session",
            "选用采集格式 \(CaptureCapabilities.formatSummary(final))"
            + "，Live Photo 能力=\(photoService.output.isLivePhotoCaptureSupported)"
            + "（候选共 \(candidates.count) 个）"
        )
    }

    /// 音频输入按需增删：只有需要麦克风的模式（Live Photo / 视频）才挂。
    /// 不需要时移除可以省电，也避免占用音频资源影响其它 App。
    ///
    /// 同时负责音频会话的激活与释放——两者必须成对：
    /// 只加 input 不激活音频会话，录出来的视频会是**无声的**；
    /// 只激活不释放，用户的音乐 App 会一直不出声。
    private func configureAudioInputLocked(for targetMode: CaptureSessionMode) {
        let needsAudio = targetMode.requiresMicrophone

        if needsAudio {
            guard audioInput == nil else { return }
            guard let microphone = CaptureCapabilities.microphone() else {
                DebugLog.shared.warn("session", "找不到麦克风设备")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: microphone)
                if session.canAddInput(input) {
                    session.addInput(input)
                    audioInput = input
                    DebugLog.shared.info("session", "已加入麦克风输入")

                    // 音频会话激活失败不阻断拍摄流程：用户可能只是没给麦克风权限，
                    // 画面依然可以录，只是没有声音——这比直接失败体验更好。
                    do {
                        try audioSession.activateForRecording()
                    } catch {
                        DebugLog.shared.error("session", "音频会话激活失败：\(error.localizedDescription)")
                    }
                }
            } catch {
                DebugLog.shared.error("session", "创建麦克风输入失败：\(error.localizedDescription)")
            }
        } else {
            if let existing = audioInput {
                session.removeInput(existing)
                audioInput = nil
                DebugLog.shared.info("session", "已移除麦克风输入")
            }
            audioSession.deactivate()
        }
    }

    /// 按模式重建输出组合。调用方必须已经在配置区间内。
    /// - Returns: 是否成功
    @discardableResult
    private func reconfigureOutputsLocked(for targetMode: CaptureSessionMode) -> Bool {
        // 先清空所有输出，保证不会残留上一个模式的输出
        for output in session.outputs {
            session.removeOutput(output)
        }

        switch targetMode {
        case .photo, .livePhoto:
            guard session.canAddOutput(photoService.output) else {
                DebugLog.shared.error("session", "无法加入照片输出")
                return false
            }
            session.addOutput(photoService.output)
            photoService.configure(for: targetMode)
            applyRotationLocked(to: photoService.output)
            return true

        case .video:
            // ⚠️ P1a 里这个分支**不可达**：CaptureSessionMode.video.isImplemented == false，
            // UI 与 switchMode 都会先拦下来。保留它只是为了模式枚举完整。
            //
            // 这里刻意只挂照片输出，**不引用任何尚未实现的类型**（例如将来的录制服务），
            // 保证 P1a 一定能编译通过。P1b 打开视频模式时，在本分支里换成
            // 录制输出即可（届时会新增对应的 Service 文件）。
            guard session.canAddOutput(photoService.output) else { return false }
            session.addOutput(photoService.output)
            photoService.configure(for: .photo)
            applyRotationLocked(to: photoService.output)
            return true
        }
    }

    /// 竖屏锁定，所以旋转角是固定值 90°，不需要监听设备方向。
    /// 这一条省掉了后面 Live Photo 与视频导出的一整套方向修正逻辑。
    private func applyRotationLocked(to output: AVCaptureOutput) {
        guard let connection = output.connection(with: .video) else { return }
        let angle: CGFloat = 90
        guard connection.isVideoRotationAngleSupported(angle) else {
            DebugLog.shared.warn("session", "连接不支持 90° 旋转角")
            return
        }
        connection.videoRotationAngle = angle
    }

    // MARK: - 私有：工具

    /// 计时刷新调试快照——对焦、ISO 这些值会随时间变化，只在操作后刷新看不到中间状态。
    private func startSnapshotTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshotTimer?.invalidate()
            self.snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshSnapshot()
            }
        }
    }

    private func stopSnapshotTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.snapshotTimer?.invalidate()
            self?.snapshotTimer = nil
        }
    }

    /// 统一把状态写入主线程。所有 `@Published` 的赋值都必须包在这里面。
    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
