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
    }

    // MARK: - 服务

    let log = DebugLog.shared
    let permissions = PermissionManager()
    let renderContext = RenderContext()
    let thumbnails = ThumbnailCache()
    let session = CaptureSessionController()

    // MARK: - UI 状态

    @Published var showSettings = false

    /// 屏幕调试图层开关。默认开启——真机侧载时没有 Xcode 控制台，这个浮层是主要排障手段。
    @Published var showDebugHUD: Bool {
        didSet {
            UserDefaults.standard.set(showDebugHUD, forKey: StorageKey.showDebugHUD)
        }
    }

    // MARK: - 生命周期

    init() {
        self.showDebugHUD = UserDefaults.standard.object(forKey: StorageKey.showDebugHUD) as? Bool ?? true
        log.info("app", "AppEnvironment 初始化完成，hud=\(showDebugHUD)")
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
