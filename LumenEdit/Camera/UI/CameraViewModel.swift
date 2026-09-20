import Combine
import Foundation
import UIKit

/// 场景 / 风格 / 滤镜三项选中态的落盘键（#6）。
///
/// 为什么落盘：原型把它们存进 `LS_SHOOT`，冷启动会恢复 —— 相机 App 里"上次选的场景"
/// 每次重选是明显倒退。「保留设置」开关（只保留其中几项）属模块 #12，暂未做：现在三项都存。
private enum SceneStyleStorageKey {
    static let scene = "lumen.camera.scene"
    static let style = "lumen.camera.style"
    static let filter = "lumen.camera.filter"
}

/// 功能面板五项拍摄现场设置的落盘键（#10）。原型存进 `LS_SHOOT` 的 `state.fn`。
///
/// 面板开合**不落盘**（临时浮层状态），HUD 用 `AppEnvironment.showDebugHUD`（已落盘）。
private enum FunctionPanelStorageKey {
    static let live = "lumen.camera.fn.live"
    static let ratio = "lumen.camera.fn.ratio"
    static let flash = "lumen.camera.fn.flash"
    static let timer = "lumen.camera.fn.timer"
    static let hdr = "lumen.camera.fn.hdr"
}

/// 视频格式（#11）的落盘键。原型把这组存进 `LS_SHOOT` 的 `state.fmt`。
///
/// 选择器开合**不落盘**（临时浮层状态）。
private enum VideoFormatStorageKey {
    static let resolution = "lumen.camera.fmt.res"
    static let frameRate = "lumen.camera.fmt.fps"
}

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

    /// 当前选中的焦段档位（2-3 焦段条的选中态；⤢ 放大态下它浮进取景器卡片内底边）。
    ///
    /// **不落盘**：原型的「保留设置」只管 场景 / 风格 / 滤镜 / EV 四项，焦段不在其中。
    /// ⚠️ 这一行在 2-5b 的编辑里被误删过（`isZoomOn` 那次编辑本意是**新增**，却替换掉了它），
    /// 导致 `focalTapped` 与 `CameraView` 里的绑定全部失效、CI 编译报错。别再删。
    @Published private(set) var focal: FocalPreset = FocalCatalog.defaultFocal

    // MARK: - 场景 · 风格（#6）

    /// 场景 · 风格条的展开态。**不落盘**：拍摄时的临时手势状态（原型也没存它）。
    @Published private(set) var isSceneStyleExpanded = false

    /// 滤镜条的展开态（#7）。**不落盘**：与场景·风格展开态同为临时手势状态
    /// （原型 `layout.filterExpanded` 也不进「保留设置」）。
    /// 状态在 VM，渲染在 `FilterStripView`（⤢ 放大态下强制隐藏，见 `CameraView`）。
    @Published private(set) var isFilterStripExpanded = false

    /// EV 圆盘（#8 · B3a）的展开态。**不落盘**：临时浮层状态。
    ///
    /// ## 为什么参数排（EV 滑条面板）被它取代 —— 原型改版，Swift 对齐
    ///
    /// 原型 2026-09-17 第八轮「圆盘统一 v2」后：EV 的调节入口 = **圆盘**
    /// （点图标行「曝光补偿」展开，`iconEV` → `layout.evOpen`），旧四列参数排的
    /// EV 数值位**已随改版删除**（原型 `index.html:2376` 明文）。EV 值由圆盘数值框
    /// 显示（`renderEv`），归零也在数值框上点。
    ///
    /// ## 它是**模态**，不是底栈一行（原型 `.screen.ev-on .bottom-stack{display:none}`）
    ///
    /// 打开时**整条底部浮层栈收起**（滤镜条 / 场景·风格 / 焦段条 / 快门排 / 图标行全藏），
    /// 圆盘下只剩取景器 —— 与功能面板"盖住底栏"同款语义，但**更彻底**（底栈整条走）。
    /// 所以它的互斥是两方向：
    ///   ① 开圆盘 → 收其它扩展浮层（`evDialTapped` 展开分支，**展开者只收别人**）；
    ///   ② 开其它浮层 / 点别处 → 收圆盘（各入口 + `dismissTransientPopovers()`）。
    /// ⚠️ 展开者自己**不能调** `dismissTransientPopovers()`（会把刚展开的自己收掉，
    /// 2026-09-18 真机踩过的坑）。
    @Published private(set) var isEvDialShown = false

    /// 对焦圆盘（#8 后半 · B3b）的展开态。**不落盘**：临时浮层状态。
    ///
    /// 与 EV 圆盘同款**模态**（打开收整条底栈）；差异只在**入口能力分派**（拍板 ①·A）：
    /// 虚拟多摄不支持手动对焦 → 点「对焦」图标 = **toast 说明、不开盘**
    /// （`isManualFocusSupported`，与 B2 手动开关同款诚实边界）；物理镜头架构落地后
    /// 探测自动变 true，盘可开、拖动写硬件，UI 零改动。
    @Published private(set) var isFocusDialShown = false

    /// 对焦读数（显示状态，0~1）。
    ///
    /// **自动/手动都跟硬件走**：session `currentLensPosition` 回写（自动对焦进行中
    /// 读数"自己会走"）；拖动期由 `focusDialValueChanged` 写入、回写闸门挡住积压旧值
    /// （`docs/14` 同构，见 `attach()` 里的对焦订阅）。
    @Published var focusLensPosition: Double = 0.56

    /// 是否处于**手动对焦档**（2026-09-20 正源修：派生自**用户意图态**
    /// `session.manualFocus != nil`，不再从硬件 `focusMode == .locked` 推断 ——
    /// `.autoFocus` 完成后系统也置 `.locked`，回读分不清两种锁，Mac 复验 ③ 根因）。
    var isFocusManual: Bool { environment?.session.manualFocus != nil }

    /// 是否处于**自动对焦**（对焦盘「自动对焦」开关的显示状态，派生不记账；
    /// 同 `isFocusManual` —— 意图态，非硬件回读）。
    var isFocusAuto: Bool { environment?.session.manualFocus == nil }

    // MARK: - 功能面板（#10）

    /// 功能面板（⠿）的展开态。**不落盘**：临时浮层状态。
    ///
    /// 原型 `layout.fnOpen`，面板是**盖住底栏的模态浮层**（不是底栈一行）——
    /// 打开时会收起其它扩展浮层（`collapseOverlays()`），点面板外任意处收起。
    @Published private(set) var isFunctionPanelExpanded = false

    /// 面板「实况」：**照片模式**下是否采集 Live Photo（落盘）。
    ///
    /// ⚠️ 与模式条的「实况」模式 (`CaptureSessionMode.livePhoto`) 是**两回事**（原型注释同款）：
    /// 这里管的是"照片模式下也拍 Live"。本件只到"状态 + 角标"——
    /// 真正让 `.photo` 模式打开 Live 采集（`PhotoCaptureService.prepareTemplate` 的
    /// `.photo` 分支现在显式关掉它）属 B 组接线。
    @Published private(set) var isFnLiveOn: Bool =
        UserDefaults.standard.bool(forKey: FunctionPanelStorageKey.live) {
        didSet { UserDefaults.standard.set(isFnLiveOn, forKey: FunctionPanelStorageKey.live) }
    }

    /// 面板「画幅比」（落盘）。默认 `4:3`（原型初值）—— **默认就有遮幅**，见 `FrameRatioMask`。
    @Published private(set) var fnRatio: FrameRatio =
        FrameRatio(rawValue: UserDefaults.standard.string(forKey: FunctionPanelStorageKey.ratio) ?? "")
        ?? .r4x3 {
        didSet { UserDefaults.standard.set(fnRatio.rawValue, forKey: FunctionPanelStorageKey.ratio) }
    }

    /// 面板「闪光灯」（落盘；硬件未接，只记状态）
    @Published private(set) var isFnFlashOn: Bool =
        UserDefaults.standard.bool(forKey: FunctionPanelStorageKey.flash) {
        didSet { UserDefaults.standard.set(isFnFlashOn, forKey: FunctionPanelStorageKey.flash) }
    }

    /// 面板「倒计时」（落盘；硬件未接，只记状态）
    @Published private(set) var fnTimer: ShootTimer =
        ShootTimer(rawValue: UserDefaults.standard.string(forKey: FunctionPanelStorageKey.timer) ?? "")
        ?? .off {
        didSet { UserDefaults.standard.set(fnTimer.rawValue, forKey: FunctionPanelStorageKey.timer) }
    }

    /// 面板「高亮增益 HDR」（落盘；硬件未接，只记状态）
    @Published private(set) var isFnHDROn: Bool =
        UserDefaults.standard.bool(forKey: FunctionPanelStorageKey.hdr) {
        didSet { UserDefaults.standard.set(isFnHDROn, forKey: FunctionPanelStorageKey.hdr) }
    }

    // MARK: - 视频格式（#11）

    /// 格式选择器是否展开（点芯片弹出）。**不落盘**（临时浮层状态）。
    @Published private(set) var isFormatSelectorExpanded = false

    /// 选中的分辨率（落盘）。默认 `4K`。
    @Published private(set) var videoResolution: VideoResolution =
        VideoResolution(
            rawValue: UserDefaults.standard.string(forKey: VideoFormatStorageKey.resolution) ?? ""
        ) ?? .uhd4K {
        didSet {
            UserDefaults.standard.set(videoResolution.rawValue, forKey: VideoFormatStorageKey.resolution)
        }
    }

    /// 选中的帧率（落盘）。
    ///
    /// ⚠️ **默认 30 而不是原型初值的 60**（用户 2026-09-18 拍板）：会话目前固定
    /// `applyFormat(..., frameRate: 30)`（`CaptureSessionController:585/602`）——
    /// 芯片是"当前状态指示"而非"目标值声明"，显示 60 就是撒谎。
    /// B 组接上 `activeFormat` 重设后，这里应改为**读取会话真实格式**（那才是终态）。
    @Published private(set) var videoFrameRate: VideoFrameRate =
        VideoFrameRate(rawValue: UserDefaults.standard.integer(forKey: VideoFormatStorageKey.frameRate))
        ?? .fps30 {
        didSet {
            UserDefaults.standard.set(videoFrameRate.rawValue, forKey: VideoFormatStorageKey.frameRate)
        }
    }

    /// 芯片文案（`4K · 30`；Log 实况模式 `Log · 4K · 30`）
    var formatChipText: String {
        VideoFormatCatalog.chipText(
            resolution: videoResolution,
            frameRate: videoFrameRate,
            isLogMode: mode == .logLive
        )
    }

    /// 顶栏副行「剩余存储」胶囊的文本。
    ///
    /// 录制类模式（视频 / Log 实况）换成**剩余可录时长 + 空间**（原型 `renderFmt` 同款）——
    /// 那是拍摄时的关键信息。
    /// ⚠️ 文本变长后 `TopBarView` 的**宽度预留**必须同步换形态（见其 `storageWidthReservation`），
    /// 否则数值到达时胶囊会跳宽 —— Mac 侧实测过的 73 → 95pt 跳变会复发。
    var storageChipText: String {
        guard mode.isRecordingBased else {
            return environment?.session.freeSpaceText ?? "—"
        }
        return VideoFormatCatalog.recordingTimeText(
            resolution: videoResolution,
            frameRate: videoFrameRate
        )
    }

    /// 选中的场景 id（落盘）
    @Published private(set) var sceneId: String =
        UserDefaults.standard.string(forKey: SceneStyleStorageKey.scene)
        ?? SceneCatalog.all[0].id {
        didSet { UserDefaults.standard.set(sceneId, forKey: SceneStyleStorageKey.scene) }
    }

    /// 选中的风格 id（落盘）
    @Published private(set) var styleId: String =
        UserDefaults.standard.string(forKey: SceneStyleStorageKey.style)
        ?? StyleCatalog.all[0].id {
        didSet { UserDefaults.standard.set(styleId, forKey: SceneStyleStorageKey.style) }
    }

    /// 选中的滤镜 id（落盘；nil = 无滤镜）。滤镜条（#7）会共用这个状态。
    @Published private(set) var filterId: String? =
        UserDefaults.standard.string(forKey: SceneStyleStorageKey.filter) {
        didSet { UserDefaults.standard.set(filterId, forKey: SceneStyleStorageKey.filter) }
    }

    /// 当前场景对象（id 解析不出来时退回第一个场景）
    var scene: ScenePreset { SceneCatalog.scene(id: sceneId) ?? SceneCatalog.all[0] }
    /// 当前风格对象
    var style: StylePreset { StyleCatalog.style(id: styleId) ?? StyleCatalog.all[0] }
    /// 当前滤镜对象
    var filter: FilterDefinition? { FilterCatalog.all.first { $0.id == filterId } }
    /// 当前滤镜名（给折叠胶囊 / 块标题用）
    var filterName: String? { filter?.displayName }

    /// ⤢ 放大拍摄布局是否开启（2-5b）。
    ///
    /// 开启后：取景器卡片化、焦段条浮进卡片内底边、参数排与图标行让位、
    /// 快门放大 1.3 倍、左右两组竖排并淡入「前置 / 设置」镜像按钮（见 `docs/09` 第三节）。
    /// **不落盘**：这是拍摄时的临时手势状态，原型也没把它放进「保留设置」。
    @Published private(set) var isZoomOn = false

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

    /// 最近一次**推送出去**的 EV 值，用于回写守卫：只接受与它一致的回写。
    ///
    /// 为什么需要：拖动中每跨一档推一次硬件，`sessionQueue` 按序回放 ——
    /// 松手瞬间积压的旧值会依次回来（"松手后跳一下"）。用它与回写值比对即可丢弃。
    /// **切模式 / 会话就绪时必须置 `nil`**（那时硬件值来自设备而非我们推送）。
    private var lastPushedExposureBias: Float?

    /// 最近一次**推送出去**的对焦值（`docs/14` 同构闸门，B3b）。
    private var lastPushedLensPosition: Float?

    /// 对焦盘**是否正在拖动**（回写闸门；对焦盘开着时整页手势本已禁言，
    /// 这道闸门挡的是**硬件回写**链路本身）。
    @Published private(set) var isFocusEditing = false

    // MARK: - 装配

    /// 由视图在 `onAppear` 时调用。`@StateObject` 无法在初始化时拿到 EnvironmentObject，
    /// 所以用这种"后装配"的方式，重复调用是安全的。
    func attach(_ environment: AppEnvironment) {
        guard !isAttached else { return }
        isAttached = true
        self.environment = environment

        // 硬件侧读回来的曝光补偿 → 同步到滑块。
        //
        // ⚠️ **两道守卫，缺一不可**（2026-09-18 真机反馈"EV 条反复跳动"，根因见 `docs/14`）：
        //
        //   ① **拖动期间不回写**。回写这条链路有四段异步
        //      （`sessionQueue` → 设备锁 → `publish` 的 `main.async` → 本订阅的 `RunLoop`），
        //      拖快时回来的是**几拍之前**的值。把滑条拽回旧档位还不算最糟 ——
        //      下一次 `onChanged` 里的**滞后判定会以"被拽回的值"当基准**，于是同一个档位边界
        //      被重复跨越、触觉重复触发。**滞后比越大跳动越明显，这是环路的判别特征**
        //      （纯密度问题不会对比值敏感）。
        //   ② **只接受与最后推送值一致的回写**。拖动尾部积压在 `sessionQueue` 里的旧值
        //      会在松手瞬间被依次回放（表现为"松手后跳一下"）。
        environment.session.$exposureBias
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                guard !self.isExposureEditing else { return }
                if let sent = self.lastPushedExposureBias,
                   abs(Double(sent) - Double(value)) >= 0.001 {
                    return
                }
                self.exposureBias = Double(value)
            }
            .store(in: &cancellables)

        // 对焦读数回写（B3b）：**自动/手动都跟** —— session `currentLensPosition` 是
        // "当前镜头位置"（手动锁定时恒定 = 锁定值；自动对焦进行中实时变化，
        // 对焦盘读数"自己会走"）。闸门与 EV 同构（`docs/14`）：
        //   ① 拖动期不回写；② 只接受与最后推送值一致的回写。
        environment.session.$currentLensPosition
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                guard !self.isFocusEditing else { return }
                if let sent = self.lastPushedLensPosition,
                   abs(Double(sent) - Double(value)) >= 0.001 {
                    return
                }
                self.focusLensPosition = Double(value)
            }
            .store(in: &cancellables)

        // 换设备完成边沿（isLensSwitching true→false）→ 执行**待重放动作**（拍板 ①：
        // 虚拟会话点手动开关/对焦入口 = 先切物理，完成后自动执行原动作）。
        environment.session.$isLensSwitching
            .receive(on: RunLoop.main)
            .sink { [weak self] switching in
                guard let self, !switching, let action = self.pendingManualAction else { return }
                self.pendingManualAction = nil
                switch action {
                case .toggleManualStrip(let kind):
                    self.stripAutoToggled(kind)
                case .openFocusDial:
                    self.focusDialTapped()
                }
            }
            .store(in: &cancellables)

        // 回切防抖（预检 ①，docs/20 第四节）：三个意图态**全空** + 物理会话 → 2s 后切回虚拟。
        environment.session.$manualExposure
            .combineLatest(environment.session.$manualWhiteBalance, environment.session.$manualFocus)
            .map { $0.0 == nil && $1 == nil && $2 == nil }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] allAuto in
                self?.evaluateRevertToVirtual(allAuto: allAuto)
            }
            .store(in: &cancellables)

        // 会话侧的模式 → 同步到 UI；**同时清空"最后推送值"记录** ——
        // 切模式会重建会话，之后的硬件值来自设备（不是我们推的），必须允许回写
        environment.session.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.mode = value
                self?.lastPushedExposureBias = nil
                self?.lastPushedLensPosition = nil
            }
            .store(in: &cancellables)

        // 会话就绪（冷启动 / 重建完成）同样清空 —— 那一刻 publish 出来的 EV 来自设备当前值，
        // 不是我们推送的，留着记录会把合法回写误吞掉。
        // 顺带（B1）：**按当前焦段档位对齐一次硬件 zoom**，原因见 `reapplyFocalAfterSessionReady`。
        //
        // ⚠️ `removeDuplicates()` 不能省（2026-09-19 真机抓到：同一帧打印两遍"焦段已对齐"）：
        // `@Published` 是 willSet 语义 —— **赋一个相同的值同样会发通知**；而 `.running`
        // 在冷启动时会被发两次（`startInternal` 先被 `setVisible(true)` 走一次、
        // 再被 scenePhase 的 `setAppActive(true)` 走一次）。少了它，下面两件副作用
        // （清 EV 回写记录 + 按档位对齐 zoom）都会重复执行。
        // 根因层已在 `CaptureSessionController` 那边加了"同值不重发"守卫，这里是第二道 ——
        // 它同时兜住任何**将来新增**的重发路径。
        environment.session.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, state == .running else { return }
                self.lastPushedExposureBias = nil
                self.lastPushedLensPosition = nil
                self.reapplyFocalAfterSessionReady()
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
        dismissTransientPopovers()
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
                // 视频要抽首帧（异步）：决策 #2 的修复，见 ThumbnailCache.rememberCapturedFile
                await environment.thumbnails.rememberCapturedFile(at: url)
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
        // 点取景器 = 对焦 + 收起功能面板（原型 viewport 的 click 处理器同时做这两件事）
        dismissTransientPopovers()
        if isFocusManual {
            // ⚠️ 拍板 ③（2026-09-19）：手动对焦锁定期间，点按**只测光、不动焦** ——
            // 用户锁了焦就是不想让它动；测光仍有用（自动曝光档下生效）。
            // 焦点框照常显示（UI 反馈），日志留痕。
            environment?.session.setExposurePointOnly(devicePoint)
            DebugLog.shared.debug(
                "ui",
                "手动对焦锁定中 → 点按仅测光（不动焦）"
            )
        } else {
            environment?.session.focus(atDevicePoint: devicePoint)
        }
        focusPoint = viewPoint
        focusToken &+= 1
        Haptics.focus()
    }

    // MARK: - 曝光

    /// 参数排（EV 滑块）**是否正在被拖动**。
    ///
    /// 为什么要这个状态：`CameraView` 的上划 / 下划手势挂在**整页 ZStack** 上
    /// （`simultaneousGesture`，见那里的注释），它与 EV 滑条的拖动是**并发识别**的。
    /// 而横拖 EV 时手指几乎必然带纵向抖动 —— 提前触发（滑够 16pt 立即生效）下，
    /// 这点抖动就足以被判成"下划"，把面板当场收起（2026-09-18 真机实锤：
    /// 横拖中途 `toast: 已收起参数排`）。所以**滑块拖动期间必须让整页手势禁言**。
    ///
    /// ⚠️ 这只是"精确闸门"（只覆盖 EV 滑块）；横滑条那类控件的同类误触由
    /// `CameraView` 的**方向锁**兜住（见 `swipeAxis`）。
    @Published private(set) var isExposureEditing = false

    /// 是否处于**手动曝光档**（ISO / 快门 被锁定）—— 派生自硬件真值，不本地记账
    private var isManualExposureActive: Bool { environment?.session.manualExposure != nil }

    /// EV 滑块开始 / 结束拖动。
    ///
    /// 两个职责：
    ///   1. 维护 `isExposureEditing` —— 它是**整页手势的闸门**（`CameraView`）与**硬件回写的闸门**
    ///      （本文件 `$exposureBias` 订阅），见 `docs/14`；
    ///   2. 记录本次推送的值（`lastPushedExposureBias`），供回写守卫丢弃队列里积压的旧值。
    ///
    /// ⚠️ 顺序有讲究：**先复位编辑态、再推硬件**。松手那一下推出的值会正常回写回来
    ///（此时编辑态已复位），"松手后以最终吸附值为准同步一次"就靠这个顺序自然成立。
    ///
    /// ⚠️ **手动曝光档下必须拦下**（`docs/16` 第五节 ②）：`setExposureTargetBias` 在手动档下
    /// 会被系统忽略，而 `CaptureDeviceConfigurator.applyExposureBias` 里那条"顺手回切自动档"
    /// 的最后防线会把设备**从手动档切走** —— 也就是"拖一下 EV，ISO/快门 的锁定静默失效"。
    /// UI 侧已禁用 EV 面板（第三道），这里是第二道；真被走到说明 UI 漏了 → 留痕。
    func exposureEditingChanged(_ isEditing: Bool) {
        if isExposureEditing != isEditing {
            isExposureEditing = isEditing
        }
        guard !isManualExposureActive else {
            lastPushedExposureBias = nil
            DebugLog.shared.warn(
                "ui",
                "手动曝光档下收到 EV 拖动 → 已拦下（EV 面板本应禁用，出现这条说明拦漏了）"
            )
            return
        }
        lastPushedExposureBias = Float(exposureBias)
        environment?.session.setExposureBias(Float(exposureBias))
    }

    // MARK: - 参数刻度条（B2 · 模块 #9）

    /// 当前展开的那条刻度条（`nil` = 收起）。
    ///
    /// **单值寄存** —— "同一时刻只显示一条"由类型保证（原型 `state.paramStrip` 同款），
    /// 不需要互斥判断。**不落盘**：临时浮层状态。
    @Published private(set) var paramStrip: ParameterStripKind?

    /// 拖动草稿：**ISO 与快门必须成对写**（`setExposureModeCustom` 一次接管两者），
    /// 所以拖某一条时要记住另一条 —— 这份草稿保存这一对。
    ///
    /// ## 为什么用草稿，而不是"本地值 + 回写闸门"
    ///
    /// `docs/16` 原方案写的是"刻度条要接与 `docs/14` 同款的回写闸门（拖动期不回写 + 只接受最后推送值）"。
    /// 实现时发现一个更省的结构：**显示值在拖动期取草稿（跟手）、其余时刻取硬件真值** ——
    /// 本地值根本不会与硬件值"打架"，所以那道闸门**不需要存在**。
    /// 少一套状态 = 少一类 bug（`docs/14` 那个环路就是"本地值被硬件回写擅自改写"造成的）。
    private var isoShutterDraft: (iso: Double, seconds: Double)?
    private var whiteBalanceDraft: Double?

    /// ISO / 快门 是否处于**自动档** —— **派生自硬件真值**，不本地记账
    ///
    /// 为什么要回读而不是自己记：`exposureMode` 是同一个 device 实例上的真值，
    /// 切模式不换 device ⇒ 手动档会活下来；而且**点按对焦会把曝光打回自动**
    /// （`setFocusAndExposurePoint` 里设了 `continuousAutoExposure`）——
    /// 本地记账必然出现"UI 说手动、设备是自动"。见 `docs/16` 第六节。
    var isISOShutterAuto: Bool { environment?.session.manualExposure == nil }

    /// 白平衡是否处于自动档（同上，派生值）
    var isWhiteBalanceAuto: Bool { environment?.session.manualWhiteBalance == nil }

    /// 某条刻度条**当前应显示的值**：拖动期 = 草稿（跟手），其余 = **硬件真值**（`nil` = 自动态）
    func stripDisplayValue(_ kind: ParameterStripKind) -> Double? {
        guard let environment else { return nil }
        switch kind {
        case .iso:
            if let draft = isoShutterDraft { return draft.iso }
            return environment.session.manualExposure.map { Double($0.iso) }
        case .shutter:
            if let draft = isoShutterDraft { return draft.seconds }
            return environment.session.manualExposure.map { $0.seconds }
        case .whiteBalance:
            if let draft = whiteBalanceDraft { return draft }
            return environment.session.manualWhiteBalance.map { Double($0.temperature) }
        }
    }

    /// 某条刻度条在这台设备上**不可用**的档位值（UI 置灰用；**灰但仍可点**，点了给 toast）
    func unavailableStripValues(for kind: ParameterStripKind) -> Set<Double> {
        environment?.session.unavailableStripValues[kind] ?? []
    }

    /// 设备当前的 ISO / 曝光时长（**自动档也有效** —— 取 AE 的收敛值）。
    /// 自动→手动切换时用它当初值（用户 2026-09-19 拍板 ③：初值取设备当前值，画面不跳）。
    private func currentExposurePair(_ environment: AppEnvironment) -> (iso: Double, seconds: Double) {
        let current = environment.session.currentExposure
        return (Double(current.iso), current.seconds)
    }

    /// 点图标行「白平衡 / 感光 / 快门速度」= 展开该条刻度条。
    ///
    /// 原型 `toggleStrip(id)`：**再点同一条 = 收起**；点另一条 = 换条（单值寄存天然成立）。
    /// 展开时收起其余扩展浮层（原型 `toggleStrip` 里那三行：场景·风格 / 滤镜条 / 参数排）。
    func stripTapped(_ kind: ParameterStripKind) {
        // ⚠️ 这里**不能**用 `dismissTransientPopovers()` —— 它会把刻度条**自己也收掉**，
        // 于是"再点同一条 = 收起"永远走不到、换条也会变成收起。
        // 与 `formatChipTapped` 同款：**展开者只收别人**；点别处收起由
        // `dismissTransientPopovers()`（外部控件调）负责。
        dismissFunctionPanelIfNeeded()
        dismissFormatSelectorIfNeeded()

        let willExpand = paramStrip != kind
        paramStrip = willExpand ? kind : nil

        // 展开时的连带收起：toast 里要**说清**（本项目"状态改写必须留痕"的纪律）
        let collapsedNames = [
            isEvDialShown ? "EV 圆盘" : nil,
            isFocusDialShown ? "对焦圆盘" : nil,
            isFilterStripExpanded ? "滤镜条" : nil,
            isSceneStyleExpanded ? "场景·风格" : nil
        ].compactMap { $0 }

        if willExpand {
            isEvDialShown = false
            isFocusDialShown = false
            isFilterStripExpanded = false
            isSceneStyleExpanded = false
        }
        Haptics.tick()

        DebugLog.shared.debug(
            "ui",
            "刻度条\(willExpand ? "展开" : "收起")（\(kind.displayName)）"
                + (collapsedNames.isEmpty ? "" : " · 连带收起 \(collapsedNames.joined(separator: "、"))")
        )

        guard willExpand else {
            showToast("\(kind.displayName) 刻度条已收起")
            return
        }
        let draftNote = collapsedNames.isEmpty
            ? ""
            : " · \(collapsedNames.joined(separator: "与"))已收起"
        if isAutoStrip(kind) {
            showToast("\(kind.displayName)：自动（点右侧开关切手动）\(draftNote)")
        } else if let value = stripDisplayValue(kind) {
            showToast(
                "\(kind.displayName)：手动 \(ParameterStripCatalog.label(for: kind, value: value))"
                    + "（左右滑动刻度）\(draftNote)"
            )
        } else {
            showToast("\(kind.displayName) 刻度条\(draftNote)")
        }
    }

    /// 某条刻度条当前是否自动档（**给 UI 用** —— 刻度条视图与图标行都要读它）
    ///
    /// ⚠️ ISO 与快门**共用** `isISOShutterAuto`（硬件约束：锁了 ISO 就得接管曝光时长，
    /// 两者不可能一个自动一个手动），白平衡用独立的 `isWhiteBalanceAuto`。
    func isAutoStrip(_ kind: ParameterStripKind) -> Bool {
        kind == .whiteBalance ? isWhiteBalanceAuto : isISOShutterAuto
    }

    /// 手动开关在**当前设备**上是否真的可用（`false` = 刻度条右端开关置灰）。
    ///
    /// 数据链：`CaptureCapabilities` 能力探测 → session `@Published` → 这里派生。
    /// 右端「自动 / 手动」开关是否可用。
    ///
    /// ⚠️ **2026-09-20 拍板 ①（`docs/20`）：恒 `true` —— B2 的"能力探测置灰"呈现随按需
    /// 架构退役**。虚拟会话下点开关 = **切物理会话（转场）→ 完成后自动进手动档**
    /// （`stripAutoToggled` 入口分派）——按需架构下这是进入手动档的唯一路径，
    /// "置灰 + 点了给原因"会让手动档永远不可达。能力探测仍在 session 写入链上
    /// 兜底（`setManualExposure` 等的 throw + 错误 toast）。
    func isManualStripAvailable(_ kind: ParameterStripKind) -> Bool {
        true
    }

    /// 待重放动作（拍板 ①：虚拟会话点手动开关 / 对焦入口 → 先切物理 → 转场完成后执行）。
    private enum PendingManualAction {
        case toggleManualStrip(ParameterStripKind)
        case openFocusDial
    }

    private var pendingManualAction: PendingManualAction?

    /// 右端「自动 / 手动」开关。
    ///
    /// ⚠️ **ISO 与快门共用一个开关**（原型 `state.auto.isoShutter`）：这是硬件约束 ——
    /// 锁了 ISO 就得接管曝光时长，反之亦然（`setExposureModeCustom` 一次接管两者）。
    /// 白平衡独立（`setWhiteBalanceModeLocked` 与曝光无关）。
    func stripAutoToggled(_ kind: ParameterStripKind) {
        guard let environment else { return }

        // ⚠️ 入口分派（拍板 ①，`docs/20`）：**虚拟会话下点手动开关 = 切物理会话**，
        // 转场完成后自动重放本开关（此时挂的是物理单摄，手动档立即可用）——
        // "置灰 + toast 不开盘"是虚拟设备时代的临时呈现，按需架构下退役。
        // 能力探测仍在 session 写入链兜底（setManualExposure 等的 throw）。
        if environment.session.form == .virtual {
            DebugLog.shared.info(
                "ui",
                "点 \(kind.displayName) 手动开关 → 虚拟会话 → 切物理（完成后自动进手动档）"
            )
            showToast("正在切换到 \(focal.displayName) mm 物理镜头 · 完成后进入手动档")
            pendingManualAction = .toggleManualStrip(kind)
            environment.session.applyFocalTarget(.physical(focal: focal))
            return
        }

        let wasAuto = isAutoStrip(kind)

        if wasAuto {
            // 自动 → 手动：**初值取设备当前值**（拍板 ③）—— 切档瞬间画面不跳，
            // 用户是从"AE/AWB 刚收敛到的那一档"开始往下调的（系统相机就是这个手感）。
            switch kind {
            case .iso, .shutter:
                let pair = currentExposurePair(environment)
                DebugLog.shared.debug(
                    "ui",
                    "切手动曝光档：初值取设备当前值 ISO \(String(format: "%.0f", pair.iso))"
                        + " / \(FormatText.shutterSpeed(pair.seconds))"
                )
                environment.session.setManualExposure(
                    iso: Float(pair.iso),
                    seconds: pair.seconds
                )
            case .whiteBalance:
                let kelvin = environment.session.currentWhiteBalanceKelvin
                DebugLog.shared.debug(
                    "ui",
                    "切手动白平衡档：初值取设备当前值 \(String(format: "%.0f", kelvin))K"
                )
                environment.session.setManualWhiteBalance(kelvin: kelvin)
            }
            showToast("\(kind.displayName) 已切手动（初值取当前画面值）· 左右滑动刻度调节")
        } else {
            switch kind {
            case .iso, .shutter:
                environment.session.setAutoExposure()
                showToast("ISO 与快门已切回自动（两者共用一个开关）")
            case .whiteBalance:
                environment.session.setAutoWhiteBalance()
                showToast("白平衡已切回自动（AWB）")
            }
        }
        Haptics.tick()
        // 草稿作废：档位刚切换，显示要交回新的硬件真值
        isoShutterDraft = nil
        whiteBalanceDraft = nil
    }

    /// 刻度条拖动（**每跨一档一次**）。`isEditing` 在拖动开始/结束由控件上报。
    ///
    /// 自动态下控件本来就不响应（原型 `stripIsAuto` 同款），这里再兜一道：
    /// 自动态收到拖动值直接忽略，避免"自动档被拖出个手动档"这种怪状态。
    func stripValueChanged(_ kind: ParameterStripKind, value: Double, isEditing: Bool) {
        guard let environment else { return }
        guard !isAutoStrip(kind) else {
            DebugLog.shared.debug("ui", "刻度条 \(kind.displayName) 处于自动态，忽略拖动值")
            return
        }

        switch kind {
        case .iso:
            var draft = isoShutterDraft ?? currentExposurePair(environment)
            draft.iso = value
            isoShutterDraft = draft
            environment.session.setManualExposure(
                iso: Float(draft.iso),
                seconds: draft.seconds
            )
        case .shutter:
            var draft = isoShutterDraft ?? currentExposurePair(environment)
            draft.seconds = value
            isoShutterDraft = draft
            environment.session.setManualExposure(
                iso: Float(draft.iso),
                seconds: draft.seconds
            )
        case .whiteBalance:
            whiteBalanceDraft = value
            environment.session.setManualWhiteBalance(kelvin: Float(value))
        }

        if !isEditing {
            // 松手：草稿清掉 → 显示交回**硬件真值**（异步回读一两帧内到，值本来就一致）
            DebugLog.shared.debug(
                "ui",
                "刻度条 \(kind.displayName) 松手吸附到 "
                    + ParameterStripCatalog.label(for: kind, value: value)
            )
            isoShutterDraft = nil
            whiteBalanceDraft = nil
        }
    }

    // MARK: - 模式

    func modeTapped(_ newMode: CaptureSessionMode) {
        dismissTransientPopovers()
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
        dismissTransientPopovers()
        DebugLog.shared.debug("ui", "闪光灯图标点击（硬件未接入）")
        showToast("闪光灯：切换与常亮在 P2 参数批次接入（AVCaptureDevice.torchMode），当前固定关闭")
    }

    /// 顶栏「网格」图标：**真开关**，与设置页共用 `AppEnvironment.showGrid`
    func gridTapped() {
        dismissTransientPopovers()
        guard let environment else { return }
        environment.showGrid.toggle()
        Haptics.tick()
        showToast(environment.showGrid ? "网格线已开" : "网格线已关")
    }

    /// 顶栏副行「影调预览」：真开关，但**当前不改变画面**，必须说明
    func tonePreviewTapped() {
        dismissTransientPopovers()
        guard let environment else { return }
        environment.showTonePreview.toggle()
        Haptics.tick()
        showToast(environment.showTonePreview
            ? "影调预览已开：P4 之后取景器会实时叠上风格与滤镜（现在画面还不会变）"
            : "影调预览已关：成片仍按所选风格与滤镜保存")
    }

    /// 顶栏副行「剩余存储」：真数据（约 10 秒刷新一次）
    func storageTapped() {
        dismissTransientPopovers()
        guard let environment else { return }
        showToast("剩余可用存储 \(environment.session.freeSpaceText)")
    }

    /// 焦段条点档位（**B1：真接硬件**）。
    ///
    /// - **不重建会话**：切镜头是虚拟多摄设备内部的事（越过系统切换点时自动换 constituent），
    ///   只做 `lock → ramp → unlock`，见 `CaptureSessionController.setZoomFactor`。
    /// - **不可用档位**（`unavailableFocalIds`，例如单摄设备上的 13mm）：
    ///   不动硬件，只给 toast 说明 —— UI 已置灰，但**灰着也要能点出原因**（产品约束）。
    func focalTapped(_ preset: FocalPreset) {
        guard let environment else { return }

        // 不可用档位（**虚拟会话**：该机型镜头覆盖不到的档位，UI 置灰；物理会话下为空集，
        // 因为跨镜头档走换设备、设备缺失由 applyFocalTarget 兜底报错）
        if environment.session.unavailableFocalIds.contains(preset.id) {
            Haptics.warning()
            DebugLog.shared.debug("ui", "焦段 \(preset.displayName)mm 在当前设备不可用（已置灰）")
            showToast(
                "焦段 \(preset.displayName)mm 在当前设备上不可用 —— 本机镜头覆盖不到这个视场"
            )
            return
        }

        // 点已选中的档位：原型是静默 return；这里补一次轻触感（"点到了、本来就选中"）
        guard preset.id != focal.id else {
            Haptics.tick()
            return
        }

        // ⚠️ **分派矩阵**（预检 ⑦，`docs/20` 第六节）——按会话形态分派，收敛在此一处：
        switch environment.session.form {
        case .virtual:
            // 虚拟会话：B1 现状 —— 虚拟切换点内 ramp（平滑变焦）
            break
        case .physical(let current):
            if isRecording, current.physicalDeviceTypes != preset.physicalDeviceTypes {
                // 预检 ③：录制中**跨镜头**禁（换 input 断流毁产物）；同镜头数码变焦允许（拍板 ②）
                Haptics.warning()
                DebugLog.shared.warn("ui", "录制中跨镜头切换被拒（\(current.displayName) → \(preset.displayName)）")
                showToast("录制中不能切换镜头 —— 试试同镜头的 35 / 48 mm（数码变焦）")
                return
            }
            if current.physicalDeviceTypes == preset.physicalDeviceTypes {
                // 物理会话**同镜头**：ramp 到该档的裁切系数（比例真读 mainCropFactor，预检 ⑦）
                focal = preset
                Haptics.tick()
                environment.session.applyZoomOnPhysical(to: preset)
                DebugLog.shared.debug(
                    "ui",
                    "物理会话同镜头变焦 → \(preset.displayName) mm（zoom "
                        + String(format: "%.2f", Double(preset.zoomFactorOnPhysicalDevice)) + "×）"
                )
                showToast("焦段 \(preset.displayName) mm · 变焦 "
                    + String(format: "%.2f", Double(preset.zoomFactorOnPhysicalDevice)) + "×")
                return
            }
            // 物理会话**跨镜头**：换设备 + 转场（第三笔接顺序触发；当前直切）
            focal = preset
            Haptics.tick()
            environment.session.applyFocalTarget(.physical(focal: preset))
            return
        }

        focal = preset
        Haptics.tick()

        environment.session.applyFocal(preset) { [weak self] applied, wasClamped in
            guard let self else { return }
            guard let applied else {
                showToast("焦段 \(preset.displayName)mm：档位数据异常，未切换")
                return
            }
            if wasClamped {
                // 理论上到不了这里（超能力的档位已被置灰拦掉）—— 留作防御：
                // 真出现就**照实说**，不假装切到了标称档位
                showToast(String(
                    format: "焦段 %@ mm 超出本机能力，已用 %.2f× 变焦",
                    preset.displayName, Double(applied)
                ))
            } else {
                showToast(String(
                    format: "焦段 %@ mm · 变焦 %.2f×",
                    preset.displayName, Double(applied)
                ))
            }
        }
    }

    /// 当前设备上不可用的焦段档位（UI 置灰用；透传 session 的探测结果）
    var unavailableFocalIds: Set<String> {
        environment?.session.unavailableFocalIds ?? []
    }

    /// 会话就绪后，把硬件 zoom 对齐到**当前焦段档位**（B1）。
    ///
    /// 为什么必须做：配置阶段的变焦只认 `CapturePreset`（预设注入链路），
    /// 而 UI 的真相是"焦段档位"（默认 24mm）。不对齐就会出现
    /// **"画面是 13mm 超广角视场、但选中态写着 24mm"** 这类不一致。
    ///
    /// ⚠️ 用**非动画**：会话刚就绪时不该让用户看到画面推近一下。
    /// ⚠️ 不可用档位不推硬件（保持设备默认视场，UI 那边本来就置灰）。
    private func reapplyFocalAfterSessionReady() {
        guard let environment else { return }
        guard !environment.session.unavailableFocalIds.contains(focal.id) else { return }

        environment.session.applyFocal(focal, animated: false) { [weak self] applied, _ in
            guard let self else { return }
            guard let applied else { return }
            DebugLog.shared.debug(
                "ui",
                "会话就绪 · 焦段 \(focal.displayName)mm 已对齐（变焦 "
                    + String(format: "%.2f", Double(applied)) + "×）"
            )
        }
    }

    // MARK: - 底部图标行

    /// 第 1 项「前置」：前后切换要**重建会话输入**（换 `AVCaptureDeviceInput`），P2 硬件批次
    func frontCameraTapped() {
        showToast("前后镜头切换要重建会话输入，在 P2 硬件批次交付，当前固定后置")
    }

    /// 第 2 项「对焦」：B3b 起走**能力分派**的圆盘入口 `focusDialTapped()`（见对焦圆盘一节）——
    /// 虚拟多摄 = toast 说明不开盘；物理镜头（架构改造后）= 开对焦圆盘。
    /// （原 `focusHintTapped` 的提示 toast 已被 `focusDialTapped` 的 toast 吸收，函数删除。）

    /// 第 3 项「白平衡」：展开 / 收起**白平衡刻度条**（模块 #9，B 组接线）
    func whiteBalanceTapped() {
        stripTapped(.whiteBalance)
    }

    /// 第 4 项「感光」：展开 / 收起 **ISO 刻度条**
    func isoTapped() {
        stripTapped(.iso)
    }

    /// 第 5 项「快门速度」：展开 / 收起**快门刻度条**
    ///
    /// ⚠️ 与「感光」是**同一条自动/手动开关**（ISO 与快门共用一个，硬件约束）——
    /// 两条刻度条可以分别展开，但切换手动的开关是同一个。
    func shutterSpeedTapped() {
        stripTapped(.shutter)
    }

    // MARK: - EV 圆盘（#8 · B3a）

    /// 第 6 项「曝光补偿」：**展开 / 收起 EV 圆盘**（原型 `iconEV` → `layout.evOpen` toggle）。
    ///
    /// ## 互斥（原型 `3551-3557` 逐行同构）
    ///
    /// 展开时收起**其它**扩展浮层（滤镜条 / 场景·风格 / 刻度条）——
    /// ⚠️ **不能调 `dismissTransientPopovers()`**（那会把刚展开的圆盘自己也收掉，
    /// 2026-09-18 的老坑）；这里只手动收"别人"，"点别处收起"归 `dismissTransientPopovers()`。
    ///
    /// ⚠️ **手动曝光档下 EV 不生效**（`docs/16` 第五节 ①）：
    ///   `setExposureTargetBias` 会被系统忽略，而 configurator 里那条"回切自动档"的最后防线
    ///   会把 ISO / 快门 的锁定**静默解除** —— 所以直接拦住并说明原因，
    ///   不做"点了没反应"，更不做"点了把别处锁定的东西悄悄改掉"。
    ///   已展开时允许收起：否则用户切到手动档之后就关不掉这个盘了。
    func evDialTapped() {
        // ⚠️ 手动档拦截（原 exposureCompensationTapped 的 tapGuard 原样迁移）
        if isManualExposureActive && !isEvDialShown {
            Haptics.warning()
            DebugLog.shared.debug("ui", "手动曝光档下点「曝光补偿」→ 已拦下并说明 EV 不生效")
            showToast("手动 ISO / 快门 档下 EV 不生效 —— 先点刻度条右端开关切回自动")
            return
        }

        // 先记住这一下会连带收起谁（toast 只报真发生的事，不虚报）
        let willCollapseOthers = !isEvDialShown
            && (isFilterStripExpanded || isSceneStyleExpanded || paramStrip != nil || isFocusDialShown)
        let collapsedNames = [
            isFilterStripExpanded ? "滤镜条" : nil,
            isSceneStyleExpanded ? "场景·风格条" : nil,
            paramStrip.map { "\($0.displayName) 刻度条" },
            isFocusDialShown ? "对焦圆盘" : nil
        ].compactMap { $0 }

        isEvDialShown.toggle()
        Haptics.tick()

        if isEvDialShown {
            // 展开者只收别人（不调 dismissTransientPopovers —— 见上）
            isFilterStripExpanded = false
            isSceneStyleExpanded = false
            paramStrip = nil
            isFocusDialShown = false
            isoShutterDraft = nil
            whiteBalanceDraft = nil
            DebugLog.shared.debug(
                "ui",
                "EV 圆盘展开（入口：图标行「曝光补偿」）"
                    + (willCollapseOthers ? " · 连带收起 \(collapsedNames.joined(separator: "、"))" : "")
            )
            let suffix = willCollapseOthers
                ? " · \(collapsedNames.joined(separator: "与"))已收起"
                : " · 再点收起"
            showToast("曝光补偿圆盘：拖动圆盘调 ±3 EV，点数值归零\(suffix)")
        } else {
            DebugLog.shared.debug("ui", "EV 圆盘收起（入口：图标行「曝光补偿」）")
            showToast("已收起曝光补偿圆盘")
        }
    }

    /// EV 圆盘拖动（**每跨 0.1 一次**；`isEditing` 在拖动开始/结束由控件上报）。
    ///
    /// ## 编辑态闸门接 `docs/14` 同款 —— 不是另起炉灶
    ///
    /// 圆盘的值流与滑条完全同构：拖动 → 更新 `exposureBias` → 推硬件
    /// （`exposureEditingChanged` 里那两行：记 `lastPushedExposureBias` + `setExposureBias`）；
    /// 硬件回写由 **`attach()` 里既有的两道守卫**挡住（拖动期不回写 + 只接受最后推送值）。
    /// 所以这里只需要：先写值、再把编辑态交给 `exposureEditingChanged`。
    ///
    /// ⚠️ 手动曝光档下 `exposureEditingChanged` 自带拦截（warn 留痕）——圆盘入口
    /// `evDialTapped` 已拦"开盘"，这里是拖动中的第二道（开盘后切到手动档的极端时序）。
    func evDialValueChanged(_ value: Double, isEditing: Bool) {
        if exposureBias != value {
            exposureBias = value
        }
        exposureEditingChanged(isEditing)
    }

    /// EV 圆盘数值框**点击归零**（原型 `#evVal` click：`state.ev = 0` + toast「曝光补偿已归零」）。
    ///
    /// 走 `evDialValueChanged(0, false)`：编辑态先复位再推硬件 —— 松手语义，
    /// "松手后以最终值为准同步一次"的既有顺序自然成立（`docs/14` 第六节）。
    func evDialZeroTapped() {
        guard exposureBias != 0 else {
            showToast("曝光补偿已是 0")
            return
        }
        evDialValueChanged(0, isEditing: false)
        Haptics.tick()
        DebugLog.shared.debug("ui", "EV 圆盘数值框点击归零（入口：数值框）")
        showToast("曝光补偿已归零")
    }

    // MARK: - 对焦圆盘（#8 后半 · B3b）

    /// 第 2 项「对焦」：**展开 / 收起对焦圆盘**——但先过**能力分派**（拍板 ①·A）。
    ///
    /// 虚拟多摄不支持手动对焦（`isLockingFocusWithCustomLensPositionSupported`，Mac 同类
    /// 预警已进守卫）→ **toast 说明、不开盘**（与 B2 手动开关同款诚实边界，B3a 先例）；
    /// 物理镜头架构落地后探测翻 true，本方法自动走开盘分支，UI 零改动。
    ///
    /// 互斥与 EV 圆盘同构：展开时收其它扩展浮层（**展开者只收别人**，不调
    /// `dismissTransientPopovers` —— 会把刚展开的自己收掉，2026-09-18 老坑）。
    func focusDialTapped() {
        guard let environment else { return }

        // ⚠️ 入口分派（拍板 ①，`docs/20`）：**虚拟会话下点「对焦」= 切物理会话**，
        // 转场完成后自动开盘 —— B3b 的"toast 不开盘"呈现（虚拟设备时代的临时口径）
        // 随按需架构退役。物理会话下 isManualFocusSupported = true，正常走开盘。
        if !environment.session.isManualFocusSupported {
            guard environment.session.form == .virtual else {
                // 物理会话仍探测失败 —— 理论不可达（物理单摄支持手动对焦），诚实兜底
                DebugLog.shared.warn(
                    "ui",
                    "物理会话下手动对焦能力探测仍为 false —— 请核对设备，本入口按诚实边界拦截"
                )
                showToast("手动对焦：当前设备不支持 · 点取景器任意位置仍可自动对焦")
                return
            }
            DebugLog.shared.info(
                "ui",
                "点「对焦」→ 虚拟会话 → 切物理（完成后自动打开对焦圆盘）"
            )
            showToast("正在切换到 \(focal.displayName) mm 物理镜头 · 完成后打开对焦圆盘")
            pendingManualAction = .openFocusDial
            environment.session.applyFocalTarget(.physical(focal: focal))
            return
        }

        // 先记住这一下会连带收起谁（toast 只报真发生的事，不虚报）
        let willCollapseOthers = !isFocusDialShown
            && (isFilterStripExpanded || isSceneStyleExpanded || paramStrip != nil || isEvDialShown)
        let collapsedNames = [
            isFilterStripExpanded ? "滤镜条" : nil,
            isSceneStyleExpanded ? "场景·风格条" : nil,
            paramStrip.map { "\($0.displayName) 刻度条" },
            isEvDialShown ? "EV 圆盘" : nil
        ].compactMap { $0 }

        isFocusDialShown.toggle()
        Haptics.tick()

        if isFocusDialShown {
            // 展开者只收别人（含另一颗盘 —— 两盘同位置互斥，原型"开一个关另一个"）
            isFilterStripExpanded = false
            isSceneStyleExpanded = false
            paramStrip = nil
            isEvDialShown = false
            isoShutterDraft = nil
            whiteBalanceDraft = nil
            DebugLog.shared.debug(
                "ui",
                "对焦圆盘展开（入口：图标行「对焦」）"
                    + (willCollapseOthers ? " · 连带收起 \(collapsedNames.joined(separator: "、"))" : "")
            )
            let suffix = willCollapseOthers
                ? " · \(collapsedNames.joined(separator: "与"))已收起"
                : " · 再点收起"
            showToast("手动对焦：拖动圆盘调焦（0.0 近 → ∞ 远）\(suffix)")
        } else {
            DebugLog.shared.debug("ui", "对焦圆盘收起（入口：图标行「对焦」）")
            showToast("已收起对焦圆盘")
        }
    }

    /// 对焦圆盘拖动（**每跨 0.01 一次**；`isEditing` 在拖动开始/结束由控件上报）。
    ///
    /// 编辑态闸门与 EV 同构（`docs/14`）：先写显示值，再走 `focusEditingChanged`
    /// （记 `lastPushedLensPosition` + `setManualFocus`）；硬件回写由 `attach()` 里
    /// 对焦订阅的两道守卫挡住。
    func focusDialValueChanged(_ value: Double, isEditing: Bool) {
        if focusLensPosition != value {
            focusLensPosition = value
        }
        focusEditingChanged(isEditing)
    }

    /// 对焦编辑态闸门（`docs/14` 同构：拖动期不回写 + 只接受最后推送值）。
    ///
    /// ⚠️ **2026-09-20 正源修：删掉原来的 `guard !isFocusAuto` 拦截** ——
    /// 那道拦截和意图态有时序矛盾：**第一次拖动就是"进入手动对焦"的意图表达**
    /// （此刻 `manualFocus` 还是 `nil` = "自动"），按旧逻辑会被自己拦掉，拖动永远
    /// 无效。自动档下盘面本来就被 `DialView` 的 `autoMode` 锁住拖动（到不了这里），
    /// 所以这里只剩闸门本职 + 把意图交给 `setManualFocus`（session 侧置 `manualFocus`）。
    func focusEditingChanged(_ isEditing: Bool) {
        if isFocusEditing != isEditing {
            isFocusEditing = isEditing
        }
        lastPushedLensPosition = Float(focusLensPosition)
        environment?.session.setManualFocus(lensPosition: Float(focusLensPosition))
    }

    /// 对焦盘「自动对焦」开关（原型 `#fdAuto`：开=自动找焦点并锁定拖动；关=停在当前值）。
    /// - 开：`setAutoFocusMode()`（连续自动优先）；读数随 `currentLensPosition` 回写
    ///   实时走（不需要原型的模拟动画 —— 那是"原型没有真硬件"的代偿）。
    /// - 关：把**当前读数**写成锁定值（`setManualFocus`），数值停在原地恢复拖动
    ///   （原型同款："关 → 立刻停住，数值停在当前值"）。
    func focusAutoToggled() {
        guard let environment else { return }
        if isFocusAuto {
            environment.session.setManualFocus(lensPosition: Float(focusLensPosition))
            Haptics.tick()
            DebugLog.shared.debug(
                "ui",
                "自动对焦已关 → 手动（当前值 \(String(format: "%.2f", focusLensPosition)) 锁定）"
            )
            showToast("自动对焦已关：现在可以拖动圆盘手动调焦")
        } else {
            environment.session.setAutoFocusMode()
            Haptics.tick()
            DebugLog.shared.debug("ui", "自动对焦已开 → 连续自动（手动拖动已锁定）")
            showToast("自动对焦已开：正在自动找焦点（手动拖动已锁定）")
        }
    }

    // MARK: - 回切防抖（预检 ① · docs/20 第四节）

    /// 全手动档退出持续 **2s**（`Theme.Size.dialRevertDebounce`）→ 切回虚拟多摄
    /// （恢复 B1 平滑变焦；防抖防"快速试一档手动就打摆"）。录制中顺延。
    private var revertDebounceTask: Task<Void, Never>?

    /// 三个意图态全空（手动曝光 / 手动白平衡 / 手动对焦都没锁）。
    var isAllManualOff: Bool {
        guard let environment else { return true }
        return environment.session.manualExposure == nil
            && environment.session.manualWhiteBalance == nil
            && environment.session.manualFocus == nil
    }

    /// 三意图态合并的观察回调：全空 + 物理会话 + 非录制 → 起 2s 防抖；任一条件破坏 → 取消。
    private func evaluateRevertToVirtual(allAuto: Bool) {
        guard let environment else { return }
        revertDebounceTask?.cancel()
        guard allAuto, environment.session.form.isPhysical, !isRecording else { return }

        let seconds = Double(Theme.Size.dialRevertDebounce)
        revertDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            guard self.isAllManualOff, !self.isRecording else { return }
            DebugLog.shared.info(
                "ui",
                "全手动档退出 \(Int(seconds))s → 切回虚拟多摄（B1 平滑变焦恢复）"
            )
            self.environment?.session.applyFocalTarget(.virtual(focal: self.focal))
        }
    }

    // MARK: - 场景 · 风格（#6）

    /// 展开 / 收起场景·风格条。三个入口（折叠胶囊 / 箭头 / 快门排风格方块）都走它。
    ///
    /// 互斥（原型 `setSS`）：展开时收起滤镜条**与参数排** —— 同一时刻只允许一个扩展浮层。
    ///
    /// ⚠️ **必须给反馈**（2026-09-18 真机教训）：这个函数此前只有 `Haptics.tick()`，
    /// 既不弹提示也不落日志 —— 而它**会改写另外两个浮层的状态**。用户在验收时反复点过
    /// 胶囊 / 方块，每次都在无声收起滤镜条或参数排，于是"上划时撞到的分支"和用户以为的
    /// 不一致，排查时日志里也什么都看不到。**任何改写状态的动作都要留下痕迹。**
    ///
    /// - Parameter source: 入口名，只用于日志对账（"胶囊/箭头" 还是 "风格方块"）
    func toggleSceneStyle(source: String = "胶囊") {
        // 先记住"这一下会不会连带收起别的浮层"，toast 才说得准
        let willCollapseOthers = !isSceneStyleExpanded
            && (isFilterStripExpanded || isEvDialShown || isFocusDialShown || paramStrip != nil)
        let collapsedNames = [
            isFilterStripExpanded ? "滤镜条" : nil,
            isEvDialShown ? "EV 圆盘" : nil,
            isFocusDialShown ? "对焦圆盘" : nil,
            paramStrip.map { "\($0.displayName) 刻度条" }
        ].compactMap { $0 }

        isSceneStyleExpanded.toggle()
        if isSceneStyleExpanded {
            isFilterStripExpanded = false
            isEvDialShown = false
            isFocusDialShown = false
            paramStrip = nil
            isoShutterDraft = nil
            whiteBalanceDraft = nil
        }
        Haptics.tick()

        let state = isSceneStyleExpanded ? "展开" : "收起"
        DebugLog.shared.debug(
            "ui",
            "场景·风格条\(state)（入口：\(source)）"
                + (willCollapseOthers ? " · 连带收起 \(collapsedNames.joined(separator: "、"))" : "")
        )

        if isSceneStyleExpanded {
            let suffix = willCollapseOthers
                ? " · \(collapsedNames.joined(separator: "与"))已收起"
                : " · 再点收起"
            showToast("场景·风格已展开（\(scene.displayName) · \(style.displayName)）\(suffix)")
        } else {
            showToast("场景·风格已收起")
        }
    }

    /// 选场景 = 连带把**推荐的风格或滤镜**一起选上（数据层保证两者不会同时有值）。
    ///
    /// ⚠️ **本件不推硬件**：建议的白平衡与 EV 只在提示条里给出来
    /// —— EV / 白平衡落地属 B 组接线（用户 2026-09-17 拍板：守 A 组边界）。
    func sceneTapped(_ preset: ScenePreset) {
        sceneId = preset.id
        if let recommendedStyle = preset.styleId {
            styleId = recommendedStyle
        }
        filterId = preset.filterId
        Haptics.tick()
        let ev = FormatText.exposureBias(Float(preset.exposureBias))
        showToast(
            "场景 \(preset.displayName)：白平衡建议 \(Int(preset.whiteBalanceKelvin))K · EV \(ev)"
        )
    }

    /// 选风格 = 一键成片：**把滤镜重置为「无」**（原型注释：否则两层胶片叠加会出脏色）。
    func styleTapped(_ preset: StylePreset) {
        guard preset.id != styleId else { return }
        styleId = preset.id
        filterId = nil
        Haptics.tick()
        showToast("风格：\(preset.displayName)（滤镜已重置为「无」，可再单独选滤镜叠加）")
    }

    // MARK: - 滤镜条（#7）

    /// 选滤镜 / 取消滤镜（原型 `buildFilters` 的 click 逻辑）。
    ///
    /// **再点已选中的 = 取消回到原片**（`filterId = nil`）。
    /// ⚠️ **选滤镜不清风格** —— 与"选风格重置滤镜"是**单向**的（原型同款）。
    /// ⚠️ 滤镜对画面的实际作用在 P4：这里只切选择状态，由「影调预览」同款的
    /// 边界讲法说明，不假装画面已经变化。
    func filterTapped(_ preset: FilterDefinition) {
        if filterId == preset.id {
            filterId = nil
            Haptics.tick()
            showToast("已取消滤镜，回到原片")
        } else {
            filterId = preset.id
            Haptics.tick()
            showToast("滤镜：\(preset.displayName) · 默认强度 \(Self.intensityText(preset.intensity))")
        }
    }

    /// 强度文本：0.75 → "0.75"、1 → "1"（对齐 `ColorGrade.num` 的写法，避免 "1.00"）
    private static func intensityText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// 取景器上划 / 下划手势的分层决策（原型 `swipeUp` / `swipeDown`）。
    ///
    /// 上划第一段呼出**滤镜条**、第二段呼出**场景与风格**（两级，互斥收起对方与参数排）；
    /// 下划逐级收起。手势的几何判定在 `CameraView.viewfinderSwipeGesture`，这里只管"呼出什么"。
    ///
    /// （Swift 侧暂无简易模式 —— 原型里"简易模式下浮层保持隐藏"的分支随模块 #12 补。）
    func swiped(up: Bool) {
        // 上划/下划前先收功能面板（原型全局 pointerdown 会先把它收掉，再执行手势）
        dismissTransientPopovers()
        if up {
            if !isFilterStripExpanded && !isSceneStyleExpanded {
                // 互斥（原型 setFilter(true)）：呼出滤镜条时收起场景·风格、两颗圆盘与刻度条
                // 连带收起时在提示里说明（同一类"状态被改写要留痕"，2026-09-18）
                let dialNote = (isEvDialShown || isFocusDialShown) ? "（圆盘已收起）" : ""
                let stripNote = paramStrip.map { "（\($0.displayName) 刻度条已收起）" } ?? ""
                isFilterStripExpanded = true
                isSceneStyleExpanded = false
                isEvDialShown = false
                isFocusDialShown = false
                paramStrip = nil
                isoShutterDraft = nil
                whiteBalanceDraft = nil
                Haptics.tick()
                showToast("已呼出滤镜条 · 再上划一次呼出场景与风格\(dialNote)\(stripNote)")
            } else if isFilterStripExpanded && !isSceneStyleExpanded {
                // 互斥（原型 setSS(true)）：呼出场景·风格时收起滤镜条、两颗圆盘与刻度条
                let dialNote = (isEvDialShown || isFocusDialShown) ? "（圆盘已收起）" : ""
                let stripNote = paramStrip.map { "（\($0.displayName) 刻度条已收起）" } ?? ""
                isFilterStripExpanded = false
                isSceneStyleExpanded = true
                isEvDialShown = false
                isFocusDialShown = false
                paramStrip = nil
                isoShutterDraft = nil
                whiteBalanceDraft = nil
                Haptics.tick()
                showToast("已呼出场景与风格 · 下划收起\(dialNote)\(stripNote)")
            } else {
                showToast("浮层已全部展开 · 下划收起")
            }
        } else {
            if isSceneStyleExpanded {
                collapseOverlays()
                showToast("已收起场景与风格")
            } else if isFilterStripExpanded {
                collapseOverlays()
                showToast("已收起滤镜条")
            } else if isEvDialShown || isFocusDialShown || paramStrip != nil {
                collapseOverlays()
                showToast("已收起 EV 圆盘 / 对焦圆盘 / 刻度条")
            } else {
                showToast("没有更多可收起的浮层")
            }
        }
    }

    /// 收起**全部**扩展浮层（原型 `collapseAll`）：场景·风格 / 滤镜条 / **EV 圆盘** /
    /// **对焦圆盘** / 参数刻度条。
    ///
    /// ✅ 与原型 `collapseAll` 一致（场景·风格 / 滤镜条 / 刻度条区 / 两颗圆盘）。
    /// ⚠️ 功能面板（#10）**不在这里**：它是模态浮层，不是"扩展浮层"（原型 `collapseAll` 也不碰
    /// `fnOpen`）；它是**反向**关系 —— 开面板时收起这些（见 `toggleFunctionPanel()`）。
    private func collapseOverlays() {
        guard isFilterStripExpanded || isSceneStyleExpanded
            || isEvDialShown || isFocusDialShown || paramStrip != nil else {
            return
        }
        isFilterStripExpanded = false
        isSceneStyleExpanded = false
        isEvDialShown = false
        isFocusDialShown = false
        paramStrip = nil
        // 收起刻度条时草稿一并作废（否则下次展开会先闪一下旧草稿值）
        isoShutterDraft = nil
        whiteBalanceDraft = nil
        Haptics.tick()
    }

    // MARK: - 功能面板（#10）

    /// ⠿ 切换功能面板。
    ///
    /// 开面板时收起其余扩展浮层（原型 `if (fnOpen && (ssExpanded || filterExpanded)) collapseAll()`）。
    func toggleFunctionPanel() {
        isFunctionPanelExpanded.toggle()
        Haptics.tick()
        DebugLog.shared.debug("ui", "功能面板\(isFunctionPanelExpanded ? "打开" : "收起")")

        if isFunctionPanelExpanded {
            collapseOverlays()
            dismissFormatSelectorIfNeeded()   // 与格式选择器互斥（原型 btnMore 那侧也关 fmtOpen）
            showToast("功能面板已打开 · 点面板外任意处收起")
        } else {
            showToast("功能面板已收起")
        }
    }

    /// 点面板外收起（原型是全局 `pointerdown` 监听：取景器 / 快门 / 模式条 / 顶栏图标都会收）。
    ///
    /// ⚠️ **Swift 侧是逐点接线**（在几个入口方法里各调一次），不是真的全局监听 ——
    /// 以后新增顶栏 / 取景器上的控件时，要记得也在它的 action 里调一次这个。
    /// （底栏控件被面板盖住、点不到，不需要处理。）
    func dismissFunctionPanelIfNeeded() {
        guard isFunctionPanelExpanded else { return }
        isFunctionPanelExpanded = false
    }

    /// 点任意"别处"时收起**所有临时弹层**（功能面板 + 格式选择器 + 参数刻度条）。
    ///
    /// 为什么合并成一个入口：原型是一个**全局 `pointerdown` 监听**同时处理
    /// `fnOpen` / `fmtOpen` / `evOpen` / `paramStrip`；Swift 侧没有全局监听，只能逐个控件接线 ——
    /// 那就必须**只有一个调用点名字**，否则"新增一个弹层忘了在某处收"会反复发生。
    /// ⚠️ 以后再加临时弹层（#8 的 EV 圆盘），**加进这里**，调用点不用动。
    ///
    /// ⚠️ **展开者自己不要调这个函数**（`stripTapped` / `formatChipTapped` 都是）——
    /// 它会把你刚展开的那个也收掉，表现为"永远打不开"或"再点同一条收不掉"。
    func dismissTransientPopovers() {
        dismissFunctionPanelIfNeeded()
        dismissFormatSelectorIfNeeded()
        dismissParamStripIfNeeded()
        dismissEvDialIfNeeded()
        dismissFocusDialIfNeeded()
    }

    /// 点别处收起 **EV 圆盘**（原型全局 pointerdown 3037：排除 `evWrap` / `iconEV`，
    /// 其余任意点都关）—— 与 #10 / #11 同款"逐点接线"。
    ///
    /// ⚠️ **展开者（`evDialTapped`）不能调本函数**（会把刚展开的自己收掉，老坑）。
    func dismissEvDialIfNeeded() {
        guard isEvDialShown else { return }
        DebugLog.shared.debug("ui", "EV 圆盘收起（点别处）")
        isEvDialShown = false
    }

    /// 点别处收起**对焦圆盘**（原型全局 pointerdown 3488：排除 `focusDial` / `btnFocusHint`）
    /// —— 与 EV 盘同款"逐点接线"。
    ///
    /// ⚠️ **展开者（`focusDialTapped`）不能调本函数**（老坑同上）。
    func dismissFocusDialIfNeeded() {
        guard isFocusDialShown else { return }
        DebugLog.shared.debug("ui", "对焦圆盘收起（点别处）")
        isFocusDialShown = false
    }

    /// 点别处收起**参数刻度条**（与 #10 / #11 同款"逐点接线"）
    ///
    /// 这也是 Backlog ④（浮层互斥缺"收起刻度条"那一半）的落地 ——
    /// 另一半（`collapseOverlays()`）同样已补上。
    func dismissParamStripIfNeeded() {
        guard paramStrip != nil else { return }
        DebugLog.shared.debug("ui", "刻度条收起（点别处）")
        paramStrip = nil
        isoShutterDraft = nil
        whiteBalanceDraft = nil
    }

    /// 面板第 1 格「实况」：照片模式下是否采集 Live Photo（只记状态 + 角标，接线属 B 组）
    func fnLiveTapped() {
        isFnLiveOn.toggle()
        Haptics.tick()
        showToast(isFnLiveOn
            ? "实况已开（照片模式下角标已亮）· 真正让照片模式采集 Live 的接线属 B 组"
            : "实况已关")
    }

    /// 面板第 2 格「画幅比」：循环 4:3 → 16:9 → 1:1，**取景器遮幅真生效**
    /// （实拍裁切属 B 组，与原型口径一致："遮幅示意，实拍裁切在 P2"）
    func fnRatioTapped() {
        fnRatio = fnRatio.next
        Haptics.tick()
        showToast("画幅比 \(fnRatio.displayName)：遮幅已生效 · 实拍裁切在 P2 落地")
    }

    /// 面板第 3 格「闪光灯」：只记状态（`AVCaptureDevice.torchMode` 属 B 组）
    func fnFlashTapped() {
        isFnFlashOn.toggle()
        Haptics.tick()
        showToast(isFnFlashOn
            ? "闪光灯已开：真机走 AVCaptureDevice.torchMode（P2 交付）"
            : "闪光灯已关")
    }

    /// 面板第 4 格「倒计时」：循环 关 → 3s → 10s，只记状态（真机实现属 B 组）
    func fnTimerTapped() {
        fnTimer = fnTimer.next
        Haptics.tick()
        showToast(fnTimer.isOn ? "倒计时 \(fnTimer.displayName)（真机在 P2 生效）" : "倒计时已关")
    }

    /// 面板第 5 格「高亮增益 HDR」：只记状态
    func fnHDROnTapped() {
        isFnHDROn.toggle()
        Haptics.tick()
        showToast(isFnHDROn ? "高亮增益已开：真机在 P2 生效" : "高亮增益已关")
    }

    /// 面板第 6 格「设置」：真开设置页，并**先收起面板**（原型同一个行为）
    func fnSettingsTapped() {
        guard let environment else { return }
        isFunctionPanelExpanded = false
        DebugLog.shared.debug("ui", "功能面板 → 设置页")
        environment.showSettings = true
    }

    /// 面板第 7 格「HUD」：真开关（与设置页那一项、`DebugHUDView` 共用 `env.showDebugHUD`）
    func fnHudTapped() {
        guard let environment else { return }
        environment.showDebugHUD.toggle()
        Haptics.tick()
        showToast(environment.showDebugHUD ? "调试浮层已开" : "调试浮层已关")
    }

    // MARK: - 视频格式（#11）

    /// 点芯片：展开 / 收起格式选择器。与功能面板（#10）**互斥**。
    ///
    /// ⚠️ A/B 组边界：本件只"记住选择"，**不动 `activeFormat`** ——
    /// 真正重设采集格式（`CaptureDeviceConfigurator.applyFormat`）属 B 组。
    /// 底注与 toast 都把这条讲清楚，不做"选了却装作已生效"。
    func formatChipTapped() {
        isFormatSelectorExpanded.toggle()
        Haptics.tick()
        DebugLog.shared.debug("ui", "格式选择器\(isFormatSelectorExpanded ? "展开" : "收起")")

        if isFormatSelectorExpanded {
            // ⚠️ 这里只能收**功能面板**，不能用 `dismissTransientPopovers()` ——
            // 那个会把"刚展开的选择器"自己也收掉（选择器就永远打不开）。
            // 点别处的统一入口是给**外部**控件用的，展开者自己除外。
            dismissFunctionPanelIfNeeded()
            showToast("\(formatChipText) · 选完只记设置，重设采集格式属 B 组")
        }
    }

    /// 点别处收起选择器（与 #10 同款逐点接线：取景器 / 快门 / 模式条 / 顶栏图标 / 上划）
    func dismissFormatSelectorIfNeeded() {
        guard isFormatSelectorExpanded else { return }
        isFormatSelectorExpanded = false
    }

    /// 选分辨率
    func formatResolutionTapped(_ resolution: VideoResolution) {
        guard resolution != videoResolution else { return }
        videoResolution = resolution
        Haptics.tick()
        showToast("分辨率 \(resolution.displayName) · 重设采集格式属 B 组")
    }

    /// 选帧率
    func formatFrameRateTapped(_ frameRate: VideoFrameRate) {
        guard frameRate != videoFrameRate else { return }
        videoFrameRate = frameRate
        Haptics.tick()
        showToast("帧率 \(frameRate.displayName) · 重设采集格式属 B 组")
    }

    /// 面板 foot「简易模式」：Swift 侧还没有简易模式（模块 #12）
    /// → 置灰外观 + 说明原因，不做"点了没反应"
    func fnSimpleModeTapped() {
        DebugLog.shared.debug("ui", "简易模式入口点击（模块 #12 未交付）")
        showToast("简易模式将在模块 #12 交付 —— 现在点它不会改变界面")
    }

    // MARK: - 快门排

    /// ⤢ 放大拍摄布局（2-5b）：切换放大态。
    ///
    /// 放大态本体（取景器卡片化 / 焦段条浮入 / 快门放大 / 镜像按钮）由
    /// `CameraView` 与 `ShutterRowView` 按 `isZoomOn` 渲染，这里只管状态。
    func zoomTapped() {
        isZoomOn.toggle()
        Haptics.tick()
        DebugLog.shared.debug("ui", "放大拍摄布局 \(isZoomOn ? "开" : "关")")
    }

    /// 风格预览方块：点击 = 展开 / 收起「场景·风格」条（与折叠胶囊、箭头同一行为）。
    ///
    /// 内层预览与风格卡同源（`StyleThumbnailView`），不再是 2-5a 那个深色占位 ——
    /// `docs/09` 第六节的未决项随 #6 一起落地了。
    func styleThumbTapped() {
        toggleSceneStyle(source: "风格方块")
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
        // ⚠️ toast 必须落日志：本项目日志双写（OSLog + 沙盒文件）就是为了留**验收证据链**，
        // 而 toast 是行为验收的核心载体 —— "六个 toast 是否都出"这类验收要靠它对账。
        // 不落日志，证据链就断在最后一环（2026-09-17 2-4 验收时实际发生过：只能人工点验）。
        DebugLog.shared.debug("ui", "toast: \(message)")
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
