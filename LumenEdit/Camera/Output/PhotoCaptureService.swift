import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 照片拍摄服务：封装 `AVCapturePhotoOutput`。
///
/// 几个容易踩的点，都在这一个文件里处理掉：
///
/// 1. **`AVCapturePhotoSettings` 必须每次新建**。拍摄时会修改 flash、质量等字段，
///    直接复用同一个实例并发拍摄会抛异常。做法是保留一份"模板"，
///    每次用 `AVCapturePhotoSettings(from:)` 复制一份出来改——
///    这比每次从零拼参数更省事，也不会丢掉编码格式等关键配置。
///
/// 2. **`isAutoDeferredPhotoDeliveryEnabled` 要关掉**（iOS 17+）。
///    开着的时候系统可能延迟处理，`fileDataRepresentation()` 拿到的是代理图，
///    表现为"存到相册的照片比预览糊"。这个坑很隐蔽，所以显式关闭。
///
/// 3. **完成时机要等 `didFinishCaptureFor`**，不能拿到照片就回调。
///    `didFinishProcessingPhoto` 只保证照片处理完，整个拍摄流程（含元数据写入）
///    要到 `didFinishCaptureFor` 才结束。P1b 的 Live Photo 更是必须等两个回调都到齐，
///    所以这套"先暂存、后统一完成"的结构从一开始就搭好。
final class PhotoCaptureService: NSObject {

    /// session 持有的输出对象；`CaptureSessionController` 负责把它加进 session
    let output = AVCapturePhotoOutput()

    private let stateLock = NSLock()
    private var template: AVCapturePhotoSettings?
    private var pendingCompletion: ((Result<CaptureResult, Error>) -> Void)?

    // 静态照片的单次暂存区。同一时刻只允许一次拍摄（UI 上会禁用快门），所以单字段够用。
    // Live Photo 走另一条路：它有两个不保证顺序的回调，必须按 uniqueID 配对
    // （见 LivePhotoCaptureService / LivePhotoAssembler）。
    private var pendingImageData: Data?
    private var pendingPixelSize: CGSize = .zero

    // MARK: 实拍裁切（docs/26 刀 1 · 批九「实拍裁切」）

    /// 本次拍摄要求的遮幅"高÷宽"（`FrameRatio.heightOverWidth`）。
    /// `nil` = 不裁（4:3 整帧直存原始字节，或 Live 路径——Live 裁切 = 刀 1b）。
    private var pendingMaskHeightOverWidth: CGFloat?
    /// 拍摄编码格式（重编码容器选择用：HEVC → HEIC，否则 JPEG）。prepareTemplate 时定。
    private var preparedCodec: AVVideoCodecType = .jpeg
    /// 本次拍摄快照的编码格式（与 pendingMask... 同批存取）
    private var pendingCodec: AVVideoCodecType = .jpeg

    /// 当前进行中的 Live Photo 拍摄。
    /// 非 nil 时，photo delegate 的两个回调会转发给它，而不是走静态照片路径。
    private var livePhotoService: LivePhotoCaptureService?

