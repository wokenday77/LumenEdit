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

    // MARK: - 焦段 → 变焦倍率（B1）

    /// 设备**最广** constituent 的等效焦距（mm）—— 档位换算 `videoZoomFactor` 的基准。
    ///
    /// **靠 constituent 类型探测，不写机型名**（铁律）：
    ///   - 有超广角 constituent → 最广就是超广角 → **13mm**
    ///   - 没有（单广角 / 只是双摄长焦）→ 最广就是广角 → **24mm**
    ///
    /// 为什么基准必须是探测值而不是写死 13：单摄设备上 `videoZoomFactor = 1.0` 代表的是
    /// **24mm 视场**，此时"13mm 档"要算成 13/24 = 0.54 —— 小于设备的 min（1.0），
    /// 于是会被 `unavailableFocalIds(for:)` 正确判为**不可用**（而不是装作切过去）。
    static func baseMillimeters(of device: AVCaptureDevice) -> CGFloat {
        let hasUltraWide = device.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera
        }
        return hasUltraWide ? 13 : 24
    }

    /// 档位等效焦距 → 虚拟设备的 `videoZoomFactor`（**纯算术**，基准见上）。
    ///
    /// 之所以能用纯算术：虚拟多摄设备的 `videoZoomFactor = 1.0` 是"最广 constituent 的 native 视场"
    /// （Apple 文档：`1.0 (full field of view)`），所以倍率就是焦距比。
    /// 越过系统切换点（`virtualDeviceSwitchOverVideoZoomFactors`，三摄约 `[2.0, 9.2]`）时
    /// **系统自动换 constituent 镜头**，画面平滑 —— 这正是回退链选虚拟设备的理由。
    static func zoomFactor(
        forFocalMillimeters millimeters: CGFloat,
        baseMillimeters base: CGFloat
    ) -> CGFloat? {
        guard base > 0, millimeters > 0 else { return nil }
        return millimeters / base
    }

    /// 设备的 `[min, max]` 可用 zoom 区间（**下限至少 1.0**）。
    ///
    /// 与 `CaptureDeviceConfigurator.applyZoomLocked` 里的口径一致，含"max 可能为 0 / 非正"的防护。
    static func zoomRange(of device: AVCaptureDevice) -> ClosedRange<CGFloat> {
        let lower = max(1.0, device.minAvailableVideoZoomFactor)
        let rawUpper = min(device.activeFormat.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor)
        let upper = max(lower, rawUpper)
        return lower...upper
    }

    /// 当前设备上**不可用**的焦段档位 id 集合（B1 置灰用）。
    ///
    /// 判据：档位换算出的 zoom **落不进** `zoomRange` → 该视场在这台设备上表达不了。
    /// 典型场景：单摄设备上 13mm 档（13/24 = 0.54 < 1.0）。
    ///
    /// ⚠️ 这里**只判"能不能表达"，不判"是不是光学变焦"** ——
    /// 数字变焦也算能表达（画质降级是另一回事，不在置灰范围内）。
    static func unavailableFocalIds(for device: AVCaptureDevice) -> Set<String> {
        let range = zoomRange(of: device)
        let base = baseMillimeters(of: device)
        var unavailable: Set<String> = []
        for preset in FocalCatalog.all {
            guard let mm = preset.millimeters,
                  let zoom = zoomFactor(forFocalMillimeters: mm, baseMillimeters: base) else {
                // 解析不出来的档位按"不可用"处理（宁可灰掉，也不让用户点了没反应）
                unavailable.insert(preset.id)
                continue
            }
            // 容差 0.01：设备能力是浮点，卡在边界上的档位不该被误判
            if zoom < range.lowerBound - 0.01 || zoom > range.upperBound + 0.01 {
                unavailable.insert(preset.id)
            }
        }
        return unavailable
    }

    /// 内置麦克风（Live Photo 与视频都要音轨）
    static func microphone() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }

    // MARK: - 格式

    /// 按偏好排序的采集格式候选列表。
    ///
    /// 排序规则（`sorted(by:)` 语义：返回 true 表示左边更优先）：
    ///   1. 4:3 —— 拍照满幅，不裁切。16:9 的格式会浪费传感器上下部分。
    ///   2. 像素质尽量小 —— 预览和实时处理的开销跟分辨率直接相关，够用就行。
    ///
    /// **为什么返回整份列表而不是单个格式**：
    /// `AVCaptureDeviceFormat` 不暴露任何"支不支持 Live Photo"的属性
    /// （在 `AVCaptureDevice.h` 里 grep `LivePhoto` 零命中）。
    /// 唯一可信的判据是把格式**应用到设备之后**再读
    /// `AVCapturePhotoOutput.isLivePhotoCaptureSupported`。
    /// 所以调用方需要一份有序候选，逐个应用、逐个探测。
    ///
    /// - Parameters:
    ///   - minimumWidth: 最低横向分辨率要求
    ///   - targetFrameRate: 必须支持到的帧率
    static func formatCandidates(
        for device: AVCaptureDevice,
        minimumWidth: Int32 = 1920,
        targetFrameRate: Double = 30
    ) -> [AVCaptureDevice.Format] {
        device.formats
            .filter { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.width >= minimumWidth else { return false }
                return format.videoSupportedFrameRateRanges.contains { range in
                    range.maxFrameRate + 0.001 >= targetFrameRate
                }
            }
            .sorted { lhs, rhs in
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

    /// 候选中的首选格式（不探测 Live Photo 能力时使用）
    static func preferredFormat(
        for device: AVCaptureDevice,
        minimumWidth: Int32 = 1920,
        targetFrameRate: Double = 30
    ) -> AVCaptureDevice.Format? {
        formatCandidates(
            for: device,
            minimumWidth: minimumWidth,
            targetFrameRate: targetFrameRate
        ).first
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
