import CoreGraphics
import Foundation

/// 一次拍摄的统一结果。
///
/// 三种采集路径（照片 / Live Photo / 视频）的产物形态完全不同，
/// 但上层（保存、缩略图、日志）需要一套统一接口，所以在这里做归一。
enum CaptureResult {

    /// 照片：相机已经编码好的原始字节（HEIC 或 JPEG），
    /// **不要在这里解码再编码**——直接交给 `PhotoLibraryWriter` 入库，画质无损且最快。
    case photo(data: Data, pixelSize: CGSize)

    /// Live Photo：照片字节 + 配对视频文件（两者必须成对入库，见 `PhotoLibraryWriter`）
    case livePhoto(imageData: Data, movieURL: URL, pixelSize: CGSize)

    /// 视频：录制完成的本地文件
    case movie(url: URL)

    // MARK: - 归一化访问

    var kindText: String {
        switch self {
        case .photo: return "照片"
        case .livePhoto: return "Live Photo"
        case .movie: return "视频"
        }
    }

    var pixelSizeText: String {
        switch self {
        case .photo(_, let size):
            return "\(Int(size.width))x\(Int(size.height))"
        case .livePhoto(_, _, let size):
            return "\(Int(size.width))x\(Int(size.height))"
        case .movie(let url):
            return url.pathExtension.uppercased()
        }
    }

    /// 用于生成缩略图的主数据。视频没有图片数据，返回 nil（由调用方走文件路径分支）。
    var thumbnailSourceData: Data? {
        switch self {
        case .photo(let data, _):
            return data
        case .livePhoto(let imageData, _, _):
            return imageData
        case .movie:
            return nil
        }
    }
}
