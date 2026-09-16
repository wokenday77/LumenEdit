import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 错误

enum LivePhotoCaptureError: LocalizedError {
    case notSupported
    case incompletePair(String)
    case aborted(String)

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "当前设备或当前格式不支持 Live Photo 拍摄"
        case .incompletePair(let reason):
            return reason
        case .aborted(let reason):
            return reason
        }
    }
}

/// Live Photo 拍摄的编排器。
///
/// ## 它在整条链路里的位置
/// `AVCapturePhotoOutput` **只能有一个实例**，所以 Live Photo 不能另起一个输出——
/// 它的两个 delegate 回调必须落在同一个 delegate 对象上。
/// 因此分工是：
///
/// ```
/// PhotoCaptureService（持有 output，是 delegate）
///        │  把两半转发过来
///        ▼
/// LivePhotoCaptureService（本次拍摄的编排 + 设置构造 + 临时文件）
///        │
///        ▼
/// LivePhotoAssembler（纯配对状态机）
/// ```
///
/// 一个实例只负责**一次**拍摄。`PhotoCaptureService` 在发起拍摄前 new 一个，
/// 拍完（无论成功失败）就丢掉。
///
/// ## 三个必须守住的点
/// 1. **`livePhotoMovieFileURL` 每次都要是全新的 URL**。复用同一个路径会让拍摄直接失败，
///    所以这里用 UUID 生成文件名。
/// 2. **`uniqueID` 由我们自己生成并写进 settings**，系统在 `resolvedSettings` 里原样带回。
///    这样"上一次拍摄的迟到回调"能被一眼识别并忽略，不会污染这一次的配对。
/// 3. **两个回调顺序不保证**，谁先到都只是"等"，直到两半齐了才产出结果。
///    先到就存、后到再补的写法，会让相册里出现"静态图 + 孤立视频"，系统不认。
final class LivePhotoCaptureService {

    // MARK: - 本次拍摄的标识

    /// 本次拍摄的 uniqueID，写进 settings 并在回调里核对
    let uniqueID: Int64

    /// 本次拍摄的临时视频路径
    let movieURL: URL

    // MARK: - 内部状态

    private let lock = NSLock()
    private var assembler = LivePhotoAssembler()
    private var didComplete = false
    private let completion: (Result<CaptureResult, Error>) -> Void

    init(uniqueID: Int64, movieURL: URL, completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        self.uniqueID = uniqueID
        self.movieURL = movieURL
        self.completion = completion
    }

    deinit {
        // 兜底：如果一个实例被释放时还留着未配对的临时文件，清掉。
        // 已经配对成功的情况下 assembler 里就没有条目了，不会误删要保存的文件。
        lock.lock()
        assembler.discardAll()
        lock.unlock()
    }

    // MARK: - 静态工具

    /// 设备/当前格式是否支持 Live Photo
    static func isSupported(by output: AVCapturePhotoOutput) -> Bool {
        output.isLivePhotoCaptureSupported
    }

    /// 配对视频的编码格式，优先 HEVC（体积小一半，画质更好）
    static func preferredVideoCodecType(for output: AVCapturePhotoOutput) -> AVVideoCodecType {
        let available = output.availableLivePhotoVideoCodecTypes
        if available.contains(.hevc) { return .hevc }
        if available.contains(.jpeg) { return .jpeg }
        return available.first ?? .hevc
    }

    /// 生成一个本次拍摄专用的临时视频路径。
    /// **每次必须是全新的 URL**——复用同一路径会让拍摄失败。
    static func makeTemporaryMovieURL() -> URL {
        let filename = "lumen-live-\(UUID().uuidString).mov"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    /// 生成 uniqueID。用毫秒时间戳做种子再加计数，保证同一次运行内不重复。
    static func makeUniqueID() -> Int64 {
        uniqueIDLock.lock()
        defer { uniqueIDLock.unlock() }
        uniqueIDCounter += 1
        return uniqueIDCounter
    }

    private static let uniqueIDLock = NSLock()
    private static var uniqueIDCounter = Int64(Date().timeIntervalSince1970 * 1000)

    /// 构造 Live Photo 的拍摄设置。
    ///
    /// 仍然走"复制模板"的路子（`AVCapturePhotoSettings(from:)`），这样编码格式等
    /// 已有配置不会丢；然后再叠上 Live Photo 专有的三个字段。
    static func makeSettings(
        from template: AVCapturePhotoSettings,
        videoCodecType: AVVideoCodecType,
        movieURL: URL,
        uniqueID: Int64
    ) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(from: template)
        settings.uniqueID = uniqueID
        settings.livePhotoMovieFileURL = movieURL
        settings.livePhotoVideoCodecType = videoCodecType
        settings.flashMode = .off
        return settings
    }

