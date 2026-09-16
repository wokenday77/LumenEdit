import CoreMedia
import Foundation

// MARK: - 通用钳制

extension Comparable {

    /// 把值夹到闭区间内。
    ///
    /// 写硬件参数前**必须**过一遍这个函数：`AVCaptureDevice` 对 ISO、
    /// 曝光时长、白平衡增益、曝光补偿都有硬范围，越界不是"被忽略"，而是抛异常。
    func clamped(to range: ClosedRange<Self>) -> Self {
        if self < range.lowerBound { return range.lowerBound }
        if self > range.upperBound { return range.upperBound }
        return self
    }
}

extension BinaryFloatingPoint {

    /// NaN / ±Infinity 一旦写进 `setExposureTargetBias` 之类的接口就会崩。
    /// 所有来自 UI（滑块、手势、文本输入）的浮点值都先过这里。
    func sanitized(or fallback: Self) -> Self {
        isFinite ? self : fallback
    }

    /// 按步长吸附，避免滑块产生 0.30000000000000004 这种值直接进硬件
    func roundedToStep(_ step: Self) -> Self {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }

    /// 钳制 + 吸附 + 去 NaN，一步到位
    func sanitizedClamped(to range: ClosedRange<Self>, step: Self) -> Self {
        sanitized(or: range.lowerBound).clamped(to: range).roundedToStep(step)
    }
}

extension Float {
    /// 曝光补偿的常规步进：1/3 EV
    static let evStep: Float = 1.0 / 3.0
}

// MARK: - CMTime

extension CMTime {

    func clamped(to range: ClosedRange<CMTime>) -> CMTime {
        if CMTimeCompare(self, range.lowerBound) < 0 { return range.lowerBound }
        if CMTimeCompare(self, range.upperBound) > 0 { return range.upperBound }
        return self
    }

    /// `CMTime.seconds` 在 invalid / indefinite 时是 NaN，不要直接拿去算 UI
    var safeSeconds: Double {
        let value = seconds
        return value.isFinite ? value : 0
    }
}

// MARK: - 显示格式化

enum FormatText {

    /// 快门速度显示：1/1000s 这种写法比 0.001 直观得多
    static func shutterSpeed(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "—" }
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }
        let denominator = (1.0 / seconds).rounded()
        return "1/\(Int(denominator))s"
    }

    /// 曝光补偿显示：+0.7 / -1.3
    static func exposureBias(_ value: Float) -> String {
        String(format: "%+.1f", value)
    }

    static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
