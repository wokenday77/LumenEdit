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

    /// 这台设备上有没有超广角这颗镜头。
    ///
    /// ⚠️ **不能拿 `caps.zoom.min` 判**（Mac 侧 2026-09-19 预检指出）：单广角回退机型上
    /// 它同样是 `1.0`，区分不了 "1.0 = 最广视场" 还是 "1.0 = 广角视场"。必须问"有没有这颗镜头"。
    ///
    /// 两条探测互补，**任一命中即可**：
    ///
    /// 1. **虚拟设备的 constituent 列表** —— 最准：它说的就是"当前这台设备"里有没有它。
    /// 2. **`DiscoverySession` 直接问系统有没有这颗镜头** —— 兜底。为什么需要：
    ///    `constituentDevices` 只在虚拟设备上有意义，一旦回退到物理设备（或某些系统版本上
    ///    对非虚拟设备返回空数组），① 会**漏判** → 该档不被置灰 → 用户点了画面不动
    ///    （典型的"点了没反应"，本项目明令禁止）。
    ///    为什么 ② 不会误报：本仓回退链是**虚拟多摄优先**（三摄 → 双摄宽 → 双摄 → 单广角），
    ///    机身有这颗镜头的机型必然选到含它的虚拟设备；所以 ① 漏判时，② 的结果就是对的。
    ///    只有"机身有这颗镜头但当前设备用不到"才会误报，而那种情形在本回退链下不存在。
    static func hasUltraWideLens(reachableFrom device: AVCaptureDevice) -> Bool {
        hasLens(.builtInUltraWideCamera, on: device)
    }

    /// 这台设备上有没有长焦那颗镜头（决定 120mm 档可不可用）
    static func hasTelephotoLens(reachableFrom device: AVCaptureDevice) -> Bool {
        hasLens(.builtInTelephotoCamera, on: device)
    }

    /// "有没有某颗镜头"的两条互补探测（原理见 `hasUltraWideLens` 的说明）
    private static func hasLens(
        _ type: AVCaptureDevice.DeviceType,
        on device: AVCaptureDevice
    ) -> Bool {
        if device.constituentDevices.contains(where: { $0.deviceType == type }) {
            return true
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [type],
            mediaType: .video,
            position: .back
        )
        return !discovery.devices.isEmpty
    }

    /// 设备"原生镜头阶梯"上每一级的 `videoZoomFactor`（按视场**从最广到最长**）。
    ///
    /// = `[1.0] + virtualDeviceSwitchOverVideoZoomFactors`
    ///
    /// 依据（Apple 文档 + 2026-09-19 真机实测互验）：
    ///   - `videoZoomFactor = 1.0` 是**最广 constituent 的 native 视场**（文档：full field of view）；
    ///   - 每越过一个 switch-over 点，虚拟设备就换到**下一颗 constituent 的原生视场**。
    ///
    /// 所以第 i 项 = 第 i 颗 constituent 的原生 zoom，与 `constituentRoles(of:)` **按下标一一对应**。
    static func nativeZoomLadder(of device: AVCaptureDevice) -> [CGFloat] {
        [1.0] + device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
    }

    /// 设备各 constituent 的**镜头角色**，已按"视场从最广到最长"排序。
    ///
    /// ⚠️ **显式排序，而不是直接沿用 `constituentDevices` 的顺序**：
    /// 阶梯（`nativeZoomLadder`）按定义是递增的，只要角色也按最广→最长排好，
    /// 两者按下标配对就必然正确 —— 这就不依赖"Apple 返回的数组顺序是否也从广到长"
    /// 这个在本机（无 Xcode）验证不了的前提。
    ///
    /// `constituentDevices` 为空时（非虚拟设备，或系统没给这个列表）**按能力探测重建**：
    /// 只信 `deviceType` 会把"三摄但列表为空"误判成单摄 → 13mm 与 120mm 两档被无谓置灰。
    static func constituentRoles(of device: AVCaptureDevice) -> [FocalLensRole] {
        var roles: [FocalLensRole] = device.constituentDevices.map { constituent in
            switch constituent.deviceType {
            case .builtInUltraWideCamera: return .ultraWide
            case .builtInTelephotoCamera: return .telephoto
            default: return .wide
            }
        }
        if roles.isEmpty {
            if hasUltraWideLens(reachableFrom: device) { roles.append(.ultraWide) }
            roles.append(.wide)
            if hasTelephotoLens(reachableFrom: device) { roles.append(.telephoto) }
        }
        roles.sort { $0.canonicalRank < $1.canonicalRank }
        return roles
    }

    /// 某颗镜头在这台设备上的原生 `videoZoomFactor`（`nil` = 这台设备没有这颗镜头）
    static func nativeZoom(of role: FocalLensRole, on device: AVCaptureDevice) -> CGFloat? {
        let roles = constituentRoles(of: device)
        guard let index = roles.firstIndex(of: role) else { return nil }
        let ladder = nativeZoomLadder(of: device)
        // 阶梯比角色短 = 系统没告诉我们切换点 → 宁可判"不可用"
        // （灰但仍可点，由 VM 给 toast 说明；不装作切过去了）
        guard index < ladder.count else { return nil }
        return ladder[index]
    }

    /// 档位在**这台设备**上对应的 `videoZoomFactor`（`nil` = 这台设备表达不了该档）。
    ///
    /// ## 规则（Mac 侧 2026-09-19 真机实测后给的修法）
    ///
    /// | 档位 | 角色 | 取值 |
    /// |---|---|---|
    /// | 13mm  | 超广角 | 原生视场（阶梯第 0 级 = `1.0`） |
    /// | 24mm  | 广角 | 原生视场（= `switchOver[0]`） |
    /// | 35mm  | 主摄裁切 | 广角原生视场 × `35/24` ≈ **×1.458**（**纯数码裁切**） |
    /// | 48mm  | 主摄裁切 | 广角原生视场 × `48/24` = **×2**（48MP 传感器的 2× 裁切点） |
    /// | 120mm | 长焦 | 原生视场（= `switchOver[last]`） |
    ///
    /// 35 与 48 **共用同一条式子**："主摄原生 × 标称比例"（比例见 `FocalPreset.mainCropFactor`）——
    /// 比在一处写死 `×2` 更难被改坏，48 的值也一分不变。
    /// 35mm 档因此落在 `switchOver[0]`（主摄原生）与 `switchOver[0] × 2` 之间：
    /// **不跨系统切换点、不换镜头**，就是主摄上的数码裁切。
    ///
    /// ## 为什么**不再**用 `mm ÷ 基准`
    ///
    /// 设备的虚拟基准是**机型相关**的。实测某机 `switchOver = [2.000, 10.000]`，
    /// 而 2.0 / 10.0 正对着 24mm / 120mm 两颗镜头的等效焦距
    /// （2.0 × 12 = 24 ✓、10.0 × 12 = 120 ✓，自洽）⇒ **它的基准是 12mm，不是 13mm**。
    ///
    /// 原方案写死 `mm ÷ 13`，后果两层：
    ///   1. 整表偏小约 **8%**（24 → 1.846 而非 2.0；120 → 9.231 而非 10.0）；
    ///   2. **最要命的是 120mm**：9.231 落在 `switchOver[1] = 10.0` **之下** →
    ///      系统根本不会切到长焦，只会继续用主摄数码放大（画质崩），
    ///      而 UI 却显示"已切到 120mm" —— 属于"装作切过去了"，本项目明令禁止。
    ///
    /// 改成按角色读设备之后，**"基准是 12 还是 13mm"这个问题不再需要回答**，
    /// 而且"哪几档可用"顺带由设备自身的镜头构成决定（没有长焦 → 120mm 档置灰）。
    static func zoomFactor(forFocal focal: FocalPreset, of device: AVCaptureDevice) -> CGFloat? {
        guard let role = focal.lensRole else { return nil }
        switch role {
        case .mainCrop:
            // 主摄内部的数码裁切（35 / 48 档）：比例来自 `FocalPreset.mainCropFactor`（= 标称 mm ÷ 24）。
            // ⚠️ **不再写死 `* 2`**：加了 35mm 档之后，"×2"只对 48 成立，两处硬编码容易只改一处。
            guard let wide = nativeZoom(of: .wide, on: device) else { return nil }
            return wide * (focal.mainCropFactor ?? 1)
        case .ultraWide, .wide, .telephoto:
            return nativeZoom(of: role, on: device)
        }
    }

    /// 变焦拓扑一行描述（B1 ④ 的核法：**一次冷启动就能拿到硬数据**）。
    ///
    /// 打印：设备类型 / constituent 数与角色 / switchOver / **原生阶梯** /
    /// **四个档位实际解析出的 zoom** / 哪些档位不可用 / 可用区间。
    ///
    /// 为什么把"档位 → zoom"也打出来：B1 第一版按 `mm ÷ 13` 换算，**真机上整体偏小 8%**
    /// 且 120mm 档落在切换点之下（Mac 侧 2026-09-19 实测发现）。这行日志把那笔账变成
    /// **可当场核对**的硬数据 —— 拿 24mm / 120mm 档的值与 switchOver 一比就知道对不对，
    /// 不用拍图、不用人工判断视场。
    ///
    /// 判读口径：
    ///   - `13mm 档 == 1.000` ✓ 最广 constituent 的原生视场
    ///   - `24mm 档 == switchOver[0]` ✓ 广角原生视场
    ///   - `120mm 档 == switchOver[last]` ✓ 长焦原生视场
    ///     （**必须 ≥ 最后一个切换点**；小于它说明系统不会切长焦，只会数码放大）
    static func zoomTopologyDescription(of device: AVCaptureDevice) -> String {
        let range = zoomRange(of: device)
        let ladder = nativeZoomLadder(of: device)
        let roles = constituentRoles(of: device)
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors
            .map { String(format: "%.3f", $0.doubleValue) }
            .joined(separator: ", ")

        let tierText = FocalCatalog.all.map { preset -> String in
            let value = zoomFactor(forFocal: preset, of: device)
                .map { String(format: "%.3f", $0) } ?? "不可用"
            return "\(preset.id)→\(value)"
        }.joined(separator: " / ")

        let unavailable = unavailableFocalIds(for: device)
        let unavailableText = unavailable.isEmpty
            ? "无"
            : FocalCatalog.all.filter { unavailable.contains($0.id) }
                .map(\.id).joined(separator: ",")

        return "变焦拓扑：deviceType=\(device.deviceType.rawValue)"
            + " · constituents=\(device.constituentDevices.count)"
            + " · 角色=[\(roles.map(\.displayName).joined(separator: ","))]"
            + " · switchOver=[\(switchOvers.isEmpty ? "—" : switchOvers)]"
            + " · 原生阶梯=[\(ladder.map { String(format: "%.3f", $0) }.joined(separator: ", "))]"
            + " · 档位=\(tierText)"
            + " · 不可用=\(unavailableText)"
            + " · zoomRange=[\(String(format: "%.2f", range.lowerBound)),"
            + " \(String(format: "%.2f", range.upperBound))]"
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
    /// 两条判据，任一命中即不可用：
    ///
    /// 1. **设备没有那一档需要的镜头**（`zoomFactor(forFocal:of:)` 返回 `nil`）——
    ///    例如单摄 / "广角+长焦"双摄上没有超广角 → 13mm 档；没有长焦 → 120mm 档。
    ///    这条是 2026-09-19 修正后新增的，比老的"算出来落不进区间"**更早也更准**：
    ///    它直接说的是"镜头不在那儿"，而不是靠算术推出一个够不到的倍率。
    /// 2. 换算出的 zoom **落不进** `zoomRange`（含容差 0.01：设备能力是浮点，
    ///    卡在边界上的档位不该被误判）。
    ///
    /// ⚠️ 这里**只判"能不能表达"，不判"是不是光学变焦"** ——
    /// 35 / 48 两档本来就是主摄内部的数码裁切，它们算"能表达"（画质降级是另一回事，不在置灰范围）。
    static func unavailableFocalIds(for device: AVCaptureDevice) -> Set<String> {
        let range = zoomRange(of: device)
        var unavailable: Set<String> = []
        for preset in FocalCatalog.all {
            guard let zoom = zoomFactor(forFocal: preset, of: device) else {
                // 需要的那颗镜头不存在（或档位数据解析不出来）→ 置灰（仍可点，点了给原因）
                unavailable.insert(preset.id)
                continue
            }
            if zoom < range.lowerBound - 0.01 || zoom > range.upperBound + 0.01 {
                unavailable.insert(preset.id)
            }
        }
        return unavailable
    }

    // MARK: - 参数刻度条：档位 × 设备能力求交（B2）

    /// 三条刻度条在**这台设备上可用**的取值区间。
    ///
    /// | 条 | 区间来源 |
    /// |---|---|
    /// | ISO | `activeFormat.minISO ... maxISO` |
    /// | 快门 | `activeFormat.minExposureDuration ... maxExposureDuration`（换算成**秒**） |
    /// | 白平衡 | **标称域**（iOS 不提供色温范围查询 API，按业界惯例取 2500…10000）→ 即"不设限" |
    ///
    /// ⚠️ **快门那一行的时间方向别搞反**：`minExposureDuration` 是**最快**快门
    /// （1/12000 ≈ 8.3e-5 s），`maxExposureDuration` 是**最慢**（1 s）——
    /// 秒数上是升序，而 UI 上刻度条是"左慢右快"，两者相反。
    /// 搞反的表现是"只有最慢档可用"，一眼可见但原因难猜。
    ///
    /// ⚠️ 设备范围随 `activeFormat` 变（30fps 的格式做不了 1s 长曝光），
    /// 所以这个区间必须**在会话就绪后**（格式已定）读，不能缓存。
    ///
    /// 越界档位由 UI **置灰但保留可点**（点了给 toast 说原因），与焦段条那套一致。
    static func availableRange(
        for kind: ParameterStripKind,
        on device: AVCaptureDevice
    ) -> ClosedRange<Double> {
        let format = device.activeFormat
        switch kind {
        case .iso:
            let lower = Double(format.minISO)
            return lower...max(lower, Double(format.maxISO))
        case .shutter:
            let lower = format.minExposureDuration.safeSeconds
            return lower...max(lower, format.maxExposureDuration.safeSeconds)
        case .whiteBalance:
            // iOS 没有色温范围查询 → 不设限（用标称域的两端）
            let values = ParameterStripCatalog.whiteBalanceValues
            return values[0]...values[values.count - 1]
        }
    }

    /// 某个档位值在这台设备上是否可用（含该条的容差，见 `ParameterStripCatalog.tolerance(for:)`）
    static func isStripValueAvailable(
        _ value: Double,
        for kind: ParameterStripKind,
        on device: AVCaptureDevice
    ) -> Bool {
        let range = availableRange(for: kind, on: device)
        let epsilon = ParameterStripCatalog.tolerance(for: kind)
        return value >= range.lowerBound - epsilon && value <= range.upperBound + epsilon
    }

    /// 某条刻度条上**不可用**的档位值集合（UI 置灰用；空集 = 全档可用）
    static func unavailableStripValues(
        for kind: ParameterStripKind,
        on device: AVCaptureDevice
    ) -> Set<Double> {
        Set(
            ParameterStripCatalog.steps(for: kind)
                .filter { !isStripValueAvailable($0.value, for: kind, on: device) }
                .map(\.value)
        )
    }

    /// 一条刻度条的能力摘要（供调试浮层 / 日志一行看清"哪些档位被灰了"）
    static func stripSummary(for kind: ParameterStripKind, on device: AVCaptureDevice) -> String {
        let range = availableRange(for: kind, on: device)
        let unavailable = unavailableStripValues(for: kind, on: device)
        let total = ParameterStripCatalog.stepCount(for: kind)
        let greyed = unavailable.isEmpty
            ? "无"
            : unavailable.sorted()
                .map { ParameterStripCatalog.label(for: kind, value: $0) }
                .joined(separator: ",")
        return "\(kind.displayName)：档位 \(total - unavailable.count)/\(total)"
            + " · 可用域 [\(String(format: "%.3g", range.lowerBound)),"
            + " \(String(format: "%.3g", range.upperBound))]"
            + " · 置灰=\(greyed)"
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
