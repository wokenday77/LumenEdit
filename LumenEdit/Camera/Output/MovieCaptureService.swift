import AVFoundation
import Foundation

// MARK: - 错误

enum MovieCaptureError: LocalizedError {
    case notReady
    case alreadyRecording
    case notRecording
    case nothingToSave
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:         return "相机尚未就绪"
        case .alreadyRecording: return "已经在录制中了"
        case .notRecording:     return "当前没有在录制"
        case .nothingToSave:    return "录制的文件为空"
        case .failed(let r):    return r
        }
    }
}

/// 视频录制服务：封装 `AVCaptureMovieFileOutput`。
///
/// ## 为什么用 `AVCaptureMovieFileOutput`
/// 它把「写文件 + 音视频同步 + 方向元数据」都包好了，直接产出可入库的 MOV。
/// 代价是拿不到逐帧数据 —— P6 做视频编辑需要逐帧时再换成
/// `AVCaptureVideoDataOutput` + `AVAssetWriter`。现在目标是「稳定录下来」，
/// 用系统封装能少踩一堆坑。
///
/// ## 与照片路径的关系
/// 两条路径**互斥**：视频模式下 session 只挂本服务的 output，照片模式只挂 photoOutput。
/// 切换由 `CaptureSessionController.reconfigureOutputsLocked` 负责 ——
/// Live Photo 与视频录制在底层存在互斥限制，共存会出现「某个模式拍摄静默失败」。
///
/// ## 三个必须守住的点
/// 1. **临时文件 URL 每次都要全新**（复用同一路径会让录制直接失败）。
/// 2. **`didFinishRecordingTo` 带回 error 不代表失败**：只要
///    `AVErrorRecordingSuccessfullyFinishedKey == true`，文件就是有效的
///    （典型场景：录到时长上限，或用户中途切后台被系统停止）。这是最容易误判的地方。
/// 3. **停止是异步的**：`stopRecording()` 只是发出请求，产物要等代理回调，
///    所以结果只能经 completion 交付，不能立即返回。
final class MovieCaptureService: NSObject {

    /// 挂在 session 上的录制输出
    let output = AVCaptureMovieFileOutput()

    // MARK: - 状态

    private let lock = NSLock()
    private var _isRecording = false
    private var didDeliver = false
    private var startedAt: Date?
    private var pendingCompletion: ((Result<CaptureResult, Error>) -> Void)?
    private var currentURL: URL?

    /// 是否正在录制
    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRecording
    }

    /// 已录制时长（秒）。没在录时返回 0。
    var recordedDuration: TimeInterval {
        lock.lock()
        let start = startedAt
        lock.unlock()
        guard let start else { return 0 }
        return Date().timeIntervalSince(start)
    }

    /// 录制时长上限（秒）。到点系统会自动停止，代理回调里会带对应 error，
    /// 但按上面第 2 条，文件仍然有效。
    var maxDuration: TimeInterval = 600

    /// 时长心跳，供 UI 计时用。回调在主线程。
    var onTick: ((TimeInterval) -> Void)?

    private var tickTimer: Timer?

    deinit {
        tickTimer?.invalidate()
    }

    // MARK: - 开始 / 停止

    /// 开始录制。产物通过 completion 交付（通常要等到停止之后）。
    func startRecording(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        lock.lock()
        if _isRecording {
            lock.unlock()
            completion(.failure(MovieCaptureError.alreadyRecording))
            return
        }
        _isRecording = true
        didDeliver = false
        startedAt = Date()
        pendingCompletion = completion
        lock.unlock()

        let url = Self.makeTemporaryMovieURL()
        currentURL = url

        output.maxRecordedDuration = CMTime(seconds: maxDuration, preferredTimescale: 600)
        output.startRecording(to: url, recordingDelegate: self)

        DebugLog.shared.info("movie", "开始录制 → \(url.lastPathComponent)")
        startTick()
    }

    /// 请求停止录制。产物仍走开始录制时传入的那个 completion。
    func stopRecording() {
        lock.lock()
        let recording = _isRecording
        lock.unlock()

        guard recording else {
            DebugLog.shared.warn("movie", "没有在录制，忽略停止请求")
            return
        }
        DebugLog.shared.info("movie", "请求停止录制")
        output.stopRecording()
    }

    // MARK: - 静态工具

    /// 每次录制都用全新的临时文件路径 —— 复用同一路径会让录制直接失败。
    static func makeTemporaryMovieURL() -> URL {
        let name = "lumen-video-\(UUID().uuidString).mov"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    // MARK: - 私有

    private func startTick() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickTimer?.invalidate()
            self.tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.isRecording else { return }
                self.onTick?(self.recordedDuration)
            }
        }
    }

    private func stopTick() {
        DispatchQueue.main.async { [weak self] in
            self?.tickTimer?.invalidate()
            self?.tickTimer = nil
        }
    }

    /// 只交付一次。正常收尾与错误路径都可能触发，必须幂等。
    private func complete(_ result: Result<CaptureResult, Error>) {
        lock.lock()
        if didDeliver {
            lock.unlock()
            return
        }
        didDeliver = true
        _isRecording = false
        startedAt = nil
        let completion = pendingCompletion
        pendingCompletion = nil
        let url = currentURL
        currentURL = nil
        lock.unlock()

        stopTick()

        // 失败时清掉临时文件，避免 tmp 目录越积越多
        if case .failure = result, let url {
            try? FileManager.default.removeItem(at: url)
        }
        if case .failure(let error) = result {
            DebugLog.shared.error("movie", error.localizedDescription)
        }

        guard let completion else { return }
        DispatchQueue.main.async { completion(result) }
    }
}

// MARK: - 录制代理

extension MovieCaptureService: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DebugLog.shared.debug("movie", "系统已开始写入 \(fileURL.lastPathComponent)")
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // ⚠️ 关键：带 error 不等于失败。
        // 只要 AVErrorRecordingSuccessfullyFinishedKey 为 true，文件就是有效的
        // （典型场景：录到时长上限、或切后台被系统停止）。
        if let error = error as NSError? {
            let finishedOK = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if !finishedOK {
                complete(.failure(MovieCaptureError.failed(error.localizedDescription)))
                return
            }
            DebugLog.shared.warn(
                "movie",
                "结束时带了 error，但系统标记为正常完成：\(error.localizedDescription)"
            )
        }

        // 再确认文件确实存在且非空
        let attrs = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard FileManager.default.fileExists(atPath: outputFileURL.path), size > 0 else {
            complete(.failure(MovieCaptureError.nothingToSave))
            return
        }

        DebugLog.shared.info("movie", "录制完成：\(outputFileURL.lastPathComponent)（\(size) 字节）")
        complete(.success(.movie(url: outputFileURL)))
    }
}
