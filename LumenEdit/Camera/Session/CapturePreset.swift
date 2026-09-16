import Foundation

/// 相机参数预设。
///
/// **这是「参数预设与相机联动」这条链路的中间结构**：
///
///     修图页调好的参数（EditRecipe）
///             ↓  P2 加 init(from:)
///     CapturePreset（本结构，纯数据、可 Codable）
///             ↓  CaptureDeviceConfigurator.apply(preset:to:)
///     AVCaptureDevice（真实硬件）
///
/// P1a 只用到 `exposureBias`，但字段一次定义完整——因为 `CaptureDeviceConfigurator`
/// 的接口签名要按最终形态设计，否则 P2 得把调用方全部改一遍。
///
/// 关于「自动档 / 手动档」的互斥（P2 的 UI 要体现）：
///   - `iso` 与 `exposureDurationSeconds` 都为 nil → **自动曝光**，此时 `exposureBias` 生效；
///   - 两者都有值 → **手动曝光**，此时 `exposureBias` 被系统忽略；
///   - 只填一个 → 非法状态，配置器会拒绝并落一条警告日志。
/// 白平衡同理：`whiteBalanceTemperature` 与 `whiteBalanceTint` 要么都有，要么都没有。
struct CapturePreset: Codable, Equatable {

    // MARK: 曝光

    /// 曝光补偿（EV）。仅自动曝光模式下有效。
    var exposureBias: Float = 0

    /// 手动 ISO。nil 表示自动。
    var iso: Float?

    /// 手动曝光时长（秒）。nil 表示自动。
    var exposureDurationSeconds: Double?

    // MARK: 白平衡

    /// 手动色温（开尔文）。nil 表示自动白平衡。
    var whiteBalanceTemperature: Double?

    /// 手动色调（-150 ~ 150）。必须与色温同时存在。
    var whiteBalanceTint: Double?

    // MARK: 对焦（P2 新增 —— 手动对焦圆盘驱动它）

    /// 手动对焦位置：**归一化 0 ~ 1**（0 = 最近、1 = 无穷远）。nil 表示自动对焦。
    ///
    /// ⚠️ 这是 `AVCaptureDevice.lensPosition` 的原始量纲，**不是米数**。
    /// 硬件只认 0~1；中心（0.5 附近）大致对应几米处，且不同镜头的映射不一样。
    /// 米数只在 UI 上显示用，换算放在 UI 侧做，不要污染这个模型。
    var lensPosition: Float?

    // MARK: 其他

    /// 变焦倍率，1.0 表示广角原生倍率
    var zoomFactor: Double = 1.0

    /// 是否开启闪光灯
    var isFlashEnabled: Bool = false

    // MARK: - 派生属性

    static let `default` = CapturePreset()

    /// 是否处于手动对焦档
    var isManualFocus: Bool { lensPosition != nil }

    /// 是否处于手动曝光档
    var isManualExposure: Bool {
        iso != nil && exposureDurationSeconds != nil
    }

    /// 是否处于手动白平衡档
    var isManualWhiteBalance: Bool {
        whiteBalanceTemperature != nil && whiteBalanceTint != nil
    }

    /// 非法的"半手动"状态：只填了 ISO 没填快门，或反过来
    var hasPartialManualExposure: Bool {
        (iso == nil) != (exposureDurationSeconds == nil)
    }

    /// 非法的白平衡状态
    var hasPartialManualWhiteBalance: Bool {
        (whiteBalanceTemperature == nil) != (whiteBalanceTint == nil)
    }

    /// 调试浮层与 UI 上的一行摘要
    var summary: String {
        var parts: [String] = []
        if isManualExposure {
            let isoText = String(format: "%.0f", iso ?? 0)
            let shutter = FormatText.shutterSpeed(exposureDurationSeconds ?? 0)
            parts.append("M \(isoText) \(shutter)")
        } else {
            parts.append("A \(FormatText.exposureBias(exposureBias))")
        }
        if isManualWhiteBalance {
            parts.append(String(format: "%.0fK/%+.0f", whiteBalanceTemperature ?? 0, whiteBalanceTint ?? 0))
        } else {
            parts.append("AWB")
        }
        if isManualFocus, let lensPosition {
            parts.append(String(format: "MF %.2f", lensPosition))
        }
        if abs(zoomFactor - 1.0) > 0.001 {
            parts.append(String(format: "%.1fx", zoomFactor))
        }
        return parts.joined(separator: " · ")
    }
}
