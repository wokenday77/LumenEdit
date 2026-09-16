import SwiftUI

/// App 入口。
///
/// 这里只做三件事：装配依赖容器、把 SwiftUI 的生命周期事件转发给相机会话、启动日志系统。
/// 不在这里做任何工程逻辑，方便以后加新的根页面。
@main
struct LumenEditApp: App {

    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 日志系统尽早启动：崩溃前也能在沙盒里留下痕迹（真机无调试器时全靠它）
        DebugLog.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .environmentObject(environment)
                // 相机类 App 全流程深色，避免进设置页时突然变白
                .preferredColorScheme(.dark)
                .task {
                    // 启动即刷新权限状态，页面根据状态决定显示引导页还是取景器
                    await environment.permissions.refreshAll()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 相机必须响应前后台：不进后台停流会被系统强杀，且持续耗电
            switch newPhase {
            case .active:
                environment.session.setAppActive(true)
            case .background:
                environment.session.setAppActive(false)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
