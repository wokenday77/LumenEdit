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

    /// 手动曝光档的当前值（`nil` = **自动档**）。**从设备回读**，不是本地记账。
    ///
    /// 见 `docs/16` 第六节：`exposureMode` 是同一个 device 实例上的真值，切模式不换 device
    /// ⇒ 手动档会活下来 —— 本地记账必然出现"UI 说自动、设备是手动"。
    @Published private(set) var manualExposure: (iso: Float, seconds: Double)?

    /// 手动白平衡档的当前值（`nil` = 自动档）。同样从设备回读。
    @Published private(set) var manualWhiteBalance: (temperature: Float, tint: Float)?

    /// 三条刻度条在这台设备上**不可用**的档位值（UI 置灰用；空字典 = 还没算过）。
    ///
    /// 会话就绪 / 切模式 / 每次手动写入后重算 —— 因为设备可用域随 `activeFormat` 变。
    @Published private(set) var unavailableStripValues: [ParameterStripKind: Set<Double>] = [:]

    /// 设备**当前**的 ISO / 曝光时长（**自动档也有效** —— 取 AE 的收敛值）。
    /// 自动 → 手动切换时用作初值（拍板 ③：切档瞬间画面不跳）。
    @Published private(set) var currentExposure: (iso: Float, seconds: Double) = (100, 1.0 / 125)

    /// 设备**当前**的色温（**自动档也有效** —— 取 AWB 的收敛值）。同上，用作切手动时的初值。
    @Published private(set) var currentWhiteBalanceKelvin: Float = 5600

    /// 当前设备上**不可用**的焦段档位 id 集合（B1 置灰用）。
    ///
    /// 判据在 `CaptureCapabilities.unavailableFocalIds(for:)`：档位换算出的 zoom 落不进
    /// 设备的可用区间（典型：单摄设备上的 13mm 档）。
    /// 会话配置完成后计算一次 —— 它只随设备/格式变化，不随拍摄状态变。
    @Published private(set) var unavailableFocalIds: Set<String> = []
    @Published private(set) var isLivePhotoSupported = false
    @Published private(set) var shutterCount = 0
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var debugSnapshot = CameraDebugSnapshot()

    /// 剩余可用存储的可读文本（如 "31 GB"）。顶栏副行的「剩余存储」胶囊直接读它。
    ///
    /// 为什么单独拎成 `@Published`，而不是让 UI 去读 `debugSnapshot.freeSpaceText`：
    /// 存储是**拍摄关键信息**，不该挂在"调试图层"的数据上 —— 调试浮层以后可能被删掉，
    /// 而这颗胶囊要一直在。刷新沿用快照那套节流（约 10 秒一次，见 `buildSnapshot`），
    /// 不为它单开一个定时器。
    @Published private(set) var freeSpaceText = "—"

    // MARK: - 会话与设备

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.lumenedit.capture.session", qos: .userInitiated)
    private let configurator = CaptureDeviceConfigurator()
    private let photoService = PhotoCaptureService()
    private let movieService = MovieCaptureService()
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

    /// 冷启动那几帧白平衡**尚未初始化**（`deviceWhiteBalanceGains` 无效，
    /// 此时调 `temperatureAndTintValues(for:)` 会抛 ObjC 异常 → 全进程 abort，
    /// 见 `CaptureDeviceConfigurator.temperatureAndTintValues(of:)` 的说明）。
    ///
    /// 置位后，快照轮询（每秒一次）发现增益就绪时会**补发一次**手动档状态，
    /// 免得 UI 一直停在兜底值 5600K 上（2026-09-19 用户提的"可选加固"，已做）。
    private var needsColdWhiteBalanceRefresh = false
    private var snapshotTimer: Timer?
    private var snapshotTick = 0

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

        // 录制中不允许切模式：换模式会重配 session 输出，
        // 正在写入的文件会被中途截断（产物损坏）。
        guard !movieService.isRecording else {
            DebugLog.shared.warn("session", "录制中不允许切换模式")
            publish { self.lastErrorMessage = "请先停止录制再切换模式" }
            return
        }

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

            self.preparePhotoTemplateIfNeeded(for: newMode)
            self.publish { self.mode = newMode }
            // 切模式重配了输出、`activeFormat` 可能跟着变 → 手动档真值与刻度条可用域重算一次
            // （手动档本身会活下来：换的是 output，不是 device）
            if let device = self.device {
                self.publishManualState(device)
            }
            self.refreshSnapshot()
        }
    }

    /// 准备照片设置模板 —— **只在照片类模式下有意义**。
    ///
    /// 录制类模式（视频 / Log 实况）的 session 里挂的是 `movieService.output`，
    /// 根本没挂 `photoService.output`。此时 `AVCapturePhotoOutput.availablePhotoCodecTypes`
    /// 是空的，硬跑一遍 `prepareTemplate()` 必然打出
    /// 「声明的编码格式不可用，回退到默认设置」——**那是假告警**：
    /// 编码格式没有任何问题，只是这个模式下用不到照片输出。
    ///
    /// 为什么必须掐掉它：真机侧载没有 Xcode 控制台，调试浮层里的告警是主要排障手段
    /// （见 `docs/04` 第八节与 `AppEnvironment.showDebugHUD` 的说明）。
    /// 一条"每次进 Log 实况都必然出现"的假告警，会把真正有价值的告警淹没掉。
    private func preparePhotoTemplateIfNeeded(for targetMode: CaptureSessionMode) {
        guard !targetMode.isRecordingBased else {
            DebugLog.shared.debug("photo", "\(targetMode.displayName)：录制链路不挂照片输出，跳过照片模板准备")
            return
        }
        photoService.prepareTemplate()
    }

    // MARK: - 参数

    /// 运行时**平滑变焦**（B1：焦段药丸点击）。
    ///
    /// ## 会话稳定性：这里**不重建会话**
    ///
    /// 设备回退链本来就是**虚拟多摄优先**（`.builtInTripleCamera` 起），
    /// 越过系统的切换点时由系统内部换 constituent 镜头 —— 采集图没变
    /// （同一个虚拟设备、同一个 input），所以只需要 `lock → ramp → unlock`。
    ///
    /// ⚠️ **不要**在这里用"模式切换那套动态增删 output"（`reconfigureOutputsLocked`）：
    /// 那套是给"采集图真的变了"用的（照片↔视频），套到变焦上会平白引入重建停顿。
    ///
    /// - Parameters:
    ///   - animated: `false` 时用极短时长（≈ 直接设值的效果），留给"需要瞬移"的场景
    ///   - completion: 回主线程回调**实际生效**的 zoom（已 clamp），供 UI 对账
    func setZoomFactor(
        _ target: CGFloat,
        animated: Bool = true,
        completion: ((CGFloat) -> Void)? = nil
    ) {
        guard let device else { return }
        let duration = animated
            ? CaptureDeviceConfigurator.zoomRampDuration
            : CaptureDeviceConfigurator.zoomRampDuration * 0.03

        // 与其它设备配置一致：都在 sessionQueue 上串行执行（不会与配置变更/曝光写入打架）
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let applied = self.configurator.applyZoomRamp(
                targetZoomFactor: target,
                duration: duration,
                to: device
            )
            self.refreshSnapshot()
            if let completion {
                self.publish { completion(applied) }
            }
        }
    }

    /// 按焦段档位变焦（B1）。
    ///
    /// **换算放在这里而不是 ViewModel**：档位 → `videoZoomFactor` 要读**设备自身**的镜头构成
    /// 与系统切换点（`CaptureCapabilities.zoomFactor(forFocal:of:)`），那是会话层的知识；
    /// VM 只管"用户点了哪个档"（分层纪律：UI 不碰设备细节）。
    ///
    /// ⚠️ 换算**不再用 `mm ÷ 基准`**（2026-09-19 Mac 实测：虚拟基准是**机型相关**的，
    /// 那台机是 12mm 而不是文档假设的 13mm；硬除会让 120mm 档落在 `switchOver[1]` 之下，
    /// 系统不切长焦、只用主摄数码放大）。
    ///
    /// - Parameter completion: 回主线程回调 `(实际生效 zoom?, 是否被 clamp)`；
    ///   这台设备没有该档需要的镜头时第一个参数为 `nil`
    func applyFocal(
        _ preset: FocalPreset,
        animated: Bool = true,
        completion: ((_ applied: CGFloat?, _ wasClamped: Bool) -> Void)? = nil
    ) {
        guard let device else {
            completion?(nil, false)
            return
        }
        guard let zoom = CaptureCapabilities.zoomFactor(forFocal: preset, of: device) else {
            // 该档在这台设备上表达不了（缺那颗镜头）。正常路径上 UI 已置灰 + 会给 toast；
            // 万一还是漏到这里，也**不推硬件** —— 不装作切过去了。
            DebugLog.shared.debug(
                "session",
                "焦段 \(preset.displayName)mm 在本机没有对应镜头，未推硬件"
            )
            completion?(nil, false)
            return
        }

        // 预先判断"会不会被 clamp"：真正 clamp 发生在 configurator 里，
        // 这里算一次是为了**如实告知用户**（不假装切到了标称档位）
        let range = CaptureCapabilities.zoomRange(of: device)
        let willClamp = zoom < range.lowerBound - 0.01 || zoom > range.upperBound + 0.01

        setZoomFactor(zoom, animated: animated) { applied in
            completion?(applied, willClamp)
        }
    }

    func setExposureBias(_ value: Float) {
        guard let device else { return }
        let safeValue = value.sanitized(or: 0).clamped(to: exposureBiasRange)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.applyExposureBias(safeValue, to: device)
                self.publish { self.exposureBias = safeValue }
                // EV 写入可能把设备从手动曝光档**回切到自动档**（configurator 里有这条防线，
                // 且会打 warn）→ 手动档真值变了，必须重发，否则 UI 会一直显示"手动"。
                self.publishManualState(device)
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "设置曝光补偿失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: - 手动曝光 / 手动白平衡（B2 · 刻度条接线）

    /// 切到**手动曝光档**（ISO 与快门**一起**写 —— 刻度条拖动时每跨一档调一次）。
    ///
    /// ⚠️ EV 与手动档互斥：手动档下 `setExposureTargetBias` 会被系统忽略，
    /// 而 `applyExposureBias` 还会把设备**回切到自动档**（`docs/16` 第五节）。
    /// UI 侧必须拦住（`CameraViewModel.exposureEditingChanged` 的守卫），这里不再重复判。
    func setManualExposure(iso: Float, seconds: Double) {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.setManualExposure(iso: iso, seconds: seconds, on: device)
                self.publishManualState(device)
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "切手动曝光失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    /// 曝光回到**自动档**（刻度条右端开关切回自动）
    func setAutoExposure() {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.setAutoExposure(on: device)
                self.publishManualState(device)
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "切回自动曝光失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    /// 切到**手动白平衡档**（只给色温；**色调跟随设备当前值**，避免"调色温顺手改了色调"）
    func setManualWhiteBalance(kelvin: Float) {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                let tint = self.configurator.currentTint(of: device)
                try self.configurator.setManualWhiteBalance(
                    temperature: kelvin,
                    tint: tint,
                    on: device
                )
                self.publishManualState(device)
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "切手动白平衡失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    /// 白平衡回到**自动档**（连续 AWB）
    func setAutoWhiteBalance() {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.setAutoWhiteBalance(on: device)
                self.publishManualState(device)
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "切回自动白平衡失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    /// **一次刷新**"手动档真值 + 刻度条可用域"并发布给 UI。
    ///
    /// 调用点（每一处设备可能改变曝光/白平衡档位的地方都要调）：
    ///   - 4 个手动写入之后
    ///   - `setExposureBias`（它可能把设备从手动档回切自动档）
    ///   - `focus(atDevicePoint:)`（点按对焦会把 `exposureMode` 设成连续自动！）
    ///   - `applyPreset`（预设会重设曝光与白平衡）
    ///   - 会话就绪 / 切模式之后
    ///
    /// ⚠️ **不要放进每秒的 `refreshSnapshot` 定时器**：那会让 UI 每秒收到一次
    /// 值没变的 `@Published`（同值也发），白白触发重算。手动档只在以上时机变。
    private func publishManualState(_ device: AVCaptureDevice) {
        let exposure = configurator.manualExposure(of: device)
        let whiteBalance = configurator.manualWhiteBalance(of: device)
        // "当前值"与"是否手动"是两件事：自动档下也要给出 AE / AWB 的收敛值，
        // 那是"自动→手动"切换时的初值（否则初值只能瞎猜或退化成常量）。
        let currentISO = device.iso
        let currentSeconds = device.exposureDuration.safeSeconds
        let currentKelvin = configurator.currentTemperature(of: device)
        var unavailable: [ParameterStripKind: Set<Double>] = [:]
        for kind in ParameterStripKind.allCases {
            unavailable[kind] = CaptureCapabilities.unavailableStripValues(for: kind, on: device)
        }
        // 冷启动那几帧白平衡还没初始化（增益无效 → `temperatureAndTintValues(for:)` 会抛异常，
        // 见 `CaptureDeviceConfigurator.temperatureAndTintValues(of:)` 的说明），
        // 此时色温只能给兜底值 5600K。记一笔，等快照轮询发现增益就绪时**补发一次**，
        // 免得 UI 一直停在兜底值上（2026-09-19 用户提的"可选加固"，已做）。
        needsColdWhiteBalanceRefresh = !configurator.hasValidWhiteBalanceGains(device)
        if needsColdWhiteBalanceRefresh {
            DebugLog.shared.debug("session", "白平衡增益尚未就绪（冷启动）→ 色温先给兜底值，就绪后补发")
        }
        publish {
            self.manualExposure = exposure
            self.manualWhiteBalance = whiteBalance
            self.currentExposure = (currentISO, currentSeconds)
            self.currentWhiteBalanceKelvin = currentKelvin
            self.unavailableStripValues = unavailable
        }
    }

    /// 点按对焦 / 测光。参数是预览层换算出来的**设备归一化坐标**。
    func focus(atDevicePoint point: CGPoint) {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.setFocusAndExposurePoint(point, on: device)
                // ⚠️ 点按对焦会把 `exposureMode` 设成**连续自动曝光** —— 也就是说
                // 手动 ISO/快门 档会被它顶掉（这是系统语义，不是 bug）。
                // 所以必须重发手动档真值，让 UI 立刻回到"自动"（否则用户会以为还锁着）。
                self.publishManualState(device)
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
                // 预设会重设曝光（ISO/快门 或 EV）与白平衡 → 手动档真值可能整片变了
                self.publishManualState(device)
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

    // MARK: - 视频录制（P1b-2）

    /// 当前是否在录制视频
    var isRecording: Bool { movieService.isRecording }

    /// 录制时长心跳（秒），供 UI 计时。setter 转发给录制服务。
    var onRecordingTick: ((TimeInterval) -> Void)? {
        get { movieService.onTick }
        set { movieService.onTick = newValue }
    }

    /// 开始录制。只在**录制类模式（视频 / Log 实况）且会话就绪**时有效。
    ///
    /// 与 `capture(completion:)` 的区别：那个是"一次性快门"，
    /// 这个的开始/停止跨越一段时间，产物要等停止后的代理回调。
    /// 是否录制类由 `CaptureSessionMode.isRecordingBased` 判定 —— 单一真相，
    /// 避免"这里说 video、那里忘了加 logLive"导致按快门没反应。
    func startRecording(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        guard mode.isRecordingBased else {
            let error = MovieCaptureError.notReady
            DebugLog.shared.warn("session", "非视频模式下请求开始录制（当前 \(mode.rawValue)）")
            publish { self.lastErrorMessage = error.localizedDescription }
            completion(.failure(error))
            return
        }
        guard state == .running else {
            let error = SessionConfigurationError.notRunning
            DebugLog.shared.warn("session", "会话未就绪就请求录制")
            publish { self.lastErrorMessage = error.localizedDescription }
            completion(.failure(error))
            return
        }

        movieService.startRecording { [weak self] result in
            if case .failure(let error) = result {
                self?.publish { self?.lastErrorMessage = error.localizedDescription }
            }
            completion(result)
        }
    }

    /// 请求停止录制。产物仍走开始录制时传入的那个 completion。
    func stopRecording() {
        movieService.stopRecording()
    }

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
        // 冷启动白平衡**就绪后的补发**（每秒查一次，就绪即补，只补一次 —— 见 `publishManualState`）
        if needsColdWhiteBalanceRefresh, let device,
           configurator.hasValidWhiteBalanceGains(device) {
            needsColdWhiteBalanceRefresh = false
            DebugLog.shared.debug("session", "白平衡增益已就绪（冷启动）→ 补发手动档状态")
            publishManualState(device)
        }

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
            freeSpaceText = DeviceStorage.freeSpaceText()
        }
        snapshot.freeSpaceText = freeSpaceText

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

                preparePhotoTemplateIfNeeded(for: mode)

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
                    // 焦段档位可用性（B1）：随设备/格式而定，配置完成后算一次
                    self.unavailableFocalIds = CaptureCapabilities.unavailableFocalIds(for: device)
                }
                // B1 ④ 核法升级：把"变焦拓扑"打成一**行硬数据**（设备类型 / constituent 数量 /
                // 超广角可达 / 换算基准 / `virtualDeviceSwitchOverVideoZoomFactors` / zoomRange）。
                //
                // 为什么要有它：方案第四节那个前提（"虚拟设备的 videoZoomFactor = 1.0 是最广
                // constituent 的 native 视场"）原本要靠"设 1.0 拍一张、与相册里的 13mm 参考
                // 对比视场"来核 —— 那是一次要动相机、要人工看图、还带主观判断的验证。
                // 现在改成**读一次冷启动日志**：switchOver 与映射表算出的切换点（1.85 / 9.23）
                // 对得上就是对得上，对不上就把映射表整体平移（改 4 个常量）。
                DebugLog.shared.info(
                    "session",
                    CaptureCapabilities.zoomTopologyDescription(of: device)
                )
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

        // 会话就绪：**按设备真值刷新手动档状态 + 刻度条可用域**。
        // 为什么放这里而不是上面那个配置块里：配置块只跑一次（`configurationSucceeded` 守着），
        // 而"就绪"每次都会到（冷启动 / 返回相机页 / 切模式）；而且设备可用域随 `activeFormat` 变，
        // 必须在格式定下来之后读。
        if let device {
            publishManualState(device)
        }

        publish {
            // ⚠️ **同值不重发**（`@Published` 是 willSet 语义 —— 赋一个相同的值同样会发通知）。
            //
            // 为什么必须防：冷启动时 `startInternal()` 会被走**两次** ——
            //   ① `onAppear` → `setVisible(true)` → `updateRunState()` → `start()`
            //   ② scenePhase 变 active → `setAppActive(true)` → `updateRunState()` → `start()`
            // 第二次时 `configurationSucceeded` 已是 true，重建被跳过，但**仍会走到这里**；
            // 于是 `.running` 被发两遍 → 订阅方"会话就绪"的副作用（按档位对齐一次 zoom、
            // 清空 EV 回写记录）跟着跑两遍 —— 真机日志里同一帧打印两遍"焦段已对齐"。
            //
            // 修法分两层：这里是**根因层**（状态没变就不该发通知）；
            // `CameraViewModel` 那边还有一道 `removeDuplicates()` 兜住其它路径。
            if self.state != .running {
                self.state = .running
            }
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

        case .video, .logLive:
            // P1b-2 起这一支挂真正的录制输出（切换逻辑见本函数开头：先清空所有输出）。
            // 视频与照片输出互斥 —— 所以这里**只**挂 movieService.output，不挂 photoOutput。
            //
            // `.logLive` 复用同一条链路（P2 打开入口）：Log 实况的产物本身就是一段视频
            // （套 LUT 导出为实况照片在 P5）。挂同一个输出保证"进去就能录"，不会出现
            // 进了模式却无法拍摄的状态。二者若要分道（例如 Log 要设 appleLog 色彩空间），
            // 在 MovieCaptureService 里按 mode 分派，不要在这里拆成两个 output。
            guard session.canAddOutput(movieService.output) else {
                DebugLog.shared.error("session", "无法加入录制输出")
                return false
            }
            session.addOutput(movieService.output)
            applyRotationLocked(to: movieService.output)
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
