import Foundation

// MARK: - 档位

/// 视频分辨率档位（原型 `.fmt-opt[data-g="res"]`：720p / 1080p / 4K）
enum VideoResolution: String, CaseIterable, Identifiable {
    case p720 = "720p"
    case p1080 = "1080p"
    case uhd4K = "4K"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

/// 视频帧率档位（原型 `.fmt-opt[data-g="fps"]`：24 / 30 / 60 / 120）
enum VideoFrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120

    var id: Int { rawValue }
    var displayName: String { String(rawValue) }

    /// 展示顺序就是声明顺序（24 / 30 / 60 / 120），与原型一致
    static var ordered: [VideoFrameRate] { allCases }
}

// MARK: - 目录（单一真源）

/// 视频格式数据 —— **芯片文案 / 剩余可录时长估算 / B 组重设 `activeFormat` 三处共用这一份**。
///
/// ## 码率表是占位数据（与原型同款）
///
/// 原型 `FMT_BITRATE` 是写死的表，注释也写明"真机从 `AVCaptureDevice` 的推荐录制设置拿"。
/// Swift 侧同样先占位 —— 真机应改读 `AVCaptureDevice.Format` 的
/// `videoSupportedFrameRateRanges` + 系统推荐码率，那是 B 组（重设 `activeFormat`）的活。
///
/// ⚠️ **缺键必须有兜底**：`bitrate(for:fps:)` 落到 `defaultBitrate`（原型是 `|| 50`）。
/// 自检第 10 组会校验"12 个值全正 + 键与档位集合一致"，就是为了避免"某个组合静默用兜底值、
/// 时长显示错得看不出来"。
enum VideoFormatCatalog {

    /// 码率占位表（Mbps）：分辨率 × 帧率 → 码率
    static let bitrateTable: [VideoResolution: [VideoFrameRate: Double]] = [
        .p720: [.fps24: 9, .fps30: 11, .fps60: 18, .fps120: 28],
        .p1080: [.fps24: 14, .fps30: 18, .fps60: 28, .fps120: 42],
        .uhd4K: [.fps24: 38, .fps30: 48, .fps60: 50, .fps120: 96]
    ]

    /// 兜底码率（原型 `|| 50`）
    static let fallbackBitrate: Double = 50

    /// 取某组合的码率；缺键时用兜底值
    static func bitrate(for resolution: VideoResolution, frameRate: VideoFrameRate) -> Double {
        bitrateTable[resolution]?[frameRate] ?? fallbackBitrate
    }

    /// 芯片文案：视频模式 `4K · 30`；Log 实况模式 `Log · 4K · 30`（原型 `renderFmt`）
    static func chipText(
        resolution: VideoResolution,
        frameRate: VideoFrameRate,
        isLogMode: Bool
    ) -> String {
        let core = "\(resolution.displayName) · \(frameRate.displayName)"
        return isLogMode ? "Log · \(core)" : core
    }

    /// 剩余可录时长文本（原型 `fmtMinutes()` 的口径）：
    /// `分钟 = 剩余字节 × 8 ÷ (码率Mbps × 10^6) ÷ 60`，由 `DeviceStorage` 算。
    ///
    /// 复用**已有**能力（交接单说的"估算能力已备好"），不新增存储读取逻辑。
    static func recordingTimeText(
        resolution: VideoResolution,
        frameRate: VideoFrameRate
    ) -> String {
        let mbps = bitrate(for: resolution, frameRate: frameRate)
        let minutes = DeviceStorage.estimatedRecordingTimeText(megabitsPerSecond: mbps)
        let freeSpace = DeviceStorage.freeSpaceText()
        // 原型格式：`≈ 85 min · 31 GB`（时长 + 剩余空间一起给，视频模式下这是关键信息）
        return "≈ \(minutes) · \(freeSpace)"
    }
}