    // MARK: - 接入两半回调

    /// 静态照片那一半
    func ingestImage(uniqueID: Int64, data: Data?, pixelSize: CGSize, error: Error?) {
        guard uniqueID == self.uniqueID else {
            DebugLog.shared.debug("live", "忽略过期回调（照片）uniqueID=\(uniqueID)")
            return
        }
        if let error {
            abort(message: "静态照片处理失败：\(error.localizedDescription)")
            return
        }
        guard let data, !data.isEmpty else {
            abort(message: "静态照片数据为空")
            return
        }

        lock.lock()
        let result = assembler.submitImage(uniqueID: uniqueID, data: data, pixelSize: pixelSize)
        lock.unlock()

        handle(result)
    }

    /// 配对视频那一半
    func ingestMovie(uniqueID: Int64, url: URL?, error: Error?) {
        guard uniqueID == self.uniqueID else {
            DebugLog.shared.debug("live", "忽略过期回调（视频）uniqueID=\(uniqueID)")
            return
        }
        if let error {
            abort(message: "配对视频处理失败：\(error.localizedDescription)")
            return
        }
        guard let url else {
            abort(message: "配对视频地址为空")
            return
        }

        lock.lock()
        let result = assembler.submitMovie(uniqueID: uniqueID, url: url)
        lock.unlock()

        handle(result)
    }

    /// 整个拍摄流程结束（`didFinishCaptureFor`）。
    /// 此时若还缺一半，就是**真的失败**了，必须报错而不是当成功。
    func finishCapture(uniqueID: Int64, error: Error?) {
        guard uniqueID == self.uniqueID else { return }

        if let error {
            abort(message: "拍摄失败：\(error.localizedDescription)")
            return
        }

        lock.lock()
        let finishResult = assembler.finish(uniqueID: uniqueID)
        lock.unlock()

        switch finishResult {
        case .alreadyDelivered:
            // 正常路径：两半都到齐并已交付
            break
        case .incomplete(let reason):
            complete(.failure(LivePhotoCaptureError.incompletePair(reason)))
        }
    }

    /// 中途出错，丢弃并清理
    func abort(message: String) {
        lock.lock()
        assembler.discard(uniqueID: uniqueID)
        lock.unlock()

        complete(.failure(LivePhotoCaptureError.aborted(message)))
    }

    // MARK: - 私有

    private func handle(_ result: LivePhotoAssembler.SubmitResult) {
        switch result {
        case .waiting:
            DebugLog.shared.debug("live", "已收到一半，等待另一半（uniqueID \(uniqueID)）")

        case .ignored(let reason):
            DebugLog.shared.warn("live", "配对回调被忽略：\(reason)")

        case .ready(let pair):
            DebugLog.shared.info(
                "live",
                "两半到齐 → 静态照片 \(pair.imageData.count) 字节 + 配对视频 \(pair.movieURL.lastPathComponent)"
            )
            complete(.success(.livePhoto(
                imageData: pair.imageData,
                movieURL: pair.movieURL,
                pixelSize: pair.pixelSize
            )))
        }
    }

    /// 只交付一次。两个回调路径 + 收尾路径都可能触发，必须幂等。
    private func complete(_ result: Result<CaptureResult, Error>) {
        lock.lock()
        if didComplete {
            lock.unlock()
            return
        }
        didComplete = true
        lock.unlock()

        if case .failure(let error) = result {
            DebugLog.shared.error("live", error.localizedDescription)
        }

        DispatchQueue.main.async { [completion] in
            completion(result)
        }
    }
}
