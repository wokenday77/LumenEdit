import Foundation
import ImageIO
import Photos

// MARK: - 错误

enum PhotoLibraryError: LocalizedError {
    case notAuthorized
    case emptyData
    case missingFile(URL)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "相册写入权限未授权"
        case .emptyData:
            return "拍摄数据为空，无法保存"
        case .missingFile(let url):
            return "待保存的文件不存在：\(url.lastPathComponent)"
        case .saveFailed(let message):
            return "保存到相册失败：\(message)"
        }
    }
}

// MARK: - 统一入库口

/// 相册入库的唯一出口。照片、视频、Live Photo 配对都从这里走。
///
/// 为什么统一到一个地方：
/// - 权限判断、错误映射、文件名生成只写一遍；
/// - Live Photo 必须"成对提交"这条规则集中在这里，不会被某个页面绕过；
/// - 以后加"存到指定相簿"只需改这一个文件。
enum PhotoLibraryWriter {

    // MARK: 照片

    /// 保存一张照片（HEIC/JPEG 原始字节直存，不做二次编码）。
    /// - Returns: 新资源的 localIdentifier，供后续跳转定位
    @discardableResult
    static func savePhotoData(_ data: Data) async throws -> String? {
        guard !data.isEmpty else { throw PhotoLibraryError.emptyData }
        try await ensureAddAuthorization()

        let options = PHAssetResourceCreationOptions()
        options.originalFilename = makeFileName(forImageData: data)

        let box = IdentifierBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: options)
                box.value = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }

        DebugLog.shared.info("library", "照片已入库 id=\(box.value ?? "nil") size=\(data.count)B")
        return box.value
    }

    // MARK: 视频

    /// 保存一段视频（MOV/MP4 文件搬进相册，保留原始音轨与编码）。
    @discardableResult
    static func saveVideoFile(at url: URL) async throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PhotoLibraryError.missingFile(url)
        }
        try await ensureAddAuthorization()

        let options = PHAssetResourceCreationOptions()
        options.originalFilename = "LUMEN_\(timestampText()).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)"
        // 入库后原始临时文件由调用方负责清理
        options.shouldMoveFile = false

        let box = IdentifierBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: options)
                box.value = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }

        DebugLog.shared.info("library", "视频已入库 id=\(box.value ?? "nil")")
        return box.value
    }

    // MARK: Live Photo

    /// 保存一对 Live Photo（照片 + 配对视频）。
    ///
    /// **必须在同一个 `PHAssetCreationRequest` 里同时添加两个资源。**
    /// 拆成两次 `performChanges` 会出现"先存了照片、再补视频"的结果——
    /// 系统里会变成一张普通静态图 + 一段孤立视频，而不是 Live Photo。
    /// 这是 Live Photo 落盘最常见的坑，所以这个函数只暴露"成对提交"这一种用法。
    @discardableResult
    static func saveLivePhotoPair(imageData: Data, movieURL: URL) async throws -> String? {
        guard !imageData.isEmpty else { throw PhotoLibraryError.emptyData }
        guard FileManager.default.fileExists(atPath: movieURL.path) else {
            throw PhotoLibraryError.missingFile(movieURL)
        }
        try await ensureAddAuthorization()

        let imageOptions = PHAssetResourceCreationOptions()
        imageOptions.originalFilename = makeFileName(forImageData: imageData)

        let videoOptions = PHAssetResourceCreationOptions()
        videoOptions.originalFilename = "LUMEN_\(timestampText()).mov"
        videoOptions.shouldMoveFile = false

        let box = IdentifierBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: imageData, options: imageOptions)
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: videoOptions)
                box.value = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }

        DebugLog.shared.info("library", "Live Photo 成对入库 id=\(box.value ?? "nil")")
        return box.value
    }

    // MARK: - 私有

    /// 只在需要写入时申请 `.addOnly` 权限——比一上来要完整相册权限的拒绝率低得多。
    private static func ensureAddAuthorization() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let newStatus: PHAuthorizationStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
            }
            if newStatus == .authorized || newStatus == .limited {
                return
            }
            throw PhotoLibraryError.notAuthorized
        case .denied, .restricted:
            throw PhotoLibraryError.notAuthorized
        @unknown default:
            throw PhotoLibraryError.notAuthorized
        }
    }

    /// 从图片字节的类型推出扩展名，给相册里一个像样的文件名。
    private static func makeFileName(forImageData data: Data) -> String {
        var ext = "jpg"
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let typeRef = CGImageSourceGetType(source) {
            switch typeRef as String {
            case "public.heic", "public.heif":
                ext = "heic"
            case "public.jpeg":
                ext = "jpg"
            default:
                ext = "img"
            }
        }
        return "LUMEN_\(timestampText()).\(ext)"
    }

    private static func timestampText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter.string(from: Date())
    }

    /// 在 `performChanges` 的变更块里回写值用的引用盒子。
    /// 变更块和完成回调不在同一线程，用引用类型才能把 placeholder 带出来。
    private final class IdentifierBox {
        var value: String?
    }
}
