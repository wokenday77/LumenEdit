import AVFoundation
import Foundation

/// 能力探测。
///
/// **铁律：不写机型判断。** 不出现 "iPhone16" 之类的字符串，全部靠能力探测：
/// 设备类型回退链、`activeFormat` 的具体能力、输出对象自己的 `isXxxSupported`。
/// 这样新机型上市不需要改代码，老机型也不会因为硬编码判断而走进死路。
enum CaptureCapabilities {

    // MARK: - 设备

    /// 后置摄像头回退链。
    /// 从"能力最强"到"一定有"排列：三摄 → 双摄（广角+超广角）→ 双摄 → 单广角。
    /// `.builtInTripleCamera` 这类虚拟设备的好处是变焦切换镜头时画面平滑，不会跳。
    static let backCameraFallbackChain: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera,
    ]

    /// 按回退链取第一个可用的后置摄像头。取不到返回 nil（模拟器上就是 nil）。
    static func backCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: backCameraFallbackChain,
            mediaType: .video,
            position: .back
        )
        for type in backCameraFallbackChain {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return discovery.devices.first
    }

    /// 内置麦克风（Live Photo 与视频都要音轨）
    static func microphone() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }

    // MARK: - 格式

    /// 挑选一个合适的采集格式。
    ///
    /// 选择优先级（`min(by:)` 语义：返回 true 表示左边更优先）：
    ///   1. 4:3 —— 拍照满幅，不裁切。16:9 的格式会浪费传感器上下部分。
    ///   2. 像素质尽量小 —— 预览和实时处理的开销跟分辨率直接相关，够用就行。
    ///   3. 宽度降序后取最小 —— 同上，反向收敛。
    ///
    /// - Parameters:
    ///   - minimumWidth: 最低横向分辨率要求
    ///   - targetFrameRate: 必须支持到的帧率
    static func preferredFormat(
        for device: AVCaptureDevice,
        minimumWidth: Int32 = 1920,
        targetFrameRate: Double = 30
    ) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= minimumWidth else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.maxFrameRate + 0.001 >= targetFrameRate
            }
        }

        return candidates.min { lhs, rhs in
            let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let leftIsFourThree = left.width * 3 == left.height * 4
            let rightIsFourThree = right.width * 3 == right.height * 4
            if leftIsFourThree != rightIsFourThree {
                return leftIsFourThree
            }
            return left.width * left.height < right.width * right.height
        }
    }

    /// 某个格式支持的帧率范围（取各 range 的并集边界）
    static func frameRateRange(of format: AVCaptureDevice.Format) -> ClosedRange<Double> {
        let ranges = format.videoSupportedFrameRateRanges
        guard !ranges.isEmpty else { return 1...30 }
        let lower = ranges.map(\.minFrameRate).min() ?? 1
        let upper = ranges.map(\.maxFrameRate).max() ?? 30
        return lower...max(lower, upper)
    }

    /// 给调试浮层用的一行格式描述
    static func formatSummary(_ format: AVCaptureDevice.Format) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = frameRateRange(of: format)
        var tags: [String] = []
        if format.isVideoBinned { tags.append("binned") }
        if dimensions.width * 3 == dimensions.height * 4 {
            tags.append("4:3")
        } else if dimensions.width * 9 == dimensions.height * 16 {
            tags.append("16:9")
        }
        let maxPhoto = format.supportedMaxPhotoDimensions
            .map { "\($0.width)x\($0.height)" }
            .joined(separator: "/")
        if !maxPhoto.isEmpty { tags.append("photoMax=\(maxPhoto)") }
        let suffix = tags.isEmpty ? "" : " " + tags.joined(separator: " ")
        return "\(dimensions.width)x\(dimensions.height) \(String(format: "%.0f-%.0f", fps.lowerBound, fps.upperBound))fps\(suffix)"
    }

    // MARK: - 输出能力

    static func isLivePhotoCaptureSupported(by output: AVCapturePhotoOutput) -> Bool {
        output.isLivePhotoCaptureSupported
    }

    /// 设备是否支持手动白平衡增益（少数外接设备不支持）
    static func supportsManualWhiteBalance(_ device: AVCaptureDevice) -> Bool {
        device.isWhiteBalanceModeSupported(.locked)
    }

    /// 设备是否支持点测光
    static func supportsPointOfInterest(_ device: AVCaptureDevice) -> (focus: Bool, exposure: Bool) {
        (device.isFocusPointOfInterestSupported, device.isExposurePointOfInterestSupported)
    }

    /// 可用的照片编码格式（HEIC 优先）
    static func preferredPhotoCodecType(by output: AVCapturePhotoOutput) -> AVVideoCodecType? {
        let available = output.availablePhotoCodecTypes
        if available.contains(.hevc) { return .hevc }
        if available.contains(.jpeg) { return .jpeg }
        return available.first
    }
}
