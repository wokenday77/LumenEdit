import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 错误

enum CaptureConfigurationError: LocalizedError {
    case formatNotBelongToDevice
    case lockFailed
    case partialManualExposure
    case partialManualWhiteBalance
    case unsupportedManualExposure
    case unsupportedWhiteBalance
    case unsupportedFocus

    var errorDescription: String? {
        switch self {
        case .formatNotBelongToDevice:
            return "选中的格式不属于当前设备"
        case .lockFailed:
            return "无法锁定设备配置（可能正被其它模块占用）"
        case .partialManualExposure:
            return "手动曝光参数不完整：ISO 与快门必须同时设置"
        case .partialManualWhiteBalance:
            return "手动白平衡参数不完整：色温与色调必须同时设置"
        case .unsupportedManualExposure:
            return "当前设备或采集格式不支持手动曝光（自定义 ISO / 快门）"
        case .unsupportedWhiteBalance:
            return "当前设备不支持手动白平衡（虚拟多摄不支持锁定增益，需物理镜头）"
        case .unsupportedFocus:
            return "当前设备不支持手动对焦（虚拟多摄不支持自定义镜头位置）"
        }
    }
}

// MARK: - 设备状态快照

/// 供调试浮层展示的设备实时状态（全部已转成可读字符串）
struct CaptureDeviceState {
    var deviceName: String = "—"
    var formatText: String = "—"
    var frameRateText: String = "—"
    var exposureText: String = "—"
    var focusText: String = "—"
    var whiteBalanceText: String = "—"
}

// MARK: - 参数能力（数值，供 UI 画刻度）

/// 相机可调参数的**数值范围与当前值**。
///
/// 与上面的 `CaptureDeviceState` 分工不同：
///   - `CaptureDeviceState` → 全是**可读字符串**，给调试浮层看；
///   - 本类型 → 全是**数值**，给参数控件（对焦圆盘 / 白平衡横尺…）算刻度与指针位置用。
struct CameraParameterCapabilities {

    /// 单个可调参数的区间与当前值
    struct Span {
        var min: Double
        var max: Double
        var current: Double

        /// 值 → 归一化 0~1（UI 用它摆指针）
        func normalized(_ value: Double) -> Double {
            guard max > min else { return 0 }
            return ((value - min) / (max - min)).clamped(to: 0...1)
        }

        /// 归一化 0~1 → 值（UI 拖动结束后用它写回硬件）
        func denormalized(_ t: Double) -> Double {
            min + (max - min) * t.clamped(to: 0...1)
        }
    }

    var iso: Span?
    var exposureSeconds: Span?
    var lensPosition: Span?
    var zoom: Span?
    var whiteBalanceTemperature: Span?
}

// MARK: - 配置器

/// **全工程唯一允许调用 `lockForConfiguration()` 的地方。**
///
/// 这条纪律很重要，原因有两个：
///   1. `AVCaptureDevice` 的多数参数在未 lock 的情况下写入会**直接抛异常**（不是返回失败）；
///   2. ISO、曝光时长、白平衡增益、曝光补偿都有各自的合法范围，越界同样会抛异常。
///      把"取值 → 钳制 → 写入"收敛到一个地方，就不会出现某个页面漏了钳制导致整机崩溃。
///
/// 所有可能的错误都已在此转成 `CaptureConfigurationError`，上层不必再处理 AVFoundation 的异常语义。
final class CaptureDeviceConfigurator {

    // MARK: - 格式与帧率

