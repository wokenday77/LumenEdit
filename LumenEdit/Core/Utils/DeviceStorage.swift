import Foundation

/// 设备存储空间。
///
/// 相机 App 必须让用户对"还能拍多少"有概念：
/// 4K30 视频约 **350MB/分钟**，一张 Live Photo 约 3~4MB，一张 HEIC 约 2MB。
/// 存储写满时系统不会给友好提示，而是拍摄直接失败——所以录制/拍摄前先查。
///
/// 注意：这里用的是 `volumeAvailableCapacityForImportantUsage`，
/// 它比 `volumeAvailableCapacity` 更贴近"系统愿意给用户用"的真实可用量，
/// 且需要 `PrivacyInfo.xcprivacy` 里声明 DiskSpace API（reason E174.1）。
enum DeviceStorage {

    /// 剩余可用字节数。查询失败返回 nil（例如沙盒路径异常）。
    static func availableBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// 剩余容量的可读文本，直接给调试浮层用
    static func freeSpaceText() -> String {
        guard let bytes = availableBytes() else { return "—" }
        return FormatText.fileSize(bytes)
    }

    /// 按给定码率估算还能录多久
    /// - Parameter megabitsPerSecond: 视频码率（4K30 约 50，1080p30 约 15）
    /// - Returns: 可读时长文本，例如 "1h 42m"
    static func estimatedRecordingTimeText(megabitsPerSecond: Double) -> String {
        guard let bytes = availableBytes(), megabitsPerSecond > 0 else { return "—" }
        // 留 5% 余量，避免拍到刚好写满导致文件损坏
        let usableBytes = Double(bytes) * 0.95
        let bytesPerSecond = megabitsPerSecond * 1_000_000 / 8
        let seconds = usableBytes / bytesPerSecond
        guard seconds.isFinite, seconds > 0 else { return "—" }

        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// 剩余空间是否已经紧张（低于阈值时 UI 该给提示）
    /// - Parameter bytes: 阈值，默认 1GB
    static func isLowSpace(thresholdBytes: Int64 = 1_000_000_000) -> Bool {
        guard let bytes = availableBytes() else { return false }
        return bytes < thresholdBytes
    }
}
