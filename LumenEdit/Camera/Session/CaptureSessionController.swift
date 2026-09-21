import AVFoundation
import CoreGraphics
import Darwin
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

/// 采集格式探测缓存的**落盘键**（跨 App 启动复用；格式对象本身不能存盘，存"标识"）。
///
/// 见 `CaptureSessionController.formatProbeIdentities` 的说明。
private let formatProbeCacheDefaultsKey = "lumen.camera.formatProbeCache"

// MARK: - 静默换形态的结果

/// `applyFocalTargetSilently` 的**结果回执**（批五 · 问题 1③）。
///
/// 为什么需要它：入口（点手动开关 / 点「对焦」）的排队原来是"盲等 1.2s，超时就退转场"——
/// 而**冷探测首次换设备要 4.2~5.0s**（Mac 批四复验实锤），于是"必然退转场"，
/// 用户看到的还是那 0.85~1.0s 的模糊（问题 1 的现象）。
/// 盲等的病根是**分不清"慢"和"没做"**：慢应该继续等，没做才该退转场。
enum SilentSwitchOutcome {

    /// 真的换了设备（形态已落定 → 调用方挂在 `form` 边沿的待执行动作会被触发）
    case switched

    /// 目标形态**本来就已满足**（无需换设备）→ 调用方应**直接执行**动作，不能等边沿
    /// （等下去 `form` 不会再变 = 永远等不到 = "点了没反应"）
    case alreadySatisfied

    /// **这次没做**（录制中 / 会话未就绪 / 真转场让路）→ 调用方应退回"转场"路径
    case skipped
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
/// 会话形态（物理架构 `docs/20`）：虚拟多摄（平滑变焦）或物理单摄（手动参数可用）。
///
/// - **冷启动默认 `.virtual`**（按需策略：自动档保住 B1 的平滑变焦）。
/// - 进入任一手动档 → `.physical(当前档位)`；全手动档退出持续 2s 防抖 → 切回 `.virtual`
///  （防抖在 VM 层，session 只执行）。
/// - 写入点唯一：`performFocalSwitch`（三个调用者：`beginFocalSwitch` /
///   `commitFocalSwitch` / `applyFocalTargetSilently`，自检⑲）。
enum SessionForm: Equatable {
    case virtual
    case physical(FocalPreset)

    var isPhysical: Bool {
        if case .physical = self { return true }
        return false
    }
}

/// 会话形态的**切换目标**（VM 把用户动作翻译成它；`performFocalSwitch` 只管执行）。
///
/// 两个 case 都带目标档位：切回虚拟后要把 zoom 对齐到当前档位（虚拟阶梯），
/// 切到物理后要对齐到 `zoomFactorOnPhysicalDevice`。
enum FocalTarget: Equatable {
    case virtual(focal: FocalPreset)
    case physical(focal: FocalPreset)

    /// 日志用描述
    var describe: String {
        switch self {
        case .virtual(let f): return "虚拟多摄（\(f.displayName) mm）"
        case .physical(let f): return "物理单摄（\(f.displayName) mm）"
        }
    }
}

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

    /// 设备**当前格式**实读的 ISO 上限（`activeFormat.maxISO`）—— ISO 刻度条的**末档**。
    ///
    /// 2026-09-21 批六（复刻飓风 · 方案 A）：用户拍板末档用**设备实读值**，不写行业表的 12800
    /// （本机三摄实读 = **12096**，与日志实锤同值）。
    /// ⚠️ 只从会话往外发（UI 层不碰设备，`docs/04` 分层纪律）—— 视图拿它重建档位表，
    /// `CaptureCapabilities` 那边仍按 `activeFormat.minISO...maxISO` 做"可用域求交"。
    @Published private(set) var stripISOMax: Double?

    /// 手动对焦档（**用户意图态** · 2026-09-20 正源修）。
    ///
    /// ## 为什么不能从硬件回读推断（Mac 复验 ③ 的根因链，`backlog ⑩`）
    ///
    /// SDK 行为：`.autoFocus` **对焦一次完成后系统自动转 `.locked`** —— 硬件回读
    /// `focusMode == .locked` 分不清"用户在对焦盘锁的"和"系统自动锁的"。
    /// 曾经从回读推断 → 点按对焦一次后 `manualFocus` 非 nil → `isFocusManual` 永久为真
    /// → 点按全走"仅测光"（该路径不碰 focusMode）→ **死锁：点按对焦永久失效**（真机实测）。
    ///
    /// ## 正源修：意图驱动
    ///
    /// - **写入点只有两个意图入口**：`setManualFocus(lensPosition:)`（盘上拖动 / 关自动开关）
    ///   置值；`setAutoFocusMode()` 置 `nil`。**`publishManualState` 绝不写它**
    ///   （自检⑱守着：同源污染回归当场 FAIL）。
    /// - **回读只喂 `currentLensPosition`**（读数，自动/手动都跟硬件）。
    /// - 换设备（物理架构 `docs/18` 2.4）后按方案**显式降级**：换设备方法置 `nil`（意图清除），
    ///   不靠回读推断。
    @Published private(set) var manualFocus: Float?

    /// 设备**当前**的镜头位置（0~1；**自动档也有效** —— 自动对焦进行中实时跟随）。
    /// 对焦圆盘的读数源：手动锁定时它就是锁定值（恒定），自动对焦时读数"自己会走"。
    @Published private(set) var currentLensPosition: Float = 0.5

    /// 手动对焦在这台设备上是否可用（虚拟多摄不支持 → `false` = 对焦盘入口 toast 不开盘）。
    /// 与 `isManualExposureSupported` / `isManualWhiteBalanceSupported` 同款能力探测。
    @Published private(set) var isManualFocusSupported = false

    /// 三条刻度条在这台设备上**不可用**的档位值（UI 置灰用；空字典 = 还没算过）。
    ///
    /// 会话就绪 / 切模式 / 每次手动写入后重算 —— 因为设备可用域随 `activeFormat` 变。
    @Published private(set) var unavailableStripValues: [ParameterStripKind: Set<Double>] = [:]

    /// 手动参数档在**当前设备**上是否真的可用（`false` = UI 把手动开关置灰）。
    ///
    /// ## 为什么需要这两个位 —— 2026-09-19 架构级发现
    ///
    /// SDK 明文（`AVCaptureDevice.h:538-541`）：虚拟多摄（`.builtInTripleCamera` 等）
    /// **不支持** ① `.custom` 曝光（手动 ISO/快门）、② 非 Current 的白平衡增益锁定。
    /// 而白平衡那条曾用 `isWhiteBalanceModeSupported(.locked)` 探测 → 虚拟设备上误报 true
    /// → 写计算增益直接抛 ObjC 异常（真机 7 次同源崩溃，见 `CaptureDeviceConfigurator`）。
    ///
    /// 这两个位 = `CaptureCapabilities` 的能力探测结果（不写机型判断），会话就绪 /
    /// 切模式等时机随 `publishManualState` 一起重算。物理镜头架构（`docs/18`）落地后
    /// 探测自动变 true，UI 无需改动。会话未就绪时保持 `false`（宁可先灰后开，
    /// 不装作可用 —— "点了没反应"禁令）。
    @Published private(set) var isManualExposureSupported = false
    @Published private(set) var isManualWhiteBalanceSupported = false

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

    /// 当前会话形态（`docs/20`）。**写入点唯一** = `performFocalSwitch`。
    @Published private(set) var form: SessionForm = .virtual

    /// 换设备进行中（模糊转场驱动位，顺序触发 —— 预检 ⑧）。
    /// `true` = UI 淡入模糊 → 完成回调才允许真正换设备（VM `commitFocalSwitch`）。
    @Published private(set) var isLensSwitching = false

    /// 会话未就绪时排队的焦段目标（预检 ②）；`startInternal` 就绪分支补执行。
    private var pendingFocalTarget: FocalTarget?

    /// 顺序触发第一段存下的换设备目标（`beginFocalSwitch` 存、`commitFocalSwitch` 取）。
    private var pendingSwitchTarget: FocalTarget?
    private var audioInput: AVCaptureDeviceInput?

    private var isConfigured = false
    /// 只在 sessionQueue 上读写的配置完成标志。
    /// 不能直接用 `isConfigured`（@Published）做流程判断——那个值是通过 `publish`
    /// **异步**回到主线程才更新的，在 sessionQueue 上立刻读到可能还是 false。
    private var configurationSucceeded = false

    /// `mode` 的**同步镜像**（批六 ② 修复 · P0-2 · 2026-09-21）。
    ///
    /// ## 为什么必须镜像（与 `configurationSucceeded` 同一类坑）
    ///
    /// `mode` 是 `@Published`，**唯一写入点**在 `switchMode` 的 `publish{}` 里 —— 也就是
    /// **主线程、异步**（`publish` 在非主线程时走 `DispatchQueue.main.async`）。而
    /// `startPrewarmIfNeeded` 跑在 `sessionQueue` 上，直接读 `mode` 会拿到**旧值**。
    ///
    /// 预热拿 `mode` 做两件事，读旧值**两件都错**：
    /// ① 判断"当前模式该不该预热"（旧值 → 该跳的时候不跳、不该探的时候乱探）；
    /// ② 拼格式缓存键 `"<设备 uniqueID>|<模式>"` —— **会把缓存写到错的模式键下**
    ///    （后果：白探一次、下次仍走冷探测；不是崩溃，但等于预热白做）。
    ///
    /// ⚠️ 只修 `state` 不修 `mode` = 半修（两者是同一类 race）。
    /// 写入点与 `mode` 同处：`switchMode` 里 `publish{}` **外**、`sessionQueue` 上（唯一一处）。
    private var modeLocked: CaptureSessionMode = .photo

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
            // 过渡态抑制（批六 ② 收尾）：整个切模式 = 一次配置变更窗口 → 资源账只记账不判定
            //（`defer` 保证任何早退都会解除，不会把标记漏在那儿）
            self.isReconfiguring = true
            defer { self.isReconfiguring = false }
            // ④ 耗时埋点：切模式 = 一次 begin/commit（+ 可能的格式重选），
            //    掉帧排查要的是"切一次花多久、切多了会不会越来越慢"
            let switchStarted = Date()
            // 切模式重配 outputs 时系统可能**重选 activeFormat**，手动档（.custom / .locked）
            // 会被一并清掉 —— 但**切模式不是退出手动的意图**，用户设置的参数必须保留。
            // 做法（2026-09-20 批四改口径）：**先快照意图、commit 后一律重放**（见下方 ① ②）。
            // ⚠️ [mac-fix] 快照前先解包设备：`device` 是 `AVCaptureDevice?`，
            //    直接传进 `manualExposure(of:)` 编译不过（2026-09-20 批三编译实测）。
            //    无设备时重配 outputs 也无从谈起 —— 直接返回（与下方 `if let device` 同源）。
            guard let device = self.device else { return }
            let prevExposure = self.configurator.manualExposure(of: device)
            let prevWhiteBalance = self.configurator.manualWhiteBalance(of: device)
            let prevBias = device.exposureTargetBias