    /// 应用采集格式与帧率。
    ///
    /// **调用时机有硬要求**：必须在 input 已经加入 session 之后调用。
    /// 原因：`AVCaptureSession` 的 preset 一旦被设置或隐式重置，会话会按 preset 重新挑选格式，
    /// 把这里写入的 `activeFormat` 冲掉。所以会话侧必须先用
    /// `sessionPreset = .inputPriority`，再 addInput，最后才走到这里。
    func applyFormat(
        _ format: AVCaptureDevice.Format,
        frameRate: Double,
        to device: AVCaptureDevice
    ) throws {
        guard device.formats.contains(where: { $0 === format }) else {
            throw CaptureConfigurationError.formatNotBelongToDevice
        }

        // 帧率必须落在该格式支持的范围里，否则设置帧率会失败甚至抛异常
        let range = CaptureCapabilities.frameRateRange(of: format)
        let safeFrameRate = frameRate.sanitized(or: range.lowerBound).clamped(to: range)

        try withLock(device) {
            device.activeFormat = format
            let timescale = CMTimeScale(max(1, safeFrameRate.rounded()))
            let duration = CMTime(value: 1, timescale: timescale)
            // min 与 max 设成同一个值 = 把帧率钉死在这个数上
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }

        DebugLog.shared.info(
            "device",
            "格式已应用 \(device.localizedName) \(CaptureCapabilities.formatSummary(format)) "
            + "fps=\(String(format: "%.0f", safeFrameRate))"
        )
    }

    // MARK: - 预设

    /// 把一份 `CapturePreset` 应用到设备上。P1a 实际只用到曝光补偿这一条。
    func apply(preset: CapturePreset, to device: AVCaptureDevice) throws {
        if preset.hasPartialManualExposure {
            throw CaptureConfigurationError.partialManualExposure
        }
        if preset.hasPartialManualWhiteBalance {
            throw CaptureConfigurationError.partialManualWhiteBalance
        }

        try withLock(device) {
            applyExposureLocked(preset, to: device)
            try applyWhiteBalanceLocked(preset, to: device)
            applyZoomLocked(preset, to: device)
        }

        DebugLog.shared.info("device", "预设已应用：\(preset.summary)")
    }

