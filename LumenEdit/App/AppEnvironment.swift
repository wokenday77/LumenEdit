import Foundation
import SwiftUI

/// 全局依赖容器。
///
/// 整个 App 只有这一个地方 new 出各层服务，页面通过 `@EnvironmentObject` 拿。
/// 好处：相机页、修图页共用同一个 `CIContext` 和同一个 `AVCaptureSession`，
/// 不会出现「两个页面各持一份 session 互相抢摄像头」这种经典问题。
@MainActor
final class AppEnvironment: ObservableObject {

    // MARK: - 存储键

    private enum StorageKey {
        static let showDebugHUD = "lumen.debug.hud"
        static let showGrid = "lumen.camera.grid"
        static let showTonePreview = "lumen.camera.tonePreview"
    }

    // MARK: - 服务

    let log = DebugLog.shared
    let permissions = PermissionManager()
    let renderContext = RenderContext()
    let thumbnails = ThumbnailCache()
    let session = CaptureSessionController()

    // MARK: - UI 状态

    @Published var showSettings = false

    /// 取景器三分构图线开关（顶栏「网格」图标与设置页共用这一份状态）。
    /// 默认**开** —— 对齐原型：网格图标一开始就是点亮态。
    @Published var showGrid: Bool {
        didSet {
            UserDefaults.standard.set(showGrid, forKey: StorageKey.showGrid)
        }
    }

    /// 「影调预览」：取景器是否实时叠上风格与滤镜（顶栏副行胶囊与设置页共用）。
    /// 默认**开** —— 对齐原型 `tonePreview: true`。
    ///
    /// ⚠️ P4（修图引擎）之前取景器还没有调色链路，所以这个开关**当前不改变画面**。
    /// 状态照常记、也照常持久化 —— 因为它是"成片会怎么显示"的真实设置项，
    /// P4 接上就生效；但 UI 上必须把"现在还不生效"讲清楚
    /// （见 `CameraViewModel.tonePreviewTapped`），不能装作已经生效。
    @Published var showTonePreview: Bool {
        didSet {
            UserDefaults.standard.set(showTonePreview, forKey: StorageKey.showTonePreview)
        }
    }

    /// 屏幕调试图层开关。默认开启——真机侧载时没有 Xcode 控制台，这个浮层是主要排障手段。
    @Published var showDebugHUD: Bool {
        didSet {
            UserDefaults.standard.set(showDebugHUD, forKey: StorageKey.showDebugHUD)
        }
    }

    // MARK: - 生命周期

    init() {
        let defaults = UserDefaults.standard
        self.showDebugHUD = defaults.object(forKey: StorageKey.showDebugHUD) as? Bool ?? true
        self.showGrid = defaults.object(forKey: StorageKey.showGrid) as? Bool ?? true
        self.showTonePreview = defaults.object(forKey: StorageKey.showTonePreview) as? Bool ?? true
        log.info(
            "app",
            "AppEnvironment 初始化完成，hud=\(showDebugHUD) grid=\(showGrid) tone=\(showTonePreview)"
        )
    }

    /// 供设置页导出日志用
    var logFileURL: URL { log.fileURL }

    /// 强制刷新所有权限状态（从系统设置改完权限回来后调用）
    func refreshPermissions() async {
        await permissions.refreshAll()
    }

    /// 把相机页看到的权限问题一次性收集成可读文本，设置页直接展示
    func permissionSummary() -> String {
        """
        相机：\(permissions.camera.displayName)
        麦克风：\(permissions.microphone.displayName)
        相册（写入）：\(permissions.photoLibraryAdd.displayName)
        相册（读取）：\(permissions.photoLibraryRead.displayName)
        """
    }
}