            self.session.beginConfiguration()
            self.configureAudioInputLocked(for: newMode)
            self.reconfigureOutputsLocked(for: newMode)
            self.session.commitConfiguration()

            // 🔍 诊断（批五）：commit 之后**立刻**读一次设备档位 —— 这一行把"参数回自动"的三种成因
            //     分开，复验时一眼定性（用户问题 3 的三个怀疑点）：
            //       · 这里=自动 → 系统在 commit 期间就清了（说明快照本身没读到手动档）
            //       · 这里=手动 → 是**之后**的异步落地清了它（快照 OK、重放也写了，被更晚的落地覆盖）
            DebugLog.shared.info(
                "session",
                "切模式 commit 后瞬间档位：曝光="
                    + "\(self.configurator.manualExposure(of: device) == nil ? "自动" : "手动")"
                    + " / 白平衡="
                    + "\(self.configurator.manualWhiteBalance(of: device) == nil ? "自动" : "手动")"
                    + " / 快照=曝光\(prevExposure == nil ? "自动" : "手动")·白平衡\(prevWhiteBalance == nil ? "自动" : "手动")"
            )
            self.preparePhotoTemplateIfNeeded(for: newMode)
            // P0-2：同步镜像与 `mode` 同处赋值 —— 必须在 `publish{}` **外**（本行在 sessionQueue 上，
            // 预热读的就是它）；写在 `publish{}` 里等于没镜像（那是在主线程上异步写的）。
            self.modeLocked = newMode
            self.publish { self.mode = newMode }
            // ⚠️ 切模式**一律按快照重放**（2026-09-20 批四 · 🔴 问题 2）。
            //
            // 旧实现是"比对 commit 前后，只有被系统清掉才重放" —— 判据依赖"系统到底改没改"，
            // 而用户实测"切模式参数还是回到自动"（批三复验 🔴6 那 3 次切模式时手动档未激活，
            // 所以那条口径**没被验到**）。意图快照 = 用户的设置，**重放是幂等的**（写同样的值），
            // 所以不需要猜系统做了什么：切模式不是退出手动的意图 → 一律重新施加一遍。
            if let device = self.device {
                // ⓪ 归一：**只清"快照里是自动档"的那一路** —— 快照要手动档的那一路下面直接重放，
                //    不必先归一再写回（少一次硬件写，也避免日志里出现"每次都报残留"的噪音）。
                //    ⚠️ 归一必须排在 EV 重放**之前**（自检⑲ n2 守这条顺序）。
                if prevExposure == nil, self.configurator.manualExposure(of: device) != nil {
                    try? self.configurator.setAutoExposure(on: device)
                    DebugLog.shared.info("session", "切模式：曝光档有残留 → 已归一到自动（为 EV 重放让路）")
                }
                if prevWhiteBalance == nil, self.configurator.manualWhiteBalance(of: device) != nil {
                    try? self.configurator.setAutoWhiteBalance(on: device)
                    DebugLog.shared.info("session", "切模式：白平衡档有残留 → 已归一到自动")
                }
                // ① 曝光：快照有手动档 → 一律重放（幂等）
                if let prev = prevExposure {
                    try? self.configurator.setManualExposure(
                        iso: prev.iso, seconds: prev.seconds, on: device
                    )
                    DebugLog.shared.info(
                        "session",
                        "切模式：手动曝光已按快照重放（ISO \(String(format: "%.0f", prev.iso))）"
                    )
                }
                // ② 白平衡：同上
                if let prev = prevWhiteBalance {
                    try? self.configurator.setManualWhiteBalance(
                        temperature: prev.temperature,
                        tint: prev.tint,
                        on: device
                    )
                    DebugLog.shared.info(
                        "session",
                        "切模式：手动白平衡已按快照重放（\(String(format: "%.0f", prev.temperature))K）"
                    )
                }
                // ③ EV 重放与手动曝光互斥（同 🔴1：applyExposureBias 见 .custom 会回切自动）——
                // 只在"切模式前就是自动曝光档"时才重放；手动档下 EV 值本就无效、保留状态即可。
                if prevExposure == nil, abs(device.exposureTargetBias - prevBias) > 0.001 {
                    try? self.configurator.applyExposureBias(prevBias, to: device)
                    DebugLog.shared.info("session", "切模式：EV 已重放（\(String(format: "%+.1f", prevBias))）")
                }
                self.publishManualState(device)
                // ④ **复查一行**（Mac 核法，🔴6 的判据）：切模式后设备的实际档位 + 意图态。
                DebugLog.shared.info(
                    "session",
                    "切模式后档位复查（\(newMode.displayName)）：曝光="
                        + "\(self.configurator.manualExposure(of: device) == nil ? "自动" : "手动")"
                        + " / 白平衡=\(self.configurator.manualWhiteBalance(of: device) == nil ? "自动" : "手动")"
                        + " / 对焦意图=\(self.manualFocus == nil ? "自动" : "手动")"
                        + " / EV=\(String(format: "%+.1f", device.exposureTargetBias))"
                )
                // ⚠️ **延迟复查与补写**（批五 · 🔴问题 3 根因）：系统重选 `activeFormat` 的落地
                //    比这里的重放**更晚**，会把它清掉 —— 隔几拍再看一眼，被清了就按快照补写。
                self.reverifyManualIntent(
                    4,
                    exposure: prevExposure,
                    whiteBalance: prevWhiteBalance,
                    bias: prevBias,
                    reason: "切模式复查"
                )
            }
            // ④ 耗时 + 资源账（切模式 = 重配 outputs + 可能的 input 增删，是泄漏的头号嫌疑路径）
            DebugLog.shared.info(
                "session",
                "切模式耗时 \(String(format: "%.2f", Date().timeIntervalSince(switchStarted)))s"
                    + "（\(newMode.displayName)；含 outputs 重配与参数重放）"
            )
            // ⚠️ 切模式**不跑逐候选格式探测**（实测：它只重配 outputs，不走 `applyPreferredFormatLocked`）
            //    → 探测闸门在这条路上没有作用点。这里只做**只读留痕**：若这期间收到过非良性打断，
            //    系统可能把参数重置 —— 打一行，供 A 条（"手动档又回自动"）定位用。**不改状态、不收闩**。
            if self.probeInterrupted {
                DebugLog.shared.warn(
                    "session",
                    "⚠️ 切模式期间检测到会话被打断（系统可能重置了参数，见紧随的档位复查）"
                )
            }
            self.refreshResourceSummary()
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
        // ⚠️ **物理会话不走虚拟阶梯**（2026-09-20 Mac 复验 🟡 问题 5）：虚拟阶梯
        // （`zoomFactor(forFocal:of:)`）吃 `virtualDeviceSwitchOverVideoZoomFactors`，
        // 物理单摄上为空 → 解析失败 → "焦段 xx mm 在本机没有对应镜头，未推硬件"
        // （会话重启后档位对齐静默失败实锤）。物理会话下设备已由 `performFocalSwitch`
        // 挂好，zoom 直接取 `zoomFactorOnPhysicalDevice`（挂载时已对齐，此处理论上是 no-op，
        // 放这里是为了**会话重启后的对齐路径**同样正确）。
        let zoom: CGFloat?
        if case .physical = form {
            zoom = preset.zoomFactorOnPhysicalDevice
        } else {
            zoom = CaptureCapabilities.zoomFactor(forFocal: preset, of: device)
        }
        guard let zoom else {
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

    // MARK: - 会话形态状态机（物理架构 · `docs/20`）

    /// 目标形态是否**真的需要**换设备（幂等判据，`beginFocalSwitch` / `applyFocalTargetSilently`
    /// / `performFocalSwitch` 三处共用）。
    ///
    /// ⚠️ 虚拟分支**不比档位** —— 虚拟会话内切档走 B1 的 ramp 分派，不经过换设备路径；
    /// 比档位会造成"点 24→35 也换一次设备"。
    private func needsSwitch(to target: FocalTarget) -> Bool {
        switch (form, target) {
        case (.virtual, .virtual):
            return false
        case (.physical(let a), .physical(let b)):
            return a.id != b.id
        default:
            return true
        }
    }

    /// 用户请求切换会话形态（虚拟 ↔ 物理单摄）—— **顺序触发第一段**（预检 ⑧）。
    ///
    /// 前置校验通过后只做：停 ramp + `isLensSwitching = true`（UI 开始淡入模糊）。
    /// **真正的换设备在 `commitFocalSwitch()`** —— 由 UI"淡入完成回调"调用（模糊先完全
    /// 盖住画面，切换快慢都不影响观感，`docs/20` 3.1）。
    ///
    /// - 幂等：目标形态 == 当前形态 → no-op（⚠️ 虚拟分支**不比档位** —— 虚拟会话内
    ///   切档走 B1 的 ramp 分派，不经过本方法）。
    /// - 会话未就绪 → `pendingFocalTarget` 排队（预检 ②，`startInternal` 补执行）。
    /// - 录制中跨设备 → 拒绝（兜底 —— VM 分派层已拦，预检 ③）。
    ///
    /// ⚠️ **只负责"置位 + 排队"，不换设备** —— 真正换设备在 `performFocalSwitch`
    /// （由 `commitFocalSwitch` 或 `applyFocalTargetSilently` 叫起）。
    func beginFocalSwitch(_ target: FocalTarget) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // 幂等：目标形态 == 当前形态 → no-op（判据见 `needsSwitch`）
            if !self.needsSwitch(to: target) { return }

            // 未就绪 → 排队（startInternal 就绪分支补执行，预检 ②）
            guard self.state == .running, self.device != nil else {
                self.pendingFocalTarget = target
                DebugLog.shared.info("session", "会话未就绪 → 焦段目标已排队（\(target.describe)）")
                return
            }
            guard let device = self.device else { return }

            // 录制中跨设备拒绝（兜底 —— VM 分派层已拦，预检 ③）
            if self.isRecording, case .physical(let newPreset) = target,
               case .physical(let curPreset) = self.form,
               newPreset.physicalDeviceTypes != curPreset.physicalDeviceTypes {
                self.publish {
                    self.lastErrorMessage = "录制中不能切换镜头（会中断录制）"
                }
                return
            }

            // ramp 进行中 → 停掉（预检 ②）
            self.configurator.stopZoomRamp(on: device)

            // 转场开（顺序触发第一段完成 —— 真正的换设备等 UI 淡入完成回调）
            self.pendingSwitchTarget = target
            self.publish { self.isLensSwitching = true }
            DebugLog.shared.info("session", "换设备开始（模糊淡入中）→ \(target.describe)")
        }
    }

    /// **顺序触发第二段**：执行换设备六步 + 参数搬运（由 UI"淡入完成回调"调用，预检 ⑧）。
    ///
    /// ⚠️ **`form` / `isLensSwitching` 的写入点只有 `performFocalSwitch`**，
    /// 而它是被这三个方法叫起来的：`beginFocalSwitch`（转场第一段：**唯一置位**
    /// `isLensSwitching = true` 的地方）、`commitFocalSwitch`（转场第二段）、
    /// `applyFocalTargetSilently`（后台无转场；自检⑲）。
    func commitFocalSwitch() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let target = self.pendingSwitchTarget else { return }
            self.pendingSwitchTarget = nil

            guard self.state == .running, self.device != nil else {
                self.pendingFocalTarget = target
                self.publish { self.isLensSwitching = false }
                return
            }

            self.performFocalSwitch(target, throughTransition: true)
        }
    }

    /// 换设备的**唯一执行体**（真实转场 / 后台静默换形态共用；`throughTransition` 只决定
    /// 是否去改写 `isLensSwitching` 那两位）。
    ///
    /// - Parameter throughTransition: `true` = 由 UI 淡入完成回调驱动的真实转场
    ///   （结束时要复位 `isLensSwitching`）；`false` = 后台静默（**绝不碰它**）。
    private func performFocalSwitch(_ target: FocalTarget, throughTransition: Bool) {
        // 过渡态抑制（批六 ② 收尾）：换设备 = 一次配置变更窗口（input 轮换 + 格式重探）→
        // 资源账期间只记账不判定（`defer` 保证早退也解除）
        isReconfiguring = true
        defer { isReconfiguring = false }

        // 幂等（静默换形态可能与真转场竞争）
        guard needsSwitch(to: target) else {
            if throughTransition { publish { self.isLensSwitching = false } }
            return
        }
        guard let device = self.device else {
            if throughTransition { publish { self.isLensSwitching = false } }
            return
        }

        // 旧设备手动参数真值快照（搬运源 —— .custom/.locked 只能用户设，回读可信）
        let previousExposure = configurator.manualExposure(of: device)
        let previousWhiteBalance = configurator.manualWhiteBalance(of: device)
        let previousBias = exposureBias
        // ④ 耗时埋点：本函数是**换设备的唯一执行体**，转场 / 静默两条路都从这里过 ——
        //    在这里量一次，两边的耗时都可比（静默路径另有一行"静默换形态耗时"，口径一致）
        let switchStarted = Date()

        // ②③④⑤ 换 input（失败回滚原 input —— 绝不留无视频输入的会话）
        let newDevice: AVCaptureDevice
        switch target {
        case .virtual: newDevice = CaptureCapabilities.backCamera() ?? device
        case .physical(let preset):
            guard let physical = CaptureCapabilities.physicalDevice(for: preset) else {
                publish {
                    if throughTransition { self.isLensSwitching = false }
                    self.lastErrorMessage = "本机没有 \(preset.displayName) mm 对应的镜头"
                }
                return
            }
            newDevice = physical
        }

        session.beginConfiguration()
        if let old = videoInput {
            session.removeInput(old)
            resourceInputRemoved()      // ④ 埋点：紧邻裸调用，见本文件「资源计数」节
        }
        do {
            let input = try AVCaptureDeviceInput(device: newDevice)
            guard session.canAddInput(input) else {
                throw SessionConfigurationError.cannotAddInput
            }
            session.addInput(input)
            resourceInputAdded()        // ④ 埋点
            videoInput = input
            self.device = newDevice
        } catch {
            if let old = videoInput ?? nil, session.canAddInput(old) {
                session.addInput(old)
                resourceInputAdded()    // ④ 埋点（回滚，同样是一次增）
                self.device = old.device
            }
            session.commitConfiguration()
            publish {
                if throughTransition { self.isLensSwitching = false }
                self.lastErrorMessage = "切换镜头失败，已恢复原镜头（\(error.localizedDescription)）"
            }
            return
        }
        session.commitConfiguration()

        // ⑥ 格式（铁律 1：commit 之后）
        applyPreferredFormatLocked(to: newDevice)

        // ⑦ 参数搬运（先归一新设备清残留，再按快照重放 —— 批四 🔴 实锤 A）
        reapplyManualStateLocked(
            on: newDevice,
            previousExposure: previousExposure,
            previousWhiteBalance: previousWhiteBalance,
            previousBias: previousBias
        )

        // zoom 对齐：物理挂载后 = 档位原生/裁切系数；回虚拟后 = 当前档位走虚拟阶梯
        let targetFocal: FocalPreset
        switch target {
        case .physical(let preset):
            targetFocal = preset
            configurator.setVideoZoomFactorDirect(preset.zoomFactorOnPhysicalDevice, on: newDevice)
        case .virtual(let focal):
            targetFocal = focal
            applyFocal(focal, animated: false) { _, _ in }
        }

        // 音频 input 不受视频 input 增删影响（只移除了视频），无需重配。
        publishManualState(newDevice)
        let formNow: SessionForm = { switch target {
        case .virtual: return .virtual
        case .physical(let p): return .physical(p)
        } }()
        publish {
            self.form = formNow
            if throughTransition { self.isLensSwitching = false }
            // ⚠️ 物理会话下**全部档位可点**：同镜头档走 ramp、跨镜头档走换设备
            // （物理设备缺失的机型由 `performFocalSwitch` 兜底报错）—— 置灰只属于
            // 虚拟会话（该机型镜头覆盖不到的档位）。
            self.unavailableFocalIds = formNow.isPhysical
                ? []
                : CaptureCapabilities.unavailableFocalIds(for: newDevice)
        }

        // 换设备日志（Mac 核法：deviceType 应变为物理单摄 / Live Photo 能力实测值，预检 ③）
        // ④ 耗时一并留在这一行（用户在"点对焦 / 切焦段"时等的那一下就是这个数）
        DebugLog.shared.info(
            "session",
            "换设备完成（\(throughTransition ? "转场" : "静默·无转场")）→ \(target.describe)；"
                + "当前档位 \(targetFocal.displayName) mm；"
                + "Live Photo 能力=\(photoService.output.isLivePhotoCaptureSupported)；"
                + "耗时 \(String(format: "%.2f", Date().timeIntervalSince(switchStarted)))s"
        )

        // 延迟复查（批五 · 问题 3 同因）：新设备的格式落地同样可能晚于搬运 ——
        // 被清掉就按旧设备快照补写一次（回焦点/回虚拟时同理）。
        reverifyManualIntent(
            4,
            exposure: previousExposure,
            whiteBalance: previousWhiteBalance,
            bias: previousBias,
            reason: throughTransition ? "换设备复查（转场）" : "换设备复查（静默）"
        )
    }

    /// 把设备的**两个手动态**（曝光 / 白平衡）归一到自动档 —— 清"上一轮残留"。
    ///
    /// ## 为什么需要它（2026-09-20 批四 · 🔴 实锤 A）
    ///
    /// `exposureMode` / `whiteBalanceMode` 是**设备实例级**状态，而"退出手动档"只改
    /// **当前挂的那台设备** —— 别的镜头（上一轮挂过的那颗）会把 `.custom` / `.locked`
    /// **留在原地**；device 对象 remove/re-add 也**不重置**。于是"新设备"常常自带
    /// 上一轮的手动档残留，两个后果：
    ///   1. UI 显示"自动"、设备其实是手动（回读口径被绕过）；
    ///   2. 接着推 EV 时 `applyExposureBias` 见 `.custom` 会**回切自动并打 WRN**
    ///      —— 用户批三实测的两次 WRN 正是这条（日志只有"只搬白平衡 + 推 EV"、
    ///      **没有**"手动曝光已重放"）。
    ///
    /// 归一到自动之后，"按快照重放"的目标态就是**唯一确定**的：不再依赖新设备的陈旧档位。
    ///
    /// ⚠️ **调用顺序是硬约束**：必须在 `applyExposureBias(` **之前**（自检⑲ n2 守着）——
    /// 反过来的话 EV 推送还是会撞上残留的 `.custom`，实锤 A 原样复发。
    ///
    /// - Returns: 各档位**原本是否有残留**（供调用方决定要不要打日志 / 复查）
    @discardableResult
    private func normalizeToAutoLocked(on device: AVCaptureDevice) -> (exposure: Bool, whiteBalance: Bool) {
        let hadExposure = configurator.manualExposure(of: device) != nil
        let hadWhiteBalance = configurator.manualWhiteBalance(of: device) != nil
        if hadExposure {
            try? configurator.setAutoExposure(on: device)
        }
        if hadWhiteBalance {
            try? configurator.setAutoWhiteBalance(on: device)
        }
        return (hadExposure, hadWhiteBalance)
    }

    /// **静默换形态**（不显示转场）：后台把目标设备/形态挂好。
    ///
    /// ## 为什么要有它（2026-09-20 批四 · 用户要求 ③「转场边界」）
    ///
    /// 用户明确的转场边界：**只有切焦段**该有转场（≤1s）；切自动/手动、点对焦按钮、
    /// 切模式 → **人眼无感**。但按需物理架构下，"切手动档 / 开对焦盘"都必须先换到物理单摄
    /// —— 换设备硬耗时 0.6~0.75s（AVFoundation 换 input + 格式），走转场就是 ≈0.85~1.0s 的模糊。
    ///
    /// 解法：把换设备从"用户按下按钮那一刻"**挪到更早或更晚的非焦点时刻**：
    ///   ① **预切换**（提前挂）：打开刻度条 / 按「对焦」入口时先挂好 ——
    ///      等用户真去点手动开关时，`form` 已经是物理 → **零转场**；
    ///   ② **静默回切**：全手动档退出 2s 后切回虚拟（`CameraViewModel.evaluateRevertToVirtual`）
    ///      —— 那是 App 自己的收尾动作，不是用户的焦段操作，同样不该闪一次转场。
    ///
    /// ## 与 `beginFocalSwitch` 的差别（只有一处，但很关键）
    ///
    /// **不碰 `isLensSwitching`** —— 那个位是"UI 该显示模糊浮层"的信号，
    /// 置位会被 `CameraView` 的 `onChange` 抓成一次淡入淡出（即便立刻复位也会闪一下）。
    /// 静默换形态是**纯后台**的设备挂载：不置位 ⇒ 无浮层。
    ///
    /// ⚠️ **代价要说清**：换 input 本身有开销（0.6~0.75s），这段时间预览可能有一瞬停顿 ——
    /// 模糊转场的价值正是盖住它。所以静默路径只用在"用户正在做别的事"的时刻
    /// （开面板 / 收面板后 2s），不在用户盯着画面等切换的时刻用。
    ///
    /// - 尽力而为：录制中 / 会话未就绪 / 真转场进行中 → 直接放弃（不排队、不报错）。
    ///   放弃没有严重后果：用户真去点手动时，`queueActionRequiringPhysical` 会走转场兜底。
    ///
    /// - Parameter completion: **结果回执**（批五 问题 1③，语义见 `SilentSwitchOutcome`）。
    ///   在 `sessionQueue` 上回调；调用方要用主线程状态的话自己 hop 回主线程。
    ///   ⚠️ 有了它，调用方**不再需要"盲等超时"** —— 慢就继续等，没做才退转场。
    func applyFocalTargetSilently(
        _ target: FocalTarget,
        completion: ((SilentSwitchOutcome) -> Void)? = nil
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { completion?(.skipped); return }
            guard !self.isRecording, self.state == .running, self.device != nil else {
                DebugLog.shared.info("session", "静默换形态跳过：录制中 / 会话未就绪")
                completion?(.skipped)
                return
            }
            // 真转场进行中 → 让路（`pendingSwitchTarget` 已存，等 UI 完成回调，别插队）
            guard !self.isLensSwitching, self.pendingSwitchTarget == nil else {
                DebugLog.shared.info("session", "静默换形态跳过：真转场进行中（让路）")
                completion?(.skipped)
                return
            }
            guard self.needsSwitch(to: target) else {
                DebugLog.shared.debug("session", "静默换形态：目标形态已满足，无需换设备")
                completion?(.alreadySatisfied)
                return
            }
            DebugLog.shared.info("session", "静默换形态（后台挂设备 · 无转场）→ \(target.describe)")
            let started = Date()
            self.performFocalSwitch(target, throughTransition: false)
            let cost = Date().timeIntervalSince(started)
            // 耗时留痕（批五 问题 1）：命中格式缓存应 ≈0.3~0.8s；首次冷探测 4~5s。
            // ⚠️ 它同时也是"用户为什么等了一下"的依据 —— 不要因为"日志有点长"删掉。
            DebugLog.shared.info(
                "session",
                "静默换形态耗时 \(String(format: "%.2f", cost))s"
                    + "（命中格式缓存 ≈0.3~0.8s；每设备首次冷探测 4~5s）"
            )
            completion?(.switched)
        }
    }

    /// 参数重放后的**延迟复查与修复**（2026-09-20 批五 · 🔴问题 3 根因）。
    ///
    /// ## 为什么"commit 之后立刻重放"不够
    ///
    /// `commitConfiguration()` **返回 ≠ 系统已完成工作**：切模式 / 换设备会让会话重新协商
    /// `activeFormat`，而那次落地**发生在我们重放之后**，把刚写进去的 `.custom` / `.locked`
    /// 清成自动 —— 表现就是"手动模式切完模式回到自动"（批四 Mac 复验：切焦段保住、切模式没测，
    /// 用户复验点名"手动模式下切模式仍恢复自动档"）。
    /// 光靠一次重放必输：我们和系统在抢同一份状态，而它比我们晚。
    ///
    /// ## 做法（复查 → 必要时补写，幂等）
    ///
    /// 按**递增间隔复查几次**（150 / 300 / 500 / 800ms，共 4 拍）：意图还在 → 什么都不做；
    /// 被系统清掉 → 按快照**再写一次**并打 WARN 留痕（复验一眼能看出"重放被谁清了"）。
    /// 复查本身只是读设备状态，代价极小；总共 ~1.75s 覆盖"系统落地拖到一秒外"的长尾。
    ///
    /// ⚠️ **必须尊重用户中途改主意**：每次复查前先看**已发布的意图态**
    /// （`manualExposure` / `manualWhiteBalance` / `exposureBias`）是否还等于快照 ——
    /// 用户在复查窗口内点了"切回自动"，这里就**不能**把它按回去（否则变成"我点了自动它自己又跳回手动"）。
    ///
    /// - Parameters:
    ///   - remaining: 剩余复查次数（调用方传 4 → 依次 150 / 300 / 500 / 800ms 四拍）
    ///   - reason: 日志前缀（"切模式复查" / "换设备复查"）
    private func reverifyManualIntent(
        _ remaining: Int,
        exposure: (iso: Float, seconds: Double)?,
        whiteBalance: (temperature: Float, tint: Float)?,
        bias: Float,
        reason: String
    ) {
        guard remaining > 0 else { return }
        let delayMs: Int
        switch remaining {
        case 4: delayMs = 150
        case 3: delayMs = 300
        case 2: delayMs = 500
        default: delayMs = 800
        }
        let thisAttempt = 5 - remaining
        sessionQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            guard let self, let device = self.device else { return }

            var repaired: [String] = []
            // ① 曝光（快照是手动档 + 用户意图仍是手动档 + 设备被清成自动 → 补写）
            if let prev = exposure {
                let intentStillManual = self.manualExposure.map { abs($0.iso - prev.iso) < 0.5 } ?? false
                if intentStillManual, self.configurator.manualExposure(of: device) == nil {
                    try? self.configurator.setManualExposure(
                        iso: prev.iso, seconds: prev.seconds, on: device
                    )
                    repaired.append("曝光")
                }
            }
            // ② 白平衡（同上）
            if let prev = whiteBalance {
                let intentStillManual = self.manualWhiteBalance
                    .map { abs($0.temperature - prev.temperature) < 25 } ?? false
                if intentStillManual, self.configurator.manualWhiteBalance(of: device) == nil {
                    try? self.configurator.setManualWhiteBalance(
                        temperature: prev.temperature, tint: prev.tint, on: device
                    )
                    repaired.append("白平衡")
                }
            }
            // ③ EV（仅自动曝光档；意图值仍是快照那个）
            if exposure == nil, abs(self.exposureBias - bias) < 0.001,
               abs(device.exposureTargetBias - bias) > 0.001 {
                try? self.configurator.applyExposureBias(bias, to: device)
                repaired.append("EV")
            }

            if !repaired.isEmpty {
                DebugLog.shared.warn(
                    "session",
                    "\(reason)：系统在重放之后清掉了\(repaired.joined(separator: "/"))"
                        + "（第 \(thisAttempt) 拍复查）→ 已按快照补写"
                )
                self.publishManualState(device)
            }
            self.reverifyManualIntent(
                remaining - 1,
                exposure: exposure,
                whiteBalance: whiteBalance,
                bias: bias,
                reason: reason
            )
        }
    }

    /// 换设备后的参数搬运（预检 ④⑤⑥；**必须在 `applyFormat` 之后调用** —— clamp 依赖
    /// 新设备 activeFormat）。
    ///
    /// 顺序**定死**（每一步都有理由）：
    ///   0. **归一新设备**（`normalizeToAutoLocked`）—— 清上一轮残留（实锤 A）
    ///   1. 曝光 / 白平衡：换设备前从**旧设备回读**的真值重放（`.custom` / `.locked` 只能用户
    ///      显式设置 —— 回读可信；clamp 到新设备域，逐项 try 不连坐）
    ///   2. EV：**仅自动曝光档**重放，且推之前再判一次新设备不在 `.custom`
    ///   3. **对焦：显式降级**（预检 ⑤）—— `lensPosition` 量程随镜头不同，搬运必然对不上焦；
    ///      落回连续自动 + 清意图态（`manualFocus = nil`）+ toast 由 VM 观察 `form` 变化发出
    ///   4. **复查一行**（Mac 核法）
    private func reapplyManualStateLocked(
        on newDevice: AVCaptureDevice,
        previousExposure: (iso: Float, seconds: Double)?,
        previousWhiteBalance: (temperature: Float, tint: Float)?,
        previousBias: Float
    ) {
        // ⓪ 归一：清掉新设备可能的上一轮残留
        let leftover = normalizeToAutoLocked(on: newDevice)
        if leftover.exposure || leftover.whiteBalance {
            DebugLog.shared.warn(
                "session",
                "新设备带上一轮手动档残留（曝光=\(leftover.exposure ? "手动" : "自动") / "
                    + "白平衡=\(leftover.whiteBalance ? "手动" : "自动")）→ 已归一到自动档，再按快照重放"
            )
        }

        // ① 曝光（ISO + 快门成对）
        if let prev = previousExposure {
            do {
                try configurator.setManualExposure(iso: prev.iso, seconds: prev.seconds, on: newDevice)
                DebugLog.shared.info("session", "搬运：手动曝光已重放（ISO \(String(format: "%.0f", prev.iso))）")
            } catch {
                DebugLog.shared.warn("session", "手动曝光搬运失败 → 回自动：\(error.localizedDescription)")
                try? configurator.setAutoExposure(on: newDevice)
            }
        }
        // ② 白平衡
        if let prev = previousWhiteBalance {
            do {
                try configurator.setManualWhiteBalance(temperature: prev.temperature, tint: prev.tint, on: newDevice)
                DebugLog.shared.info("session", "搬运：手动白平衡已重放（\(String(format: "%.0f", prev.temperature))K）")
            } catch {
                DebugLog.shared.warn("session", "手动白平衡搬运失败 → 回自动：\(error.localizedDescription)")
                try? configurator.setAutoWhiteBalance(on: newDevice)
            }
        }
        // ③ EV（预检 🔴1）：**手动曝光档下不推** —— `applyExposureBias` 见 `.custom` 会把设备
        // 回切自动（docs/16 第五节的防线），先搬 ISO 再搬 EV 会把刚搬好的手动档**自己杀掉**
        // （Mac 复验 4 次 WRN 实锤，违反 docs/18 §2.4"手动档下不推 EV"）。
        // EV 值本来就在 session 状态里（`exposureBias`），回自动档时自动生效 —— 这里跳过即可。
        if previousExposure == nil {
            // ⚠️ 推 EV 前**再确认**新设备此刻不在手动曝光档（⓪ 已归一 ⇒ 正常路径必为自动）。
            // 这道断言是**防线**：将来谁把 ⓪ 那段归一删了，这里会在日志里立刻暴露，
            // 而不是又退化成一次"静默把手动档杀掉 + 一条 WRN"。
            if configurator.manualExposure(of: newDevice) != nil {
                DebugLog.shared.warn("session", "EV 重放前新设备仍是手动曝光档 → 先归一（防回切 WRN）")
                try? configurator.setAutoExposure(on: newDevice)
            }
            do {
                try configurator.applyExposureBias(previousBias, to: newDevice)
                DebugLog.shared.info("session", "搬运：EV 已重放（\(String(format: "%+.1f", previousBias))）")
            } catch {
                DebugLog.shared.warn("session", "EV 搬运失败（保留状态值）：\(error.localizedDescription)")
            }
        } else {
            DebugLog.shared.info(
                "session",
                "搬运：手动曝光档激活 → 跳过 EV 重放（值保留 \(String(format: "%+.1f", previousBias))，回自动档生效）"
            )
        }
        // ④ 对焦：显式降级（预检 ⑤）—— 意图清除 + 连续自动
        publish { self.manualFocus = nil }
        do {
            try configurator.setAutoFocus(on: newDevice)
            DebugLog.shared.info("session", "搬运：对焦显式降级 → 连续自动（预检 ⑤）")
        } catch {
            DebugLog.shared.warn("session", "对焦降级失败：\(error.localizedDescription)")
        }
        // ⑤ **复查一行**（Mac 核法）：换设备/预切换后**新设备的实际档位**。
        // 有了它，"实锤 A 有没有根治"不用再靠推断 —— 直接看这一行是不是"曝光=自动"。
        DebugLog.shared.info(
            "session",
            "换设备后新设备档位复查：曝光=\(configurator.manualExposure(of: newDevice) == nil ? "自动" : "手动")"
                + " / 白平衡=\(configurator.manualWhiteBalance(of: newDevice) == nil ? "自动" : "手动")"
                + " / 对焦=自动（显式降级）"
                + " / EV=\(String(format: "%+.1f", newDevice.exposureTargetBias))"
        )
    }

    // MARK: - 手动对焦（B3b · 对焦圆盘接线）

    /// 手动对焦（对焦圆盘拖动写硬件；虚拟多摄不支持 —— UI 已按能力分派，这里是最后防线）。
    /// 物理会话下的**同镜头平滑变焦**（预检 ⑦：35↔48 同挂一颗 Wide，ramp 到
    /// `zoomFactorOnPhysicalDevice` —— 比例真读 `mainCropFactor`，禁字面量）。
    /// 跨镜头（↔13 / ↔120）不归本方法 —— 走 `beginFocalSwitch` 换设备 + 转场。
    /// 录制中调用是安全的（同一颗设备内 ramp，系统支持录制中变焦 —— 拍板 ②）。
    func applyZoomOnPhysical(to preset: FocalPreset) {
        guard let device else { return }
        guard case .physical = form else {
            DebugLog.shared.warn("session", "applyZoomOnPhysical 在非物理会话被调用 —— 分派矩阵漏改")
            return
        }
        // B1 的 ramp 量级（docs/15：0.35s）
        configurator.applyZoomRamp(targetZoomFactor: preset.zoomFactorOnPhysicalDevice,
                                   duration: 0.35, to: device)
    }

    /// 手动对焦（对焦圆盘拖动 / 「自动对焦」开关关闭时）。
    ///
    /// ⚠️ **这是 `manualFocus` 的意图写入点之一**：调用 = 用户表达"进入/保持手动对焦档"
    /// —— 这里发布 `manualFocus = lensPosition`（意图态），**不是**从硬件回读推断
    /// （`.autoFocus` 完成后系统也置 `.locked`，回读分不清两种锁，Mac 复验 ③ 根因）。
    func setManualFocus(lensPosition: Float) {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.setManualFocus(lensPosition: lensPosition, on: device)
                self.publishManualState(device)
                self.publish { self.manualFocus = lensPosition }
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "手动对焦失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    /// 切到**自动对焦**（对焦盘「自动对焦」开关打开时；**以及点按取景器解除手动档时**）
    ///
    /// ⚠️ **这是 `manualFocus` 的意图写入点之二**：调用 = 用户表达"退出手动对焦档"
    /// —— 这里发布 `manualFocus = nil`。此后点按对焦（`.autoFocus` → 系统转 `.locked`）
    /// 不会再被误判成"用户手动锁定"（正源修，`backlog ⑩`）。
    ///
    /// 两个调用点（都是**用户显式操作**，没有"推断"成分）：
    ///   1. 对焦盘「自动对焦」开关置开；
    ///   2. **点取景器时手动锁定 → 解除并重新对焦**（方案 A，2026-09-20 用户拍板；见 `docs/21` 第七节）。
    ///      带例外：对焦盘开着时的点按算误触，**不调本方法**（只测光）。
    func setAutoFocusMode() {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.setAutoFocus(on: device)
                self.publishManualState(device)
                self.publish { self.manualFocus = nil }
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "切自动对焦失败：\(error.localizedDescription)")
                self.publish { self.lastErrorMessage = error.localizedDescription }
            }
        }
    }

    /// **只测光、不动焦** —— 现在的唯一调用点：**对焦盘开着时点取景器**（误触缓解）。
    ///
    /// ⚠️ 语义变更（2026-09-20 方案 A）：它**不再**是"手动锁定期间点按取景器"的默认行为。
    /// 原拍板 ③ 那条（手动锁定 → 点按只测光、无提示）在真机上造成了"无出路"（批三 40 次点按
    /// 全部只测光、用户以为对焦坏了）—— 现改为**点按解除手动档并重新对焦**（方案 A），
    /// 只有"对焦盘正开着"这一种误触场景才走这里（见 `CameraViewModel.focusTapped`）。
    func setExposurePointOnly(_ point: CGPoint) {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurator.setExposurePointOnly(point, on: device)
                self.publishManualState(device)
                self.refreshSnapshot()
            } catch {
                DebugLog.shared.error("session", "点按测光失败：\(error.localizedDescription)")
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
        let currentLens = device.lensPosition
        var unavailable: [ParameterStripKind: Set<Double>] = [:]
        for kind in ParameterStripKind.allCases {
            unavailable[kind] = CaptureCapabilities.unavailableStripValues(for: kind, on: device)
        }
        // 手动参数能力（虚拟多摄不支持，见属性注释）：能力探测一次，随本方法一起发布。
        let manualExposureOK = CaptureCapabilities.supportsManualExposure(device)
        let manualWhiteBalanceOK = CaptureCapabilities.supportsManualWhiteBalance(device)
        let manualFocusOK = CaptureCapabilities.supportsManualFocus(device)
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
            // ISO 末档 = 设备当前格式实读的 maxISO（批六 ①：不写行业表的 12800）
            self.stripISOMax = Double(device.activeFormat.maxISO)
            self.isManualExposureSupported = manualExposureOK
            self.isManualWhiteBalanceSupported = manualWhiteBalanceOK
            // 对焦：**回读只喂 `currentLensPosition`**（读数，自动/手动都跟硬件）。
            // ⚠️ `manualFocus` **绝不能在这里赋值**（2026-09-20 正源修，`backlog ⑩`）：
            // `focusMode == .locked` 是"一次性 AF 完成后"的正常状态（SDK `:1053-1054`：
            // `.autoFocus` 对焦一次后自动转 `.locked`），**不等于**"用户锁了手动对焦"。
            // 从回读推断 → 点按一次后 `isFocusManual` 永久为真 → 点按全走"仅测光"
            // → **死锁：点按对焦永久失效**（真机实测，Mac 最小修 `670970b` 临时压住，
            // 本笔正源修根治）。`manualFocus` 的写入点只有两个**意图入口**：
            // `setManualFocus(lensPosition:)` / `setAutoFocusMode()`（见各自注释），
            // 自检⑱守着"publishManualState 不得写 manualFocus"。
            self.currentLensPosition = currentLens
            self.isManualFocusSupported = manualFocusOK
        }
    }

    /// 点按对焦 / 测光。参数是预览层换算出来的**设备归一化坐标**。
    ///
    /// ## 2026-09-21 批六 · ③「**不选自动就永远手动**」（用户拍板 · 核心口径）
    ///
    /// 系统语义：`setFocusAndExposurePoint` 会把 `exposureMode` 设成 `.continuousAutoExposure`
    /// —— 手动 ISO / 快门**会被它顶掉**。旧口径是"重发真值让 UI 立刻回到自动"，
    /// 那等于 **App 自己替用户退出手动档**（用户实测日志链：
    /// `11:45:10.006 手动 799 / 1/60 → 11:45:13.242 点按对焦 → 15.302 退出 → 16.329「曝光=自动」`）。
    ///
    /// 现口径：**点按只是"重新对焦"，不是退出曝光手动的意图** —— 点按前取**意图快照**、
    /// 点按后**按快照重放**（与切模式 `switchMode` 同一套写入）。白平衡 / EV 同理。
    ///
    /// ⚠️ 与 `CameraViewModel` 的**方案 A** 不冲突：方案 A 解的是「手动**对焦**档」这条轴
    /// （点按 = 重新对焦 + 解除手动对焦，防"无出路"），本方法保的是**曝光 / 白平衡**这两条轴。
    ///
    /// ⚠️ 顺序有讲究：先把系统设的连续自动曝光**按快照写回 `.custom`**，**最后**才推 EV
    /// —— `applyExposureBias` 见 `.custom` 会回切自动档（`docs/16` 第五节那条防线）。
    ///
    /// ⚠️ "只测光"那条路径（`setExposurePointOnly`）**不需要本套**：它自带
    /// `device.exposureMode != .custom` 守卫，本来就不会碰手动档。
    func focus(atDevicePoint point: CGPoint) {
        guard let device else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let prevExposure = self.configurator.manualExposure(of: device)
            let prevWhiteBalance = self.configurator.manualWhiteBalance(of: device)
            let prevBias = device.exposureTargetBias
            do {
                try self.configurator.setFocusAndExposurePoint(point, on: device)
                // ① 曝光：意图是手动 → 按快照重放（顶掉系统设的连续自动曝光）
                if let prev = prevExposure {
                    try? self.configurator.setManualExposure(
                        iso: prev.iso, seconds: prev.seconds, on: device
                    )
                    DebugLog.shared.info(
                        "session",
                        "点按对焦后按意图重放手动曝光（ISO \(String(format: "%.0f", prev.iso))"
                            + " / \(FormatText.shutterSpeed(prev.seconds))）"
                    )
                }
                // ② 白平衡：同上
                if let prev = prevWhiteBalance {
                    try? self.configurator.setManualWhiteBalance(
                        temperature: prev.temperature, tint: prev.tint, on: device
                    )
                    DebugLog.shared.info(
                        "session",
                        "点按对焦后按意图重放手动白平衡（\(String(format: "%.0f", prev.temperature))K）"
                    )
                }
                // ③ EV：只在"意图本来就是自动曝光档"时重放（手动档下 EV 无效，同 ① 的互斥口径）
                if prevExposure == nil, abs(device.exposureTargetBias - prevBias) > 0.001 {
                    try? self.configurator.applyExposureBias(prevBias, to: device)
                    DebugLog.shared.info(
                        "session",
                        "点按对焦后按意图重放 EV（\(String(format: "%+.1f", prevBias))）"
                    )
                }
                self.publishManualState(device)
                // 复查一行（Mac 核法）：点按后档位到底保住没有，一眼可读
                DebugLog.shared.info(
                    "session",
                    "点按对焦后档位：曝光="
                        + "\(self.configurator.manualExposure(of: device) == nil ? "自动" : "手动")"
                        + " / 白平衡="
                        + "\(self.configurator.manualWhiteBalance(of: device) == nil ? "自动" : "手动")"
                        + " / 意图=曝光\(prevExposure == nil ? "自动" : "手动")"
                        + "·白平衡\(prevWhiteBalance == nil ? "自动" : "手动")"
                )
                // 点按不重配会话，但系统可能在 AF 收敛前后**再改一次**曝光档 → 两拍复查（500/800ms）
                self.reverifyManualIntent(
                    2,
                    exposure: prevExposure,
                    whiteBalance: prevWhiteBalance,
                    bias: prevBias,
                    reason: "点按对焦复查"
                )
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
        // ④ 资源账（每 5s 一行）：掉帧排查要的就是"跑一段时间之后的 input/output 数 + 内存"，
        //    必须**周期性**留痕 —— 只在增删时打日志，恰恰看不到"没增没删但内存一路涨"。
        if snapshotTick % 5 == 1 {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.refreshResourceSummary()
                DebugLog.shared.info("resource", self.resourceSummaryText)
            }
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
                // 手动参数能力一行（Mac 复验核法：虚拟多摄上应三个 false；
                // 物理镜头架构 docs/18 落地后按探测自动变 true）
                DebugLog.shared.info(
                    "session",
                    "手动参数能力：曝光(custom)=\(CaptureCapabilities.supportsManualExposure(device))"
                        + " / 白平衡(锁定增益)=\(CaptureCapabilities.supportsManualWhiteBalance(device))"
                        + " / 对焦(锁定位置)=\(CaptureCapabilities.supportsManualFocus(device))"
                )
                DebugLog.shared.info("session", "会话配置完成，Live Photo 支持=\(livePhotoSupported)")
            }
        }

        guard configurationSucceeded else { return }

        // 排队补执行（预检 ②）：会话就绪前用户点过的焦段目标，这里补上。
        if let pending = pendingFocalTarget {
            pendingFocalTarget = nil
            DebugLog.shared.info("session", "会话就绪 → 补执行排队的焦段目标（\(pending.describe)）")
            // 会话刚配置完，画面还没有"过程"要给用户看 → 走**静默**换形态（无转场）
            applyFocalTargetSilently(pending)
        }

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
            // 打断观察必须在开始跑之前挂上（预热的安全闸门，批六 ②）
            observeInterruptionsIfNeeded()
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

        // ④ 资源计数：就绪后先攒一份汇总（首次冷探测的计数都从这里开始有基线）
        refreshResourceSummary()

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

    // MARK: - 资源计数与耗时（2026-09-21 批六 · ④「取景器掉帧」排查）

    // 用户场景：点开所有功能 → 切手动 → 依次切 照片 / 实况 / log / 视频，之后开始掉帧，
    // 且**重启 App 立刻恢复**。Mac CB 的判据：热降频 / 系统节流不会因重启 App 快速恢复，
    // 而 App 侧资源泄漏（模式切换 / 静默预切换没拆净的 input / output）会随次数累积 ——
    // 所以这一段只干一件事：**把"活的有几个、增删对不对得上"变成日志里一眼可读的数字**。
    //
    // ⚠️ 埋点纪律：每一处 `session.addInput / removeInput / addOutput / removeOutput` 的
    //    **紧邻 3 行内**必须有对应的计数调用 —— `check_swift` 第 19 组 o1 逐点比对，
    //    漏埋一处就 FAIL（计数本身错了比没有计数更坏：会让人往错的方向排查）。
    private var inputAddCount = 0
    private var inputRemoveCount = 0
    private var outputAddCount = 0
    private var outputRemoveCount = 0
    /// 上一次攒好的汇总（在 `sessionQueue` 上写、1s 定时器读字符串 —— 不会读到半个数字）
    private var resourceSummaryText = "资源：尚未采集"

    private func resourceInputAdded() { inputAddCount += 1; refreshResourceSummary() }
    private func resourceInputRemoved() { inputRemoveCount += 1; refreshResourceSummary() }
    private func resourceOutputAdded() { outputAddCount += 1; refreshResourceSummary() }
    private func resourceOutputRemoved() { outputRemoveCount += 1; refreshResourceSummary() }

    /// **会话配置变更窗口**（add/remove input·output 的 begin…commit 之间）。
    ///
    /// 为什么要有它：切模式 / 换设备时，`mode`（主线程发布）与真实的 input·output 数量会有
    /// **几百毫秒错位** —— 2026-09-21 真机 118 次连切实测出 **48 条「⚠️ 资源超出预期」全是这类过渡态误报**
    /// （47×「模式照片 in 活 2」= 切到实况时麦克风已加、`mode` 还没发布；1×「模式实况」= outputs 瞬态 2）。
    /// 误报会淹没真信号 → 配置窗口内**只记账、不判定**。
    private var isReconfiguring = false
    /// 连续超预期的次数（**连续 2 次才 WARN**）—— 配置窗口之外仍可能有单次瞬态。
    private var overExpectStreak = 0

    /// 该模式下**应当**挂着的 input / output 数量 —— 超出即泄漏（比"累计增删对不上"更早报出来）。
    ///
    /// ⚠️ **input 以"麦克风是否真在我们手上"为事实源**（`audioInput != nil`），不再按
    /// `mode.requiresMicrophone` 另算一套 —— 那个口径与 `configureAudioInputLocked` 的真值在切换瞬间
    /// 必然漂移（就是上面那 48 条误报的根因）；而且**照片模式也会带麦克风**（Live Photo 要录音），
    /// 所以"照片 = 1 个 input"本身就是错的。
    private var expectedResourceCounts: (inputs: Int, outputs: Int) {
        (audioInput != nil ? 2 : 1, 1)
    }

    /// 汇总 + **超出预期就喊**（掉帧排查的主信号）
    private func refreshResourceSummary() {
        let liveInputs = session.inputs.count
        let liveOutputs = session.outputs.count
        let expected = expectedResourceCounts
        let memory = Self.memoryFootprintMB().map { String(format: "%.1fMB", $0) } ?? "取不到"
        resourceSummaryText = "模式 \(mode.displayName) · input 活 \(liveInputs)"
            + "（累计增/删 \(inputAddCount)/\(inputRemoveCount)）"
            + " · output 活 \(liveOutputs)（累计增/删 \(outputAddCount)/\(outputRemoveCount)）"
            + " · 内存 \(memory)"
        // 配置变更窗口内：只记账（过渡态一律不判定）
        guard !isReconfiguring else { return }
        if liveInputs > expected.inputs || liveOutputs > expected.outputs {
            overExpectStreak += 1
            // 连续 2 次才喊：单次瞬态不报，**真泄漏是持续的、照样会被喊出来**
            if overExpectStreak >= 2 {
                DebugLog.shared.warn(
                    "resource",
                    "⚠️ 资源超出预期（多出来的那个就是泄漏的形状）：\(resourceSummaryText)"
                        + " · 预期 input ≤ \(expected.inputs) / output ≤ \(expected.outputs)"
                        + "（连续 \(overExpectStreak) 次）"
                )
            }
        } else {
            overExpectStreak = 0
        }
    }

    /// 进程**物理内存占用**（MB）—— `TASK_VM_INFO.phys_footprint`（"活动监视器"里那个数）。
    ///
    /// 为什么不用 `resident_size`：它含可回收页，App 内存涨了它常常不动 → 读不出泄漏。
    /// 取不到就返回 nil —— 诊断信息不该成为风险源（**绝不影响主链路**）。
    private static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    // MARK: - 格式探测闸门（批六 ② 收尾 · 2026-09-21）

    // 为什么把闸门**装进 `applyPreferredFormatLocked`**，而不是装在某一条入口上：
    //   它有**两条入口** —— 启动配置（`buildSession` 分支）与换设备（`performFocalSwitch`）。
    //   ⚠️ **切模式不走它**（只重配 outputs，实测 grep 过调用点）→ 那条路没有探测闸门的作用点，
    //   只有一处**只读留痕**（`切模式期间检测到会话被打断`）。别把这里写成"覆盖三条入口"。
    //   装在这个执行体里仍然值得：它同时是"会话配置"与"换设备"的共用路径，装一次覆盖两条。

    /// 打断观察者**只注册一次**的闩。
    ///
    /// ⚠️ 批六 ② 收尾修（2026-09-21 夜）：它原本和预热状态量放在一起，**随"删设备级预热"被一起删掉**，
    /// 但 `observeInterruptionsIfNeeded()`（探测闸门版）仍用它做只注册一次的守卫 → Mac 编译报
    /// `cannot find 'interruptionObserverRegistered' in scope`。当时的 `check_swift` **全过**，
    /// 因为"状态引用完整性"只覆盖 `viewModel.*` / `env.*` 这类跨文件引用，**不查同文件"声明被删、引用还在"**
    /// → 现在由 o8（成员引用完整性）专门守这一类，并配了"删任一 `private var` 声明"的变异。
    private var interruptionObserverRegistered = false

    /// 探测被**真实打断**的闩。
    ///
    /// 写入点 = 打断通知线程（直接置，**不排队**）；读取点 = 探测循环所在的 `sessionQueue`。
    /// 🔴 为什么不能排队：旧实现把"放弃"动作 `async` 到那条正被占用的队列上，等它醒来已经来不及
    /// （真机上那句「已拆除预热」从未出现过）—— 收手标记必须**同步**可见。
    private var probeInterrupted = false
    /// 探测代次 —— 只让"本次探测期间"的打断生效，避免上一轮的闩误伤下一次。
    private var probeGeneration = 0

    /// 打开一次探测闸门（返回本次代次）。探测循环持有它，用来判断"这个闩是不是给我的"。
    private func beginFormatProbe() -> Int {
        probeInterrupted = false
        probeGeneration += 1
        return probeGeneration
    }

    /// 本次探测是否已被真实打断
    private func isFormatProbeInterrupted(_ generation: Int) -> Bool {
        probeInterrupted && generation == probeGeneration
    }

    /// 直播会话的**打断观察**（只注册一次）。
    ///
    /// 两个职责：
    /// ① **留痕**：打断原因打成一行（按枚举名 + raw，便于 Mac 反查）；
    /// ② **给格式探测上闩**：非良性打断 → 置 `probeInterrupted`，探测循环在下一个候选前收手、
    ///    采用兜底格式（避免在会话已被扰动时继续 churn `applyFormat` —— 每次 ≈0.3s）。
    ///
    /// ⚠️ **白名单制**：只把"进后台"当良性。别的客户端抢占（`videoDeviceInUseByAnotherClient`）
    /// 这类**必须保留闸门作用** —— 写成"排除所有非致命 reason"就会连黑屏那条一起放过。
    private func observeInterruptionsIfNeeded() {
        guard !interruptionObserverRegistered else { return }
        interruptionObserverRegistered = true
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            let reason = Self.interruptionReason(raw)
            DebugLog.shared.warn("session", "⚠️ 直播会话被打断：\(reason.text)（raw \(raw)）")
            guard !reason.benign else {
                DebugLog.shared.info("session", "打断原因属良性（进后台）→ 不触发探测闸门")
                return
            }
            // 🔴 通知线程上**直接置闩**（不排队）—— 探测循环下一候选前就能看到
            self.probeInterrupted = true
        }
    }

    /// 打断原因 →（文案，**是否良性**）（批六 ② P0-4 / P0-5）。
    ///
    /// ## 判据按**枚举名**，不按 raw 常量猜
    ///
    /// 真机实测：raw **1 / 4 / 6** 全部落进旧的 `default`（打成「其它(N)」）—— 说明"经典 raw 表"
    /// （1=后台 / 2=音频 / 3=视频 / 4=分屏 / 5=系统压力）在本机机型 + iOS 26 上**不成立**。
    /// 所以一律用 `AVCaptureSession.InterruptionReason(rawValue:)` 具名匹配；`raw` 只进日志（留反查）。
    ///
    /// ## ✅ 符号已在 Mac 侧核实（2026-09-21 夜 · 真机 + SDK）
    ///
    /// `AVCaptureSession.h:88` = raw **1**、`:91` = raw **4** —— 两个 case 在 iOS 26 SDK **都在**，
    /// 编译 0 error；**白名单那条（后台不可用）确认可用**。真机另实测 raw **1 / 4 / 6** 都会出现
    /// （旧代码只认 2 / 3 / 5，于是全部落进 `default` 打成「其它(N)」）——
    /// 这就是"按**枚举名**匹配 + `@unknown default` 兜底"的由来。
    ///
    /// ⚠️ 未知原因一律 `benign = false`（**保守**）：闸门对未知情况继续生效。
    private static func interruptionReason(_ raw: Int) -> (text: String, benign: Bool) {
        guard let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return ("未知原因", false)
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            // 🔴 白名单里的**唯一一条**：与"抢占设备"无关（进后台 / 回前台必然来一发）
            return ("后台不可用（良性 · 与设备抢占无关）", true)
        case .audioDeviceInUseByAnotherClient:
            return ("音频设备被另一个客户端占用", false)
        case .videoDeviceInUseByAnotherClient:
            // 🔴 预热抢设备时会出现的那条 —— **必须保留闸门作用**（黑屏就是它）
            return ("视频设备被另一个客户端占用", false)
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return ("多前台 App 分屏导致不可用", false)
        case .videoDeviceNotAvailableDueToSystemPressure:
            return ("系统压力导致不可用", false)
        @unknown default:
            return ("其它原因", false)
        }
    }

    /// 在 begin/commit 区间内构建会话。返回可作为"格式写入目标"的设备。
    ///
    /// **本方法是幂等的**：入口处会先清空已有的 input / output。
    /// 因为"配置失败 → 用户点重试"的场景下会再进来一次，
    /// 如果上一次已经加进去了一部分（例如 input 成功、output 失败），
    /// 直接再 add 会命中 `canAddInput == false` 而永远修不好。
    private func buildSession() -> Result<AVCaptureDevice, Error> {
        // 过渡态抑制（批六 ② 收尾）：构建会话 = 最大的一次配置变更窗口
        isReconfiguring = true
        defer { self.isReconfiguring = false }
        session.beginConfiguration()
        // 关键顺序 1：必须先设 preset，且必须是 .inputPriority
        session.sessionPreset = .inputPriority

        // 幂等清理
        for input in session.inputs {
            session.removeInput(input)
            resourceInputRemoved()      // ④ 埋点（清理同样算一次删 —— 计数口径必须一致）
        }
        for output in session.outputs {
            session.removeOutput(output)
            resourceOutputRemoved()     // ④ 埋点
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
                    resourceInputAdded()    // ④ 埋点
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
    /// (设备 uniqueID + 模式) → 已探测成功的采集格式的**标识字符串**。
    ///
    /// ## 为什么存"标识"而不是格式对象
    ///
    /// `AVCaptureDevice.Format` 是设备的附属对象，**不能存盘**（下一次启动是另一批对象）。
    /// 所以存"尺寸 + 像素格式 + 帧率区间"这三件套组成的标识，命中时在当前设备的
    /// `formats` 里按同样的标识找回那个格式对象。
    ///
    /// ## 为什么要落盘（2026-09-20 批五 · 🔴问题 1①）
    ///
    /// 原本这个缓存只在**内存**里：App 每次启动都是冷的，于是**每会话的第一次换设备**
    /// 都要跑完整探测（12~41 个候选逐个 `applyFormat`，每个 300~800ms）
    /// = 4.2~5.0s（Mac 批四复验实测）。
    /// 那个耗时**直接导致静默路径被降级成转场**（用户要的"点对焦/开刻度条人眼无感"就没了），
    /// 所以缓存必须跨会话活着。
    private var formatProbeIdentities: [String: String] =
        (UserDefaults.standard.dictionary(forKey: formatProbeCacheDefaultsKey) as? [String: String]) ?? [:]

    /// 格式的**可持久化标识**（见 `formatProbeIdentities` 的说明）。
    ///
    /// 三件套：`宽x高 | 像素格式(FourCC) | 帧率区间`。
    /// 同一台设备上三者全同基本就是同一个格式；万一撞了也只是"少试几个候选"，
    /// 而且照片类模式还有一道 **Live 能力自愈**（见 `applyPreferredFormatLocked`）。
    private static func formatIdentity(_ format: AVCaptureDevice.Format) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subType = format.formatDescription.mediaSubType.rawValue
        let ranges = format.videoSupportedFrameRateRanges
        let minFPS = ranges.map(\.minFrameRate).min() ?? 0
        let maxFPS = ranges.map(\.maxFrameRate).max() ?? 0
        return "\(size.width)x\(size.height)|\(subType)"
            + "|\(String(format: "%.0f", minFPS))-\(String(format: "%.0f", maxFPS))"
    }

    private func persistFormatProbeIdentities() {
        UserDefaults.standard.set(formatProbeIdentities, forKey: formatProbeCacheDefaultsKey)
    }

    private func applyPreferredFormatLocked(to device: AVCaptureDevice) {
        // ⚠️ 视频 / Log 模式下照片输出**不挂载** → `isLivePhotoCaptureSupported` 恒 false
        // （2026-09-20 Mac 复验 🟠 问题 4）—— Live 挑选循环永远选不出（41 候选跑满 9.1s
        // 落第一个候选）。这两个模式**不需要 Live**：直接走"第一个候选"（最小 1080p 档），
        // 不进 Live 探测循环；同样写缓存（模式在 key 里，回照片模式仍会完整探测一次）。
        let needsLiveProbe = mode == .photo || mode == .livePhoto
        let cacheKey = "\(device.uniqueID)|\(mode.rawValue)"

        // A/B 开关（Mac 复验用，不必重出构建）：`-lumen.camera.formatProbe.fastpath.disabled YES`
        // → 关掉"Live 优先序 + 零成本短路"，回到旧的逐候选顺序 → 应复现 4.41s 的冷探测。
        let fastPathEnabled = !UserDefaults.standard.bool(
            forKey: "lumen.camera.formatProbe.fastpath.disabled"
        )

        // ① 缓存命中（优先磁盘里的标识）：**一次 applyFormat 直达**
        if let identity = formatProbeIdentities[cacheKey],
           let cached = device.formats.first(where: { Self.formatIdentity($0) == identity }) {
            var applied = false
            do {
                try configurator.applyFormat(cached, frameRate: 30, to: device)
                applied = true
            } catch {
                DebugLog.shared.warn(
                    "session",
                    "缓存标识解析出的格式应用失败 → 回退完整探测：\(error.localizedDescription)"
                )
            }
            // **自愈**：照片类模式要求 Live 能力 —— 缓存里的格式若不满足（系统/机型变化、
            // 或标识撞档），一律作废并回退完整探测，宁可慢一次也不能把 Live 能力悄悄关掉。
            if applied, needsLiveProbe, !photoService.output.isLivePhotoCaptureSupported {
                DebugLog.shared.warn("session", "缓存格式不支持 Live Photo → 作废缓存并回退完整探测")
                applied = false
            }
            if applied {
                DebugLog.shared.info(
                    "session",
                    "采集格式命中**缓存**（跳过探测循环）：\(CaptureCapabilities.formatSummary(cached))"
                )
                return
            }
            formatProbeIdentities[cacheKey] = nil
            persistFormatProbeIdentities()
        }

        // ② 候选表：**Live 探测走优先序**（`420v` 优先 + 面积降序 —— 真机全表反推：命中位次 12 → 1，
        //    见 `CaptureCapabilities.liveProbePreferredCandidates`）；视频 / Log 仍走原序
        //    （它们取"第一个候选"，换序会把视频档位改成大尺寸 —— 那是行为改变，不是优化）。
        let candidates: [AVCaptureDevice.Format] = (needsLiveProbe && fastPathEnabled)
            ? CaptureCapabilities.liveProbePreferredCandidates(for: device)
            : CaptureCapabilities.formatCandidates(
                for: device,
                minimumWidth: 1920,
                targetFrameRate: 30
            )

        guard !candidates.isEmpty else {
            DebugLog.shared.warn("session", "没有找到满足条件的采集格式，沿用设备默认格式")
            return
        }

        // ③ 闸门（覆盖**启动配置 / 换设备 / 切模式**三条入口 —— 见「格式探测闸门」节）：
        //    持本次代次，循环里每个候选前查一次"这段时间有没有被真实打断"。
        let probeToken = beginFormatProbe()
        let probeStarted = Date()

        // ④ **P-a 零成本短路**：设备当前 `activeFormat` 若**已经就是首试目标**，则一次
        //    `applyFormat` 都不用（实测：设备被运行中的会话使用时每次 ≈0.295s）。
        //    ⚠️ 只认"就是首试目标"这一种情况 —— 若放宽成"当前格式只要 Live 就接受"，会把采集格式
        //    留在较小那档（如 1920x1440），那是**画质行为改变**、不是优化。
        if needsLiveProbe, let first = candidates.first, device.activeFormat === first,
           photoService.output.isLivePhotoCaptureSupported {
            formatProbeIdentities[cacheKey] = Self.formatIdentity(first)
            persistFormatProbeIdentities()
            DebugLog.shared.info(
                "session",
                "冷探测：设备已停在首试目标 → **0 次 applyFormat**（耗时 0.00s）"
                    + "｜\(CaptureCapabilities.formatSummary(first))"
            )
            return
        }

        var fallback: AVCaptureDevice.Format?
        var chosen: AVCaptureDevice.Format?
        var attempts = 0
        var stoppedByInterruption = false

        for candidate in candidates {
            // 闸门：被**真实打断** → 立刻收手（不再在会话已被扰动时继续 churn，每次 ≈0.3s）
            if isFormatProbeInterrupted(probeToken) {
                stoppedByInterruption = true
                break
            }
            attempts += 1
            do {
                try configurator.applyFormat(candidate, frameRate: 30, to: device)
            } catch {
                DebugLog.shared.error("session", "应用采集格式失败：\(error.localizedDescription)")
                continue
            }
            if fallback == nil { fallback = candidate }
            // 视频 / Log：不需要 Live —— 第一个候选（最小档）即可，写缓存直达
            if !needsLiveProbe {
                chosen = fallback
                break
            }
            if photoService.output.isLivePhotoCaptureSupported {
                chosen = candidate
                break
            }
        }

        // ⑤ **P-b2 兜底（降级版 · 只给一次机会）**：整轮都没试出 Live → 借"同模式兄弟设备已命中的
        //    标识"再试一次。为什么只有这么一点：三颗镜头命中档的 `dims|subType|fps` 实测完全一致、
        //    优先序已让首试就命中，而"把格式写进设备"本身就必然要 1 次 `applyFormat`
        //    → 跨镜头"预测"的边际收益 ≈ 0，只值这一次兜底。
        if chosen == nil, needsLiveProbe, fastPathEnabled, !stoppedByInterruption {
            let suffix = "|\(mode.rawValue)"
            let siblingIdentity = formatProbeIdentities
                .first { $0.key != cacheKey && $0.key.hasSuffix(suffix) }?.value
            if let siblingIdentity,
               let sibling = device.formats.first(where: { Self.formatIdentity($0) == siblingIdentity }) {
                attempts += 1
                if (try? configurator.applyFormat(sibling, frameRate: 30, to: device)) != nil,
                   photoService.output.isLivePhotoCaptureSupported {
                    chosen = sibling
                }
            }
        }

        // 兜底路径下循环可能停在"最后一个试过且不支持 Live Photo"的格式上，
        // 这里把设备还原到兜底档（`chosen` 优先，否则第一个试过的那个）。
        let final = chosen ?? fallback
        if let final, final !== device.activeFormat {
            do {
                try configurator.applyFormat(final, frameRate: 30, to: device)
            } catch {
                DebugLog.shared.error("session", "回退采集格式失败：\(error.localizedDescription)")
            }
        }

        // 📏 判据 a（Mac 核法）：候选数 / `applyFormat` 次数 / 耗时 —— 一眼看出快速路径有没有生效
        let cost = Date().timeIntervalSince(probeStarted)
        DebugLog.shared.info(
            "session",
            "冷探测：候选 \(candidates.count) 个，applyFormat \(attempts) 次，耗时 "
                + String(format: "%.2f", cost) + "s"
                + (fastPathEnabled ? "（Live 优先序）" : "（A/B：优先序已关）")
        )
        if stoppedByInterruption {
            // 被打断时试到的结果**不算数**（不写缓存）—— 下次老老实实重探
            DebugLog.shared.warn(
                "session",
                "⚠️ 探测期间会话被打断 → 已在第 \(attempts) 次候选处收手，采用兜底格式（不写缓存）"
            )
            return
        }

        guard let final else { return }
        // 写缓存（**带标识落盘**，跨会话复用 —— 批五 问题 1①）
        formatProbeIdentities[cacheKey] = Self.formatIdentity(final)
        persistFormatProbeIdentities()
        DebugLog.shared.info(
            "session",
            "选用采集格式 \(CaptureCapabilities.formatSummary(final))"
                + "，Live Photo 能力=\(photoService.output.isLivePhotoCaptureSupported)"
                + "（候选共 \(candidates.count) 个 · applyFormat \(attempts) 次，已缓存并落盘）"
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
                    resourceInputAdded()        // ④ 埋点（麦克风输入）
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
                resourceInputRemoved()      // ④ 埋点（麦克风输入）
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
            resourceOutputRemoved()     // ④ 埋点
        }

        switch targetMode {
        case .photo, .livePhoto:
            guard session.canAddOutput(photoService.output) else {
                DebugLog.shared.error("session", "无法加入照片输出")
                return false
            }
            session.addOutput(photoService.output)
            resourceOutputAdded()       // ④ 埋点
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
            resourceOutputAdded()       // ④ 埋点
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
