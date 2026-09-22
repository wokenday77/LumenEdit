import Combine
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
    let viewfinderRenderer: ViewfinderWindowRenderer
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

    /// session 变更的转发订阅。
    ///
    /// ⚠️ **嵌套的 `ObservableObject` 不会自动向上传播**：视图里读的是
    /// `env.session.state`，但 SwiftUI 只有在 `env` 自己的 `objectWillChange` 发信号时
    /// 才会重算 —— 少了这条转发，`session` 里那些 `@Published` 的变化对视图是**不可见的**。
    ///
    /// 真机后果（2026-09-17）：冷启动后 `env.session.state` 一直停在装配时的 `.idle`
    /// → `isShutterEnabled` 恒 false → **快门完全没反应且呈禁用外观（灰）**，
    /// 直到点一下取景器（触发别的状态变化、顺带让视图重算）才"莫名恢复"。
    private var cancellables = Set<AnyCancellable>()

    init() {
        let defaults = UserDefaults.standard
        self.showDebugHUD = defaults.object(forKey: StorageKey.showDebugHUD) as? Bool ?? true
        self.showGrid = defaults.object(forKey: StorageKey.showGrid) as? Bool ?? true
        self.showTonePreview = defaults.object(forKey: StorageKey.showTonePreview) as? Bool ?? true

        // ⑥ 窗内自绘（docs/26 刀 1）：渲染器由环境**强持有**（复用同一个 RenderContext），
        // 会话层弱引用它收帧 —— UI 挂上窗后自动开始出画面，拆除时自动停画。
        self.viewfinderRenderer = ViewfinderWindowRenderer(renderContext: renderContext)
        session.viewfinderRenderer = viewfinderRenderer

        // 把 session 的变更转发到自己的 objectWillChange（原因见 `cancellables` 的注释）
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

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
