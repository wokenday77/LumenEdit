import CoreGraphics
import Foundation

/// Live Photo 的两半配对器。
///
/// ## 为什么必须有这个东西
/// 拍一张 Live Photo 会触发**两个互不保证顺序**的 delegate 回调：
///
/// | 回调 | 给什么 |
/// |---|---|
/// | `didFinishProcessingPhoto` | 静态照片的原始字节 |
/// | `didFinishProcessingLivePhotoToMovieFileAt` | 配对视频文件（MOV） |
///
/// 两边都到齐才能提交给相册。**先到的那一半必须等，不能单独保存**——
/// 单独保存的结果就是相册里"一张静态图 + 一段孤立视频"，系统不会把它们认成一对。
///
/// ## 为什么按 uniqueID 存字典而不是单个字段
/// 每次拍摄的 `uniqueID` 由我们自己生成并写进 `AVCapturePhotoSettings.uniqueID`，
/// 系统在 `resolvedSettings` 里原样带回来。按它索引有两个好处：
///   1. 上一次拍摄的迟到回调（uniqueID 对不上）会被自然忽略，不会污染这一次；
///   2. 以后要支持连拍 Live Photo 时不用重构。
///
/// ## 顺带负责临时文件
/// 配对失败或重复提交时，把已经落在临时目录里的 MOV 删掉。
/// 不删的话 tmp 目录会随着失败次数慢慢堆积（真机上是几个 GB 级别的问题）。
///
/// 本类型**不 import AVFoundation**，只依赖 Data / URL / CGSize，可以直接单元测试。
struct LivePhotoAssembler {

    /// 配对成功的一对
    struct Pair {
        let imageData: Data
        let movieURL: URL
        let pixelSize: CGSize
    }

    enum SubmitResult {
        /// 只到一半，在等另一半
        case waiting
        /// 两边到齐
        case ready(Pair)
        /// 重复或多余的回调，已忽略（不算失败）
        case ignored(String)
    }

    enum FinishResult {
        /// 正常：两半都到齐并已交付
        case alreadyDelivered
        /// 异常：拍摄流程结束了却还缺一半（已清理临时文件）
        case incomplete(String)
    }

    private struct Pending {
        var imageData: Data?
        var pixelSize: CGSize = .zero
        var movieURL: URL?
    }

    private var pending: [Int64: Pending] = [:]

    // MARK: - 喂入两半

    mutating func submitImage(uniqueID: Int64, data: Data, pixelSize: CGSize) -> SubmitResult {
        var entry = pending[uniqueID] ?? Pending()

        guard entry.imageData == nil else {
            return .ignored("uniqueID \(uniqueID) 的静态照片已收到过，忽略重复回调")
        }
        guard !data.isEmpty else {
            return .ignored("uniqueID \(uniqueID) 的静态照片数据为空")
        }

        entry.imageData = data
        entry.pixelSize = pixelSize

        if let movieURL = entry.movieURL {
            pending.removeValue(forKey: uniqueID)
            return .ready(Pair(imageData: data, movieURL: movieURL, pixelSize: pixelSize))
        }

        pending[uniqueID] = entry
        return .waiting
    }

    mutating func submitMovie(uniqueID: Int64, url: URL) -> SubmitResult {
        var entry = pending[uniqueID] ?? Pending()

        guard entry.movieURL == nil else {
            // 重复的 MOV 回调：把后来这个删掉，保留先到的
            deleteTemporaryFile(at: url)
            return .ignored("uniqueID \(uniqueID) 的配对视频已收到过，忽略重复回调")
        }

        entry.movieURL = url

        if let data = entry.imageData {
            pending.removeValue(forKey: uniqueID)
            return .ready(Pair(imageData: data, movieURL: url, pixelSize: entry.pixelSize))
        }

        pending[uniqueID] = entry
        return .waiting
    }

    // MARK: - 收尾

    /// 拍摄流程结束（`didFinishCaptureFor`）。
    /// 若此时仍有未配对的条目，说明缺了一半——这是**必须报错**的情况，不能当成功。
    mutating func finish(uniqueID: Int64) -> FinishResult {
        guard let entry = pending.removeValue(forKey: uniqueID) else {
            return .alreadyDelivered
        }

        var missing: [String] = []
        if entry.imageData == nil { missing.append("静态照片") }
        if entry.movieURL == nil { missing.append("配对视频") }

        if let url = entry.movieURL {
            deleteTemporaryFile(at: url)
        }

        return .incomplete("Live Photo 缺少\(missing.joined(separator: "与"))，无法成对提交")
    }

    /// 主动丢弃某次拍摄（取消或出错时调用），并清掉已产生的临时文件
    mutating func discard(uniqueID: Int64) {
        guard let entry = pending.removeValue(forKey: uniqueID) else { return }
        if let url = entry.movieURL {
            deleteTemporaryFile(at: url)
        }
    }

    /// 丢弃全部（例如退出相机页时兜底清理）
    mutating func discardAll() {
        for (_, entry) in pending {
            if let url = entry.movieURL {
                deleteTemporaryFile(at: url)
            }
        }
        pending.removeAll()
    }

    /// 当前未配对的条目数，调试浮层用
    var pendingCount: Int { pending.count }

    // MARK: - 私有

    private func deleteTemporaryFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            DebugLog.shared.debug("live", "已清理临时文件 \(url.lastPathComponent)")
        } catch {
            DebugLog.shared.warn("live", "清理临时文件失败：\(error.localizedDescription)")
        }
    }
}
