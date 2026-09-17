import Foundation

/// 拍摄模式。
///
/// 每个模式对应一组不同的 session 输出组合（见 `CaptureSessionController.reconfigureOutputsLocked`）：
///   - 照片：`AVCapturePhotoOutput`（Live Photo 关闭）
///   - 实况（Live Photo）：同一个 `AVCapturePhotoOutput`（Live Photo 开启，内部会额外写一段 MOV）
///   - Log 实况：**当前复用录制链路**（`AVCaptureMovieFileOutput`），见下方 `logLive` 的说明
///   - 视频：`AVCaptureMovieFileOutput`
///
/// **为什么按模式动态增删 output，而不是全部常驻**：
/// Live Photo 拍摄与视频录制在底层存在互斥限制。把几种输出全部挂在一个 session 上，
/// 会出现在某个模式下拍摄静默失败、且几乎无法排查的问题。
/// 按模式重配输出的代价是一次 `beginConfiguration`，完全值得。
///
/// ⚠️ **新增 case 时必须全仓排查引用点**：本枚举被 3 处 `switch` 消费
/// （本文件的 4 个属性、`PhotoCaptureService.configure(for:)`、
/// `CaptureSessionController.reconfigureOutputsLocked`），
/// 另外还有 4 处 `==` 比较（切模式的 Live 能力校验、拍摄分派、快门分派、顶栏角标）。
/// 漏掉任何一处 switch 分支都会编译不过，漏掉 `==` 比较则是**静默行为错误**。
enum CaptureSessionMode: String, CaseIterable, Identifiable, Codable {
    case photo
    case livePhoto
    /// Log 实况：拍 Log 视频 → 套 LUT → 导出为实况照片。
    ///
    /// **本阶段（P2 UI 骨架）的语义边界**：模式**可以进入**（与网页原型 `enabled:true` 一致），
    /// 采集与录制走的是与 `.video` 同一条链路（`AVCaptureMovieFileOutput`），
    /// 因此进去之后按快门能正常录、能正常入库到相册，**不会出现"进了模式却什么都干不了"**。
    /// 但"套用 LUT 导出为实况照片"那一步属于 P5，所以本阶段：
    ///   - 进入模式时给出明确提示（`CameraViewModel.modeTapped`）
    ///   - 存盘后的提示语区分模式，不谎称这是实况照片（`CameraViewModel.persist`）
    /// 这样既守住了"UI 不做点了没反应"，也不会给出错误的功能预期。
    case logLive
    case video

    var id: String { rawValue }

    /// 界面文字用「实况」与系统叫法对齐；代码标识符 `livePhoto` 保持不变。
    /// `allCases` 的顺序 = 顶部模式条的显示顺序：照片 / 实况 / Log 实况 / 视频。
    var displayName: String {
        switch self {
        case .photo: return "照片"
        case .livePhoto: return "实况"
        case .logLive: return "Log 实况"
        case .video: return "视频"
        }
    }

    var systemImageName: String {
        switch self {
        case .photo: return "camera"
        case .livePhoto: return "livephoto"
        case .logLive: return "record.circle"
        case .video: return "video"
        }
    }

    /// 是否必须拿到麦克风权限才能真正可用
    var requiresMicrophone: Bool {
        switch self {
        case .photo: return false
        case .livePhoto, .logLive, .video: return true
        }
    }

    /// 该模式是否走「录制」链路（`AVCaptureMovieFileOutput`），而不是一次性拍照。
    ///
    /// 把这条判据收进枚举，是为了让**拍摄分派**只有一处真相：
    /// `CameraViewModel.shutterTapped` 与 `CaptureSessionController.startRecording`
    /// 都问它，而不是各自写一串 `mode == .video || mode == .logLive`
    /// ——那种写法每加一个模式都要改多处，漏一处就是"按了快门没反应"。
    var isRecordingBased: Bool {
        switch self {
        case .photo, .livePhoto: return false
        case .logLive, .video: return true
        }
    }

    /// 该模式是否已经在本阶段实现。
    ///
    /// 进度：P1a 照片闭环 → P1b 第一批 Live Photo 拍摄 → P1b 第二批 视频录制（✅ 已打开）
    /// → P2 `.logLive` 打开入口（录制可用，LUT 导出为实况照片在 P5）。
    /// 未实现的模式在 UI 上**明确置灰并给出原因**，而不是点了没反应
    /// ——点了没反应是最容易被误判成"相机坏了"的情况。
    var isImplemented: Bool {
        switch self {
        case .photo, .livePhoto, .logLive, .video: return true
        }
    }

    /// 未实现时给用户看的原因
    var unavailableReason: String? {
        guard !isImplemented else { return nil }
        return "该模式将在后续阶段交付"
    }
}
