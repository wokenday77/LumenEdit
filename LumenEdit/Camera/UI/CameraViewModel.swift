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

    /// 参数排（曝光补偿面板）的展开态。
    ///
    /// **默认收起** —— 原型的常态就是"图标行 44pt"（`.row-params{height:44px}`），
    /// 展开是点图标行「曝光补偿」之后的事（`.screen.strip-on .row-params{height:140px}`）。
    ///
    /// ⚠️ Swift 侧此前把 `ExposurePanel` 常驻渲染，这是个真问题（2026-09-18 真机反馈）：
    ///   1. **没有收起入口**：图标行「曝光补偿」只弹 toast（"在上方参数排调节"），
    ///      用户找不到关闭方式；
    ///   2. **常态净可见被压到 50% 以下**（面板约 108pt，底栏栈 334pt → 取景器净可见约 43%）；
    ///   3. **吃掉上滑手势的起手区**：它把"取景器可见区下沿"往上推了约 124pt，
    ///      而 #7 的手势起点线是 55%，两者之间只剩几 pt —— 表现为"上滑要很用力 + 特定位置"。
    @Published private(set) var isExposurePanelExpanded = false

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
        dismissFunctionPanelIfNeeded()
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
        dismissFunctionPanelIfNeeded()
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
        dismissFunctionPanelIfNeeded()
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
        dismissFunctionPanelIfNeeded()
        DebugLog.shared.debug("ui", "闪光灯图标点击（硬件未接入）")
        showToast("闪光灯：切换与常亮在 P2 参数批次接入（AVCaptureDevice.torchMode），当前固定关闭")
    }

    /// 顶栏「网格」图标：**真开关**，与设置页共用 `AppEnvironment.showGrid`
    func gridTapped() {
        dismissFunctionPanelIfNeeded()
        guard let environment else { return }
        environment.showGrid.toggle()
        Haptics.tick()
        showToast(environment.showGrid ? "网格线已开" : "网格线已关")
    }

    /// 顶栏副行「影调预览」：真开关，但**当前不改变画面**，必须说明
    func tonePreviewTapped() {
        dismissFunctionPanelIfNeeded()
        guard let environment else { return }
        environment.showTonePreview.toggle()
        Haptics.tick()
        showToast(environment.showTonePreview
            ? "影调预览已开：P4 之后取景器会实时叠上风格与滤镜（现在画面还不会变）"
            : "影调预览已关：成片仍按所选风格与滤镜保存")
    }

    /// 顶栏副行「剩余存储」：真数据（约 10 秒刷新一次）
    func storageTapped() {
        dismissFunctionPanelIfNeeded()
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

    // MARK: - 底部图标行

    /// 第 1 项「前置」：前后切换要**重建会话输入**（换 `AVCaptureDeviceInput`），P2 硬件批次
    func frontCameraTapped() {
        showToast("前后镜头切换要重建会话输入，在 P2 硬件批次交付，当前固定后置")
    }

    /// 第 2 项「对焦」：**对焦本身已可用**（点取景器任意位置），手动对焦圆盘是模块 #8。
    /// 原型里这个图标开的是圆盘（title 写成提示语是它的历史遗留），这里把两件事都说清。
    func focusHintTapped() {
        showToast("对焦：点按取景器任意位置即可 · 手动对焦圆盘在模块 #8 交付")
    }

    /// 第 3 项「白平衡」：刻度条是模块 #9（参数排展开态，一次一条）
    func whiteBalanceTapped() {
        showToast("白平衡刻度条在 P2 参数批次交付（走 setWhiteBalanceModeLocked）")
    }

    /// 第 4 项「感光」
    func isoTapped() {
        showToast("感光度 ISO 刻度条在 P2 参数批次交付（走 setExposureModeCustom）")
    }

    /// 第 5 项「快门速度」
    func shutterSpeedTapped() {
        showToast("快门速度刻度条在 P2 参数批次交付（同一套 setExposureModeCustom）")
    }

    /// 第 6 项「曝光补偿」：**展开 / 收起参数排**（EV 滑块就在它里面）。
    ///
    /// 原型的做法（第二轮定稿）：参数排常态只剩图标行，**只有点「曝光补偿」才展开滑块区**，
    /// 再点一次收起。Swift 侧此前是"面板常驻 + 这一项只弹 toast"，所以用户**找不到收起入口**
    /// （2026-09-18 真机反馈"曝光补偿条无法关闭"）。现在这一项就是那个开关。
    ///
    /// 互斥：展开参数排时收起滤镜条 / 场景·风格条（同一时刻只允许一个扩展浮层）。
    /// ⚠️ **连带收起必须在提示里说清**（2026-09-18 真机教训）：此前这里是静默改写
    /// 两个浮层的状态，用户与日志都看不见 → "上划为什么走到那个分支"无法对账。
    func exposureCompensationTapped() {
        // 先记住这一下会连带收起谁（toast 只报真发生的事，不虚报）
        let willCollapseOthers = !isExposurePanelExpanded && (isFilterStripExpanded || isSceneStyleExpanded)
        let collapsedNames = [
            isFilterStripExpanded ? "滤镜条" : nil,
            isSceneStyleExpanded ? "场景·风格条" : nil
        ].compactMap { $0 }

        isExposurePanelExpanded.toggle()
        Haptics.tick()

        DebugLog.shared.debug(
            "ui",
            "参数排\(isExposurePanelExpanded ? "展开" : "收起")（入口：图标行「曝光补偿」）"
                + (willCollapseOthers && isExposurePanelExpanded
                    ? " · 连带收起 \(collapsedNames.joined(separator: "、"))" : "")
        )

        if isExposurePanelExpanded {
            isFilterStripExpanded = false
            isSceneStyleExpanded = false
            let value = FormatText.exposureBias(Float(exposureBias))
            let suffix = willCollapseOthers
                ? " · \(collapsedNames.joined(separator: "与"))已收起"
                : " · 再点收起参数排"
            showToast("曝光补偿 \(value) EV\(suffix)")
        } else {
            showToast("参数排已收起（点「曝光补偿」可再次展开）")
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
        let willCollapseOthers = !isSceneStyleExpanded && (isFilterStripExpanded || isExposurePanelExpanded)
        let collapsedNames = [
            isFilterStripExpanded ? "滤镜条" : nil,
            isExposurePanelExpanded ? "参数排" : nil
        ].compactMap { $0 }

        isSceneStyleExpanded.toggle()
        if isSceneStyleExpanded {
            isFilterStripExpanded = false
            isExposurePanelExpanded = false
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
        dismissFunctionPanelIfNeeded()
        if up {
            if !isFilterStripExpanded && !isSceneStyleExpanded {
                // 互斥（原型 setFilter(true)）：呼出滤镜条时收起场景·风格与参数排
                // 连带收起参数排时在提示里说明（同一类"状态被改写要留痕"，2026-09-18）
                let panelNote = isExposurePanelExpanded ? "（参数排已收起）" : ""
                isFilterStripExpanded = true
                isSceneStyleExpanded = false
                isExposurePanelExpanded = false
                Haptics.tick()
                showToast("已呼出滤镜条 · 再上划一次呼出场景与风格\(panelNote)")
            } else if isFilterStripExpanded && !isSceneStyleExpanded {
                // 互斥（原型 setSS(true)）：呼出场景·风格时收起滤镜条与参数排
                let panelNote = isExposurePanelExpanded ? "（参数排已收起）" : ""
                isFilterStripExpanded = false
                isSceneStyleExpanded = true
                isExposurePanelExpanded = false
                Haptics.tick()
                showToast("已呼出场景与风格 · 下划收起\(panelNote)")
            } else {
                showToast("浮层已全部展开 · 下划收起")
            }
        } else {
            if isSceneStyleExpanded {
                collapseOverlays()
                showToast("已收起场景与风格，参数排回到平铺")
            } else if isFilterStripExpanded {
                collapseOverlays()
                showToast("已收起滤镜条，参数排回到平铺")
            } else if isExposurePanelExpanded {
                collapseOverlays()
                showToast("已收起参数排")
            } else {
                showToast("没有更多可收起的浮层")
            }
        }
    }

    /// 收起**全部**扩展浮层（原型 `collapseAll`）：场景·风格 / 滤镜条 / 参数排 / EV 圆盘。
    ///
    /// ⚠️ **新浮层必须加进这里**（#8 的 EV 圆盘、#9 的参数刻度条落地时补）——
    /// 少加一处就会出现"下划收不干净"。
    /// ⚠️ 功能面板（#10）**不在这里**：它是模态浮层，不是"扩展浮层"（原型 `collapseAll` 也不碰
    /// `fnOpen`）；它是**反向**关系 —— 开面板时收起这些（见 `toggleFunctionPanel()`）。
    private func collapseOverlays() {
        guard isFilterStripExpanded || isSceneStyleExpanded || isExposurePanelExpanded else {
            return
        }
        isFilterStripExpanded = false
        isSceneStyleExpanded = false
        isExposurePanelExpanded = false
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
