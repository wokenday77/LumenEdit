import ImageIO
import Photos
import UIKit

/// 缩略图缓存。
///
/// 两个数据来源，按优先级：
///   1. **刚拍到的照片**——直接从 `AVCapturePhoto` 的原始字节降采样生成缩略图，
///      不依赖相册读取权限，也不做整图解码（4800 万像素整图解码要几百 MB 内存）。
///   2. **相册里最新一张**——只有拿到相册读取权限时才有；用于冷启动时把缩略图填上。
///
/// 降采样这一条特别重要：`CGImageSourceCreateThumbnailAtIndex` 配合
/// `kCGImageSourceThumbnailMaxPixelSize` 是"不解码原图就出小图"的标准做法，
/// 直接 `UIImage(data:)` 会先把整张图解进内存。
@MainActor
final class ThumbnailCache: ObservableObject {

    /// 左下角缩略图当前展示的图。nil 表示还没有内容（尚未拍照且无相册权限）。
    @Published private(set) var lastThumbnail: UIImage?

    /// 最近一次入库资源的本地标识，P3 相册页会用它做跳转定位
    private(set) var lastSavedLocalIdentifier: String?

    private let cache = NSCache<NSString, UIImage>()
    private let imageManager = PHCachingImageManager()

    init() {
        cache.countLimit = 120
    }

    // MARK: - 写入

    /// 用刚拍摄的照片原始数据生成缩略图
    func rememberCapturedPhoto(data: Data, maxPixelSize: CGFloat = 240) {
        guard let image = Self.downsample(data: data, maxPixelSize: maxPixelSize) else {
            DebugLog.shared.warn("thumb", "缩略图生成失败，原始数据 \(data.count) 字节")
            return
        }
        lastThumbnail = image
        DebugLog.shared.debug("thumb", "缩略图已更新（照片），\(Int(image.size.width))x\(Int(image.size.height))")
    }

    /// 用本地文件（视频等）生成缩略图
    func rememberCapturedFile(at url: URL, maxPixelSize: CGFloat = 240) {
        guard let image = Self.downsample(url: url, maxPixelSize: maxPixelSize) else {
            DebugLog.shared.debug("thumb", "缩略图生成失败（非图片文件），跳过：\(url.lastPathComponent)")
            return
        }
        lastThumbnail = image
    }

    func rememberSavedIdentifier(_ identifier: String?) {
        lastSavedLocalIdentifier = identifier
    }

    // MARK: - 相册读取（需要读取权限）

    /// 取相册里最新一张的缩略图。无权限时静默返回 nil，由调用方决定怎么展示。
    func refreshFromLibraryIfAuthorized(size: CGSize = CGSize(width: 240, height: 240)) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            DebugLog.shared.debug("thumb", "无相册读取权限，跳过最新照片缩略图")
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1

        guard let asset = PHAsset.fetchAssets(with: options).firstObject else { return }

        let key = asset.localIdentifier as NSString
        if let cached = cache.object(forKey: key) {
            lastThumbnail = cached
            return
        }

        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = false
        // 用 highQualityFormat：它保证回调只被调用**一次**，配合 continuation 最安全。
        // 若用 fastFormat，系统会先给一张模糊图再给最终图，回调两次，
        // 一旦在第一次就 resume，第二次就会触发 "continuation resumed twice" 崩溃。
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .fast
        requestOptions.isNetworkAccessAllowed = false

        let image: UIImage? = await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: requestOptions
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }

        if let image {
            cache.setObject(image, forKey: key)
            lastThumbnail = image
        }
    }

    // MARK: - 降采样实现

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return makeThumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    private static func downsample(url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return makeThumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    private static func makeThumbnail(source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 自动应用 EXIF 方向
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
