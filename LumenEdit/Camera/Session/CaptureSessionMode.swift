import Foundation

/// 拍摄模式。
///
/// 每个模式对应一组不同的 session 输出组合（见 `CaptureSessionController.applyOutputs`）：
///   - 照片：`AVCapturePhotoOutput`（Live Photo 关闭）
///   - Live Photo：同一个 `AVCapturePhotoOutput`（Live Photo 开启，内部会额外写一段 MOV）
///   - 视频：`AVCaptureMovieFileOutput`
///
/// **为什么按模式动态增删 output，而不是全部常驻**：
/// Live Photo 拍摄与视频录制在底层存在互斥限制。把三种输出全部挂在一个 session 上，
/// 会出现在某个模式下拍摄静默失败、且几乎无法排查的问题。
/// 按模式重配输出的代价是一次 `beginConfiguration`，完全值得。
enum CaptureSessionMode: String, CaseIterable, Identifiable, Codable {
    case photo
    case livePhoto
    case video

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .photo: return "照片"
        case .livePhoto: return "Live"
        case .video: return "视频"
        }
    }

    var systemImageName: String {
        switch self {
        case .photo: return "camera"
        case .livePhoto: return "livephoto"
        case .video: return "video"
        }
    }

    /// 是否必须拿到麦克风权限才能真正可用
    var requiresMicrophone: Bool {
        switch self {
        case .photo: return false
        case .livePhoto, .video: return true
        }
    }

    /// 该模式是否已经在本阶段实现。
    ///
    /// 进度：P1a 照片闭环 → P1b 第一批 Live Photo 拍摄 → P1b 第二批 视频录制（✅ 已打开）。
    /// 未实现的模式在 UI 上**明确置灰并给出原因**，而不是点了没反应
    /// ——点了没反应是最容易被误判成"相机坏了"的情况。
    var isImplemented: Bool {
        switch self {
        case .photo, .livePhoto, .video: return true
        }
    }

    /// 未实现时给用户看的原因
    var unavailableReason: String? {
        guard !isImplemented else { return nil }
        return "该模式将在后续阶段交付"
    }
}
