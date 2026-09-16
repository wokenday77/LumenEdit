import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 错误

enum CaptureConfigurationError: LocalizedError {
    case formatNotBelongToDevice
    case lockFailed
    case partialManualExposure
    case partialManualWhiteBalance
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
        case .unsupportedWhiteBalance:
            return "当前设备不支持锁定的白平衡"
        case .unsupportedFocus:
            return "当前设备不支持手动对焦（锁定焦点）"
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

        try withLock(device) {
            // 处于手动曝光档时 EV 补偿不生效，这里顺手切回自动档，
            // 避免出现"拖了滑块但画面没反应"的困惑。
            if device.exposureMode == .custom,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(safeBias, completionHandler: nil)
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
        guard device.isFocusModeSupported(.locked) else {
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
            let temperatureAndTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            state.whiteBalanceText = String(
                format: "手动 %.0fK/%+.0f",
                temperatureAndTint.temperature,
                temperatureAndTint.tint
            )
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
            guard device.isWhiteBalanceModeSupported(.locked) else {
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
        // P2 会换成 iOS 18 的 AVCaptureDevice.Ramp 做平滑变焦，这里先用直接设置
        device.videoZoomFactor = target
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