    /// 当前是否有拍摄在进行中
    private var _isBusy = false
    var isBusy: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isBusy
    }

    // MARK: - 配置（必须在 session 的 beginConfiguration 区间内调用）

    /// 按模式准备照片输出。
    ///
    /// ⚠️ 本方法当前**只对 `.photo` / `.livePhoto` 有实际作用**（这两个模式才会把
    /// `photoService.output` 挂进 session，见 `CaptureSessionController.reconfigureOutputsLocked`）。
    /// 另外两个模式走录制链路，走不到这里；分支仍然写全，是为了保住 switch 的穷尽性
    /// ——新增模式时编译期就会提醒，而不是运行时静默沿用上一次的开关状态。
    func configure(for mode: CaptureSessionMode) {
        // 关闭延迟处理：见类注释第 2 条
        output.isAutoDeferredPhotoDeliveryEnabled = false

        switch mode {
        case .photo:
            output.isLivePhotoCaptureEnabled = false
        case .livePhoto:
            // 不支持时硬设为 true 会抛异常，必须先探测
            let supported = output.isLivePhotoCaptureSupported
            output.isLivePhotoCaptureEnabled = supported
            DebugLog.shared.info("photo", "Live Photo 采集 \(supported ? "已开启" : "不被支持，已保持关闭")")
        case .logLive, .video:
            // 录制链路：照片输出不参与拍摄，Live Photo 必须显式关掉。
            // AVCapturePhotoOutput.h 明确写着 livePhotoCaptureEnabled 在配置变更后可能自己回到
            // NO；反过来说，从 Live 切到录制链路上如果不清一次，残留的开启状态会让
            // 之后切回照片模式时行为不符合预期。
            output.isLivePhotoCaptureEnabled = false
        }

        output.maxPhotoQualityPrioritization = .balanced
    }

    /// 生成拍摄设置模板（用相机支持的最优编码格式，HEIC 优先）
    func prepareTemplate() {
        let codec = CaptureCapabilities.preferredPhotoCodecType(by: output) ?? .jpeg
        let settings: AVCapturePhotoSettings

        if output.availablePhotoCodecTypes.contains(codec) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            DebugLog.shared.info("photo", "照片编码格式：\(codec.rawValue)")
        } else {
            settings = AVCapturePhotoSettings()
            DebugLog.shared.warn("photo", "声明的编码格式不可用，回退到默认设置")
        }

        settings.photoQualityPrioritization = .balanced

        stateLock.lock()
        template = settings
        preparedCodec = codec
        stateLock.unlock()
    }

    // MARK: - 拍摄

    /// 触发一次拍摄。
    /// - Parameter maskHeightOverWidth: 遮幅"高÷宽"（窗高宽比）。`nil` 或 4:3 = 不裁、
    ///   整帧原始字节直存；16:9 / 1:1 → 中心裁切后重编码（见 `croppedRepresentation`）。
    ///   控制器已保证 **Live 路径不带比例**（Live 裁切 = 刀 1b）。
    /// - Parameter completion: 在**主线程**回调，携带归一化后的结果
    func capture(
        maskHeightOverWidth: CGFloat?,
        completion: @escaping (Result<CaptureResult, Error>) -> Void
    ) {
        stateLock.lock()
        if _isBusy {
            stateLock.unlock()
            completion(.failure(CaptureConfigurationError.lockFailed))
            DebugLog.shared.warn("photo", "上一次拍摄尚未结束，忽略本次快门")
            return
        }
        _isBusy = true
        pendingCompletion = completion
        pendingImageData = nil
        pendingPixelSize = .zero
        pendingMaskHeightOverWidth = Self.normalizedCropRatio(maskHeightOverWidth)
        pendingCodec = preparedCodec
        let templateSettings = template
        stateLock.unlock()

        // 复制模板而不是复用：见类注释第 1 条
        let settings: AVCapturePhotoSettings
        if let templateSettings {
            settings = AVCapturePhotoSettings(from: templateSettings)
        } else {
            settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            DebugLog.shared.warn("photo", "模板缺失，使用默认设置拍摄")
        }
        settings.flashMode = .off

        DebugLog.shared.info("photo", "快门触发")
        output.capturePhoto(with: settings, delegate: self)
    }

    /// 触发一次 Live Photo 拍摄。
    ///
    /// 和静态照片的区别只在 settings：多设 `livePhotoMovieFileURL` 与视频编码格式。
    /// **uniqueID 不能自己指定**——`AVCapturePhotoSettings.uniqueID` 是只读属性，由系统分配。
    /// 配对改用「运行时认领」：第一个到达的回调把系统 ID 记下来，之后校验一致性，
    /// 详见 `LivePhotoCaptureService.claim(_:)`。
    /// 结果要等静态照片与配对视频**两半都到齐**才产出。
    func captureLivePhoto(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        guard output.isLivePhotoCaptureEnabled else {
            let error = LivePhotoCaptureError.notSupported
            DebugLog.shared.error("live", error.localizedDescription)
            completion(.failure(error))
            return
        }

        stateLock.lock()
        if _isBusy {
            stateLock.unlock()
            DebugLog.shared.warn("photo", "上一次拍摄尚未结束，忽略本次 Live Photo 快门")
            completion(.failure(CaptureConfigurationError.lockFailed))
            return
        }
        _isBusy = true
        let templateSettings = template
        stateLock.unlock()

        let movieURL = LivePhotoCaptureService.makeTemporaryMovieURL()

        let service = LivePhotoCaptureService(movieURL: movieURL) { [weak self] result in
            // Live Photo 的收尾不走本类的 finish(error:)，所以忙碌标志在这里放开
            self?.markNotBusy()
            completion(result)
        }

        stateLock.lock()
        livePhotoService = service
        stateLock.unlock()

        let baseSettings: AVCapturePhotoSettings
        if let templateSettings {
            baseSettings = templateSettings
        } else {
            baseSettings = AVCapturePhotoSettings()
            baseSettings.photoQualityPrioritization = .balanced
            DebugLog.shared.warn("photo", "模板缺失，Live Photo 使用默认设置拍摄")
        }

        let settings = LivePhotoCaptureService.makeSettings(
            from: baseSettings,
            videoCodecType: LivePhotoCaptureService.preferredVideoCodecType(for: output),
            movieURL: movieURL
        )

        DebugLog.shared.info("live", "Live Photo 快门触发（uniqueID 由系统分配，首个回调到达时认领）")
        output.capturePhoto(with: settings, delegate: self)
    }

    /// 释放忙碌标志（Live Photo 路径专用）
    private func markNotBusy() {
        stateLock.lock()
        _isBusy = false
        stateLock.unlock()
    }

    // MARK: - 私有：收尾

    /// 遮幅比归一：`nil` 直接透传；4:3（整帧）归一成 `nil`（不裁）。
    private static func normalizedCropRatio(_ ratio: CGFloat?) -> CGFloat? {
        guard let r = ratio, r > 0 else { return nil }
        if abs(r - 4.0 / 3.0) < 0.001 { return nil }
        return r
    }

    /// 按遮幅比对静态照片做**中心裁切**并重编码（docs/26 刀 1 · 批九「实拍裁切」）。
    ///
    /// - 只服务 `.photo` 非 Live 路径；**Live 裁切 = 刀 1b**（Live 有静态+视频两份资源，
    ///   只裁静态会拆散配对，必须走 `PHLivePhotoEditingContext` 逐帧裁 —— 下一小步单独交付）。
    /// - 像素空间公式与窗内渲染同口径（`ViewfinderWindowRenderer.windowCropRect` 的横片
    ///   换算版）：照片是横片像素（4032×3024 + EXIF Orientation 90），竖排窗高宽比 `r`
    ///   在像素空间为 `pw = min(w, h·r)`、`ph = pw / r`，中心取矩形。
    /// - 元数据整体保留（EXIF/GPS/TIFF Orientation —— 裁切中心对称，竖排语义不变）；
    ///   仅 Exif PixelX/YDimension 按裁后尺寸覆写。
    /// - 画质：一次有损重编码（0.95）。P4c PhotoExporter 落地后此路径会被收编。
    /// - 返回 `nil` = 裁切未生效（调用方按整帧入库，不拦拍摄）。
    private func croppedRepresentation(
        from photo: AVCapturePhoto,
        maskHeightOverWidth r: CGFloat
    ) -> (data: Data, pixelSize: CGSize)? {
        guard let cg = photo.cgImageRepresentation() else {
            DebugLog.shared.warn("photo", "实拍裁切：拿不到 CGImage 表示")
            return nil
        }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }

        let pw = min(w, h * r)
        let ph = pw / r
        let rect = CGRect(x: (w - pw) / 2, y: (h - ph) / 2, width: pw, height: ph)
        guard let cropped = cg.cropping(to: rect) else {
            DebugLog.shared.warn("photo", "实拍裁切：CGImage.cropping 失败")
            return nil
        }

        let out = NSMutableData()
        let type = (pendingCodec == .hevc ? UTType.heic : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else {
            DebugLog.shared.warn("photo", "实拍裁切：创建编码器失败")
            return nil
        }

        var metadata = photo.metadata
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [String: Any] {
            // 常量值即 kCGImagePropertyExifPixelXDimension / ...PixelYDimension
            exif["PixelXDimension"] = Int(pw)
            exif["PixelYDimension"] = Int(ph)
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        // 重编码质量（唯一一次有损环节，给足 0.95；P4c PhotoExporter 落地后收编此路径）
        metadata[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(destination, cropped, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination), out.length > 0 else {
            DebugLog.shared.warn("photo", "实拍裁切：编码失败")
            return nil
        }

        DebugLog.shared.info(
            "photo",
            "实拍裁切已生效：像素 \(Int(pw))x\(Int(ph))"
                + "（遮幅高宽比 \(String(format: "%.3f", r)) · 容器 \(pendingCodec == .hevc ? "HEIC" : "JPEG")）"
        )
        return (out as Data, CGSize(width: pw, height: ph))
    }

    private func finish(error: Error?) {
        stateLock.lock()
        let completion = pendingCompletion
        let data = pendingImageData
        let size = pendingPixelSize
        pendingCompletion = nil
        pendingImageData = nil
        pendingPixelSize = .zero
        _isBusy = false
        stateLock.unlock()

        guard let completion else { return }

        let result: Result<CaptureResult, Error>
        if let error {
            DebugLog.shared.error("photo", "拍摄失败：\(error.localizedDescription)")
            result = .failure(error)
        } else if let data, !data.isEmpty {
            DebugLog.shared.info("photo", "拍摄完成 \(Int(size.width))x\(Int(size.height)) \(data.count) 字节")
            result = .success(.photo(data: data, pixelSize: size))
        } else {
            DebugLog.shared.error("photo", "拍摄完成但未拿到图像数据")
            result = .failure(PhotoLibraryError.emptyData)
        }

        DispatchQueue.main.async {
            completion(result)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension PhotoCaptureService: AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let dimensions = photo.resolvedSettings.photoDimensions
        let pixelSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))

        // Live Photo 路径：这一半（静态照片）交给配对器等另一半（MOV），不在本类收尾
        stateLock.lock()
        let livePhoto = livePhotoService
        stateLock.unlock()

        if let livePhoto {
            livePhoto.ingestImage(
                uniqueID: photo.resolvedSettings.uniqueID,
                data: photo.fileDataRepresentation(),
                pixelSize: pixelSize,
                error: error
            )
            return
        }

        if let error {
            DebugLog.shared.error("photo", "照片处理失败：\(error.localizedDescription)")
            return
        }

        // `fileDataRepresentation()` 返回相机已经编码好的原始字节。
        // 直接拿去入库，不要解码成 UIImage 再重新编码——那会平白损失一次画质。
        guard let data = photo.fileDataRepresentation() else {
            DebugLog.shared.error("photo", "fileDataRepresentation() 返回空")
            return
        }

        // 实拍裁切（docs/26 刀 1）：遮幅 16:9 / 1:1 时中心裁切后重编码；
        // 4:3（或未带比例）= 整帧原始字节直存，本段完全不生效。
        stateLock.lock()
        let cropRatio = pendingMaskHeightOverWidth
        stateLock.unlock()

        var finalData = data
        var finalSize = pixelSize
        if let r = cropRatio {
            if let cropped = croppedRepresentation(from: photo, maskHeightOverWidth: r) {
                finalData = cropped.data
                finalSize = cropped.pixelSize
            } else {
                // 裁切失败不拦拍摄：按整帧入库 + 留痕（Mac 复验时看这行就知道退回了）
                DebugLog.shared.warn("photo", "实拍裁切未生效，按整帧入库")
            }
        }

        stateLock.lock()
        pendingImageData = finalData
        pendingPixelSize = finalSize
        stateLock.unlock()
    }

    /// Live Photo 的配对视频处理完成。
    ///
    /// ⚠️ 它和 `didFinishProcessingPhoto` 的**先后顺序不保证**，
    /// 所以两边都只是往配对器里喂数据，齐了才产出结果。
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        stateLock.lock()
        let livePhoto = livePhotoService
        stateLock.unlock()

        guard let livePhoto else {
            DebugLog.shared.warn("live", "收到 Live Photo 视频回调但没有进行中的拍摄，忽略")
            return
        }

        DebugLog.shared.debug(
            "live",
            "配对视频已生成，时长 \(String(format: "%.2f", duration.safeSeconds))s"
        )
        livePhoto.ingestMovie(
            uniqueID: resolvedSettings.uniqueID,
            url: outputFileURL,
            error: error
        )
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        // Live Photo 路径：交给它收尾，并把进行中的引用清掉
        stateLock.lock()
        let livePhoto = livePhotoService
        livePhotoService = nil
        stateLock.unlock()

        if let livePhoto {
            livePhoto.finishCapture(uniqueID: resolvedSettings.uniqueID, error: error)
            return
        }

        finish(error: error)
    }
}