    /// 只改曝光补偿（拖动 EV 滑块时高频调用，所以单独开一个轻量入口）
    func applyExposureBias(_ bias: Float, to device: AVCaptureDevice) throws {
        let range = device.minExposureTargetBias...device.maxExposureTargetBias
        let safeBias = bias.sanitized(or: 0).clamped(to: range)

        // 处于手动曝光档时 EV 补偿不生效，这里顺手切回自动档。
        //
        // 初衷是"避免拖了滑块但画面没反应"，但 **B2 之后它的含义变了**：
        // 手动锁了 ISO / 快门之后，用户碰一下 EV 就会把**锁定静默解除**。
        // 所以两道处理（`docs/16` 第五节 ①）：
        //   1. **UI 侧必须拦住** —— 手动曝光档下 EV 面板禁用 + 说明（`CameraViewModel`）；
        //   2. 这里保留回切作为**最后防线**，但**必须留痕**：真被触发就说明 UI 那道闸门漏了，
        //      日志里要看得见 —— 否则又是一次"静默改掉别处的设置"（比"点了没反应"更糟）。
        var switchedBackFromManual = false
        try withLock(device) {
            if device.exposureMode == .custom,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                switchedBackFromManual = true
            }
            device.setExposureTargetBias(safeBias, completionHandler: nil)
        }
        if switchedBackFromManual {
            DebugLog.shared.warn(
                "device",
                "推 EV 时设备处于手动曝光档 → 已回切自动档（UI 闸门本应拦住这种情况，"
                    + "出现这条说明拦漏了）"
            )
        }
    }

    // MARK: - 点按对焦 / 测光

    /// 把对焦点与测光点同时设到同一个位置。
    ///
    /// 参数是**设备归一化坐标**（0~1，原点在左上），由预览层
    /// `captureDevicePointConverted(fromLayerPoint:)` 转换而来——不要在 SwiftUI 层自己算，
    /// 坐标系换算错一两像素的现象在真机上非常难查。
    ///
    /// 不支持 POI 的设备（部分前置摄像头、外接设备）不抛错，只记一条警告——
    /// 因为"点按对焦无效"不应该让整个拍摄流程中断。
    func setFocusAndExposurePoint(_ point: CGPoint, on device: AVCaptureDevice) throws {
        let target = CGPoint(
            x: point.x.sanitized(or: 0.5).clamped(to: 0...1),
            y: point.y.sanitized(or: 0.5).clamped(to: 0...1)
        )

        try withLock(device) {
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = target
                device.focusMode = .autoFocus
            } else {
                DebugLog.shared.warn("device", "设备不支持对焦点，忽略点按对焦：\(device.localizedName)")
            }

            if device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = target
                device.exposureMode = .continuousAutoExposure
            }
        }

        DebugLog.shared.debug("device", "对焦点 → (\(String(format: "%.2f", target.x)), \(String(format: "%.2f", target.y)))")
    }

    // MARK: - 手动对焦（P2 · 对焦圆盘驱动它）

    /// 手动对焦。`lensPosition` 归一化 0 ~ 1（0 最近、1 无穷远）。
    ///
    /// 与 `setFocusAndExposurePoint` 的分工：
    ///   - 那个是「点一下画面某处，让系统自动对到那儿」——一次性、自动档；
    ///   - 这个是「把焦点锁死在某个距离」——持续、手动档。
    /// 调用本方法后焦点会一直锁着，直到 `setAutoFocus` 或用户再次点按画面。
    func setManualFocus(lensPosition: Float, on device: AVCaptureDevice) throws {
        // ⚠️ 能力守卫必须用 `isLockingFocusWithCustomLensPositionSupported`（SDK 头文件
        //    AVCaptureDevice.h:1110），**不能用** `isFocusModeSupported(.locked)` ——
        //    虚拟多摄上后者为 true，但 SDK 明文（AVCaptureDevice.h:538-541）虚拟设备
        //    只允许锁 `AVCaptureFocusModeLocked` 的 Current 位置，传自定义 lensPosition
        //    照样抛 ObjC 异常（Swift catch 不住 → abort）。
        //    Mac 侧 2026-09-19 同类预警（与白平衡 7 连崩同因，见 `setManualWhiteBalance`）。
        guard device.isLockingFocusWithCustomLensPositionSupported else {
            throw CaptureConfigurationError.unsupportedFocus
        }
        // 越界写 lensPosition 同样是**抛异常**（不是被忽略），必须先钳。
        let safe = lensPosition.sanitized(or: 0.5).clamped(to: 0...1)
        try withLock(device) {
            device.setFocusModeLocked(lensPosition: safe, completionHandler: nil)
        }
    }

    /// 恢复自动对焦（从手动档退回）
    func setAutoFocus(on device: AVCaptureDevice) throws {
        try withLock(device) {
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
        }
    }

    // MARK: - 手动曝光档（B2 · ISO / 快门刻度条驱动）

    /// 切到**手动曝光档**：ISO 与曝光时长**必须同时给**。
    ///
    /// 为什么必须成对：`setExposureModeCustom(duration:iso:)` 一次接管两者 ——
    /// 锁了 ISO 就得接管曝光时长（反之亦然）。这正是原型注释里那句
    /// 「ISO 与快门**共用一个自动/手动开关**」（`state.auto.isoShutter`）的硬件根源，
    /// 也是 UI 上不可能给出两个独立开关的原因。
    ///
    /// 越界赋值是**抛异常**（不是被忽略）→ 两个值都按 `activeFormat` 的真实范围 clamp。
    func setManualExposure(iso: Float, seconds: Double, on device: AVCaptureDevice) throws {
        guard device.isExposureModeSupported(.custom) else {
            throw CaptureConfigurationError.unsupportedManualExposure
        }
        let format = device.activeFormat
        let safeISO = iso.sanitized(or: format.minISO)
            .clamped(to: format.minISO...format.maxISO)
        let requested = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        let durationRange = format.minExposureDuration...format.maxExposureDuration
        let safeDuration = requested.clamped(to: durationRange)

        try withLock(device) {
            device.setExposureModeCustom(
                duration: safeDuration,
                iso: safeISO,
                completionHandler: nil
            )
        }
        DebugLog.shared.info(
            "device",
            "手动曝光档：ISO \(String(format: "%.0f", safeISO))"
                + " 快门 \(FormatText.shutterSpeed(safeDuration.safeSeconds))"
        )
    }

    /// 手动曝光档 → **自动曝光档**（刻度条右端开关切回自动时走它）
    ///
    /// 与 `setAutoFocus` 同款：设备不支持连续自动曝光时静默不动 ——
    /// 调用方已按能力置灰，这里只兜底，不该让整个拍摄流程中断。
    func setAutoExposure(on device: AVCaptureDevice) throws {
        try withLock(device) {
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
        DebugLog.shared.info("device", "曝光已回到自动档")
    }

    /// 读回手动曝光档的**实际值**（`nil` = 当前不是手动档）。
    ///
    /// ## 为什么回读，而不是本地记账（`docs/16` 第六节）
    ///
    /// `exposureMode` 是**同一个 device 实例上的真值**；切模式（照片↔视频）只换 output、
    /// 不换 device ⇒ 手动档会活下来。本地记账必然出现"UI 说自动、设备是手动"，
    /// 也就是"点了没反应"那一类。与 `docs/14` 那条
    /// "**硬件参数态只能由硬件单向回写**"是同一条纪律。
    func manualExposure(of device: AVCaptureDevice) -> (iso: Float, seconds: Double)? {
        guard device.exposureMode == .custom else { return nil }
        return (device.iso, device.exposureDuration.safeSeconds)
    }

    // MARK: - 手动白平衡档（B2 · 白平衡刻度条驱动）

    /// 切到**手动白平衡档**：色温与色调**必须同时给**。
    ///
    /// 本件只做"色温"一根条（`docs/16` 第十节「不做」）→ 色调由调用方传**设备当前色调**
    /// （`currentTint(of:)`），这样表现就是"只动色温、不动色调"。
    func setManualWhiteBalance(
        temperature: Float,
        tint: Float,
        on device: AVCaptureDevice
    ) throws {
        // ⚠️ 能力守卫必须用 `isLockingWhiteBalanceWithCustomDeviceGainsSupported`
        //    （SDK 头文件 AVCaptureDevice.h:1601），**不能用** `isWhiteBalanceModeSupported(.locked)`
        //    —— 后者在虚拟多摄上也返回 true，但 SDK 明文（AVCaptureDevice.h:538-541）
        //    虚拟设备只允许锁 `AVCaptureWhiteBalanceGainsCurrent`，传**计算出来的增益**
        //    会抛 NSInvalidArgumentException（ObjC 异常，Swift catch 不住 → 全进程 abort）。
        //    2026-09-19 真机 7 次同源崩溃（点白平衡手动开关即崩，栈落在 :328 一带）的根因
        //    就是这条守卫选错了探测 API。换用正确探测后，虚拟设备上为 false → 抛
        //    `unsupportedWhiteBalance` → 上层给诚实边界（置灰 + toast），根本不碰硬件 API。
        guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
            throw CaptureConfigurationError.unsupportedWhiteBalance
        }
        try withLock(device) {
            var values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues()
            values.temperature = temperature.sanitized(or: 5600)
            values.tint = tint.sanitized(or: 0)
            // 温度/色调 → RGB 增益，**必须**把增益钳到设备范围，否则
            // `setWhiteBalanceModeLocked` 抛 NSInvalidArgumentException（与 `applyWhiteBalanceLocked` 同理）
            let gains = normalize(device.deviceWhiteBalanceGains(for: values), for: device)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
        DebugLog.shared.info(
            "device",
            "手动白平衡档：\(String(format: "%.0f", temperature))K"
                + "（色调跟随当前值 \(String(format: "%.0f", tint))）"
        )
    }

    /// 手动白平衡档 → **自动白平衡档**（连续 AWB）
    func setAutoWhiteBalance(on device: AVCaptureDevice) throws {
        try withLock(device) {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
        DebugLog.shared.info("device", "白平衡已回到自动档")
    }

    /// 把设备的白平衡增益转成「色温 / 色调」，**转换前先校验增益是否有效**（无效返回 `nil`）。
    ///
    /// ## 为什么必须校验 —— 2026-09-19 真机冷启动崩溃（本仓第一例 ObjC 异常 abort）
    ///
    /// `temperatureAndTintValues(for:)` 对**无效**的 `deviceWhiteBalanceGains`
    /// 会抛 `NSInvalidArgumentException` —— **Swift 拦不住 ObjC 异常，全进程 abort**。
    /// 而冷启动那一瞬（`session.startRunning()` 是异步的，还没真正跑起来），
    /// 设备白平衡尚未初始化，`deviceWhiteBalanceGains` 正是无效值。崩溃栈：
    ///
    /// ```
    /// objc_exception_throw
    ///   -[AVCaptureFigVideoDevice temperatureAndTintValuesForDeviceWhiteBalanceGains:]  ← 抛
    ///   CaptureDeviceConfigurator.currentTemperature(of:)      （:363-365）
    ///   CaptureSessionController.publishManualState(_:)        （:446）
    ///   CaptureSessionController.startInternal()               （:728-730）
    /// ```
    ///
    /// 有效判据（与 `normalize(_:for:)` 的钳制口径一致）：
    /// **三个分量都 finite，且落在 `1.0 ... device.maxWhiteBalanceGain`**。
    /// 无效时返回 `nil`，调用方各自给兜底值（**不要**在这里瞎猜一个色温）。
    private func temperatureAndTintValues(
        of device: AVCaptureDevice
    ) -> (temperature: Float, tint: Float)? {
        let gains = device.deviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        let isValid: (Float) -> Bool = { value in
            value.isFinite && value >= 1.0 && value <= maxGain
        }
        guard isValid(gains.redGain), isValid(gains.greenGain), isValid(gains.blueGain) else {
            return nil
        }
        // ⚠️ 增益有效才能调这个 API（无效会抛 ObjC 异常，Swift catch 不到）
        let values = device.temperatureAndTintValues(for: gains)
        return (values.temperature, values.tint)
    }

    /// 设备白平衡增益是否有效（能安全地调 `temperatureAndTintValues(for:)`）。
    /// 供会话侧做"冷启动白平衡就绪后补发一次"的判断（见 `CaptureSessionController`）。
    func hasValidWhiteBalanceGains(_ device: AVCaptureDevice) -> Bool {
        temperatureAndTintValues(of: device) != nil
    }

    /// 读回手动白平衡档的**实际值**（`nil` = 当前不是锁定档，**或增益还没初始化好**）。
    ///
    /// ⚠️ 回读的是**实际生效**的色温（设备可能把请求值钳过），所以 toast 要报这个值、不是请求值。
    func manualWhiteBalance(of device: AVCaptureDevice) -> (temperature: Float, tint: Float)? {
        guard device.whiteBalanceMode == .locked else { return nil }
        return temperatureAndTintValues(of: device)
    }

    /// 设备当前的**色调**（只做色温一根条时，色调跟随它 —— 避免"调色温顺手把色调也改了"）。
    ///
    /// 增益还没初始化（冷启动瞬间）→ 兜底 **0**：调用方拿 0 传回 `setManualWhiteBalance`
    /// 时会走 `values.tint.sanitized(or: 0)`，等价于"色调不动"。
    func currentTint(of device: AVCaptureDevice) -> Float {
        temperatureAndTintValues(of: device)?.tint ?? 0
    }

    /// 设备当前的**色温**（AWB 态下就是它的收敛值）。
    /// 自动 → 手动切换时用作初值（拍板 ③：初值取设备当前值，切档瞬间画面不跳）。
    ///
    /// 增益还没初始化（冷启动瞬间）→ 兜底 **5600K**（与 `ParameterStripCatalog` 的默认值同源）。
    /// 会话侧会在快照轮询发现增益就绪后**补发一次**，所以这只是头一两秒的占位值。
    func currentTemperature(of device: AVCaptureDevice) -> Float {
        temperatureAndTintValues(of: device)?.temperature
            ?? Float(ParameterStripCatalog.defaultWhiteBalanceKelvin)
    }

    // MARK: - 参数能力（P2 · 供 UI 画刻度）

    /// 读取设备当前可调参数的**数值范围与当前值**。
    ///
    /// UI（对焦圆盘 / 白平衡横尺 / ISO 横尺…）靠它决定刻度范围与指针位置。
    /// 与 `snapshot(of:)` 的区别：那个产出给人看的可读字符串，这个产出给控件用的数值
    /// —— 用途不同，不要合并。
    func capabilities(of device: AVCaptureDevice) -> CameraParameterCapabilities {
        let format = device.activeFormat
        var caps = CameraParameterCapabilities()

        caps.iso = .init(
            min: Double(format.minISO),
            max: Double(format.maxISO),
            current: Double(device.iso)
        )

        caps.exposureSeconds = .init(
            min: format.minExposureDuration.safeSeconds,
            max: format.maxExposureDuration.safeSeconds,
            current: device.exposureDuration.safeSeconds
        )

        // 对焦位置天生就是 0~1，不需要探测范围
        caps.lensPosition = .init(min: 0, max: 1, current: Double(device.lensPosition))

        let maxZoom = max(
            1.0,
            Double(min(format.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor))
        )
        caps.zoom = .init(min: 1, max: maxZoom, current: Double(device.videoZoomFactor))

        // 色温范围 iOS 没有提供查询 API，按业界惯例取值域
        caps.whiteBalanceTemperature = .init(min: 2000, max: 10000, current: 5600)

        return caps
    }

    // MARK: - 快照

    /// 读取设备当前状态，供调试浮层显示。读操作不需要 lock。
    func snapshot(of device: AVCaptureDevice) -> CaptureDeviceState {
        var state = CaptureDeviceState()
        state.deviceName = device.localizedName
        state.formatText = CaptureCapabilities.formatSummary(device.activeFormat)
        state.frameRateText = String(
            format: "%.0f",
            device.activeVideoMinFrameDuration.safeSeconds > 0
                ? 1.0 / device.activeVideoMinFrameDuration.safeSeconds
                : 0
        )

        switch device.exposureMode {
        case .custom:
            state.exposureText = String(
                format: "M ISO%.0f %@",
                device.iso,
                FormatText.shutterSpeed(device.exposureDuration.safeSeconds)
            )
        case .continuousAutoExposure:
            state.exposureText = "AE \(FormatText.exposureBias(device.exposureTargetBias))"
        case .autoExpose:
            state.exposureText = "AE(单次)"
        case .locked:
            state.exposureText = "曝光锁定"
        @unknown default:
            state.exposureText = "未知"
        }

        switch device.focusMode {
        case .locked:
            state.focusText = String(format: "锁定 %.2f", device.lensPosition)
        case .autoFocus:
            state.focusText = "单次对焦"
        case .continuousAutoFocus:
            state.focusText = "连续对焦"
        @unknown default:
            state.focusText = "未知"
        }

        switch device.whiteBalanceMode {
        case .locked:
            // 手动档读色温也必须走"先验增益有效性"的安全路径（`temperatureAndTintValues(of:)`）
            // —— 直接调 `temperatureAndTintValues(for:)` 对无效增益会抛 ObjC 异常
            // （2026-09-19 冷启动崩溃同款 API，见该私有方法的说明）。
            if let values = temperatureAndTintValues(of: device) {
                state.whiteBalanceText = String(
                    format: "手动 %.0fK/%+.0f",
                    values.temperature,
                    values.tint
                )
            } else {
                state.whiteBalanceText = "手动（读取中）"
            }
        case .continuousAutoWhiteBalance:
            state.whiteBalanceText = "AWB"
        case .autoWhiteBalance:
            state.whiteBalanceText = "AWB(单次)"
        @unknown default:
            state.whiteBalanceText = "未知"
        }

        return state
    }

    // MARK: - 私有：带锁的写入

    /// 统一的 lock / unlock 包装。任何写入都必须走这里，保证不会漏 unlock。
    private func withLock(_ device: AVCaptureDevice, _ body: () throws -> Void) throws {
        do {
            try device.lockForConfiguration()
        } catch {
            throw CaptureConfigurationError.lockFailed
        }
        defer { device.unlockForConfiguration() }
        try body()
    }

    // MARK: - 私有：分项写入（调用方必须已经持锁）

    private func applyExposureLocked(_ preset: CapturePreset, to device: AVCaptureDevice) {
        let format = device.activeFormat

        if let iso = preset.iso, let seconds = preset.exposureDurationSeconds {
            // 手动档：ISO 与曝光时长都要钳到当前格式的合法范围
            let safeISO = iso.sanitized(or: format.minISO).clamped(to: format.minISO...format.maxISO)
            let requested = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            let durationRange = format.minExposureDuration...format.maxExposureDuration
            let safeDuration = requested.clamped(to: durationRange)
            device.setExposureModeCustom(duration: safeDuration, iso: safeISO, completionHandler: nil)
        } else {
            // 自动档：EV 补偿在此生效
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let biasRange = device.minExposureTargetBias...device.maxExposureTargetBias
            let safeBias = preset.exposureBias.sanitized(or: 0).clamped(to: biasRange)
            device.setExposureTargetBias(safeBias, completionHandler: nil)
        }
    }

    private func applyWhiteBalanceLocked(_ preset: CapturePreset, to device: AVCaptureDevice) throws {
        if let temperature = preset.whiteBalanceTemperature, let tint = preset.whiteBalanceTint {
            // 与 `setManualWhiteBalance` 同因同修：能力探测必须用
            // `isLockingWhiteBalanceWithCustomDeviceGainsSupported`（虚拟多摄上
            // `isWhiteBalanceModeSupported(.locked)` 误报 true，写计算增益即崩 —— 详见该处注释）
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                throw CaptureConfigurationError.unsupportedWhiteBalance
            }
            var values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues()
            values.temperature = Float(temperature)
            values.tint = Float(tint)
            // 温度/色调 → RGB 增益，然后**必须**把增益钳到设备范围内，
            // 否则 setWhiteBalanceModeLocked 会抛 NSInvalidArgumentException。
            let gains = normalize(device.deviceWhiteBalanceGains(for: values), for: device)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } else {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    private func applyZoomLocked(_ preset: CapturePreset, to device: AVCaptureDevice) {
        guard abs(preset.zoomFactor - 1.0) > 0.001 else { return }
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor)
        // 注意 upperBound 必须保证 >= 1.0：ClosedRange 的 lower > upper 会直接 trap，
        // 不能假设 maxAvailableVideoZoomFactor 一定是正数（外接设备/异常格式下可能为 0）。
        let upper = max(1.0, Double(maxZoom))
        let target = CGFloat(preset.zoomFactor.sanitized(or: 1.0).clamped(to: 1.0...upper))
        // **配置阶段**用直接设置（瞬移）—— 会话刚建起来，没有"过程"要给用户看。
        // 运行时的平滑变焦走 `applyZoomRamp`（B1 焦段条接的就是那条）。
        //
        // ⚠️ **两个方法必须保持独立，不得互相调用**（自检第 11 组⑨守着）：
        //   本方法的口径 = `CapturePreset.zoomFactor`（预设注入链路，P4 后由 `EditRecipe` 驱动）
        //   `applyZoomRamp` 的口径 = **焦段档位**（UI 真相）
        // 一旦互相调用，将来 P4 注入预设时会出现"两个来源抢 videoZoomFactor" ——
        // 表现为画面在"预设值"与"档位值"之间来回跳，且很难归因。
        device.videoZoomFactor = target
    }

    /// 变焦平滑时长（用户 2026-09-18 拍板：约 0.35s）。
    ///
    /// ⚠️ **这是本件唯一的时长旋钮**：SDK **没有** `withDuration:` 重载（见 `applyZoomRamp`
    /// 的"签名"一节），所以"固定时长"完全由 `rate = log2(目标 / 当前) / zoomRampDuration`
    /// 反推实现 —— 调手感就改这一个常量，调用处无处可传时长。
    ///
    /// 自检第 11 组⑧守着它的量级 ∈ `[0.2, 0.6]s`（太小 ≈ 硬跳、太大 ≈ 拖沓），
    /// 同时守着 `rate` 必须由 `log2` 算出（固定 rate 会让跨档越大越慢）。
    static let zoomRampDuration: TimeInterval = 0.35

    /// 运行时**平滑**变焦（B1：焦段药丸点击 → 这里是接线）。
    ///
    /// ## 签名：只有 `withRate:` 一种（Mac 侧 2026-09-19 读 iOS 26 SDK 的 `AVCaptureDevice.h` 实测）
    ///
    /// 整个 VideoZoom 分类就三个 API：
    /// ```
    /// - (void)rampToVideoZoomFactor:(CGFloat)factor withRate:(float)rate;   // 返回 void
    /// @property(readonly) BOOL rampingVideoZoom;
    /// - (void)cancelVideoZoomRamp;
    /// ```
    /// **没有 `withDuration:` 重载，也没有 `AVCaptureDevice.Ramp` 类型** —— 所以
    /// 「固定时长」只能由 `rate = log2(目标 / 当前) / 期望时长` 反推（见下），
    /// 调用处**不需要** `_ =` 那类"兼容两种签名"的写法（那个前提不成立）。
    ///
    /// > `docs/15` 第二节原先留了"若存在 `withDuration:` 则首选"的分支 —— 已按实测删除。
    /// > **别再把它加回来**：那会让人以为"时长可以直接传"。
    ///
    /// ## 三条硬事实（Apple 文档 2026-09-18 查证，别凭印象改）
    ///
    /// 1. **必须在 `lockForConfiguration()` 内调用** —— 否则抛 `NSGenericException`。
    ///    这也正是本文件存在的理由（工程铁律 2：全工程只有这里允许加锁）。
    /// 2. `rate` 的单位是"**每秒 2 的幂次**"：`1.0` = 每秒翻倍/减半；**只取绝对值**，
    ///    方向由目标值自动决定；`0` 等价于 `cancelVideoZoomRamp()`。
    /// 3. 给 `videoZoomFactor` **赋值会打断进行中的 ramp** —— 所以连点档位**不需要先 cancel**，
    ///    直接再调 ramp 即可（目标被替换）。
    ///
    /// ## 为什么按"目标距离"算 rate，而不是固定 rate
    ///
    /// 固定 rate 意味着"每秒翻倍"恒定 → **跨档越大耗时越长**
    /// （13→120mm 需要 `log2(9.23) / 3 ≈ 1.07s`，太拖）。改成
    /// `rate = log2(目标 / 当前) / 期望时长`，每次切换都约 `duration` 秒，手感一致。
    ///
    /// - Returns: **实际生效**的目标 zoom（已 clamp），供 UI 对账
    @discardableResult
    func applyZoomRamp(
        targetZoomFactor: CGFloat,
        duration: TimeInterval,
        to device: AVCaptureDevice
    ) -> CGFloat {
        // clamp（铁律 2 的通用要求：越界赋值是**抛异常**，不是被忽略）。
        // 区间口径统一走 CaptureCapabilities.zoomRange，避免两处判断漂移。
        let range = CaptureCapabilities.zoomRange(of: device)
        let target = targetZoomFactor.sanitized(or: range.lowerBound).clamped(to: range)

        let current = device.videoZoomFactor
        // 已在目标附近：不折腾（省掉一次无意义的 ramp，也避免"点了像没反应"的错觉）
        guard abs(target - current) > 0.001 else { return target }

        let ratio = Double(target) / Double(max(current, 0.0001))
        let rate = Float(abs(log2(ratio)) / max(duration, 0.05))

        do {
            try withLock(device) {
                // 返回 void（Mac 侧已核对 iOS 26 SDK 头文件）→ 直接调用，不要 `_ =`。
                // 老写法 `_ = device.ramp(...)` 是基于"可能返回 AVCaptureDevice.Ramp"的猜测，
                // 那个前提不成立（没有 Ramp 类型）。真机报错就按 Xcode 自动补全改这一行。
                device.ramp(toVideoZoomFactor: target, withRate: rate)
            }
        } catch {
            DebugLog.shared.error("device", "平滑变焦失败：\(error.localizedDescription)")
        }
        return target
    }

    private func normalize(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        for device: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceGains {
        var result = gains
        let maxGain = device.maxWhiteBalanceGain
        result.redGain = result.redGain.sanitized(or: 1.0).clamped(to: 1.0...maxGain)
        result.greenGain = result.greenGain.sanitized(or: 1.0).clamped(to: 1.0...maxGain)
        result.blueGain = result.blueGain.sanitized(or: 1.0).clamped(to: 1.0...maxGain)
        return result
    }
}
