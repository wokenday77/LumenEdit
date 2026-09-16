import UIKit

/// 触感反馈封装。
///
/// 生成器做成静态常量复用：`UIImpactFeedbackGenerator` 每次新建都会有几十毫秒的
/// 预热开销，快门这种要求"按下去立刻震"的场景，复用能明显提升手感。
/// 同时提供统一开关，方便在设置里关掉。
///
/// 这里**故意不加 `@MainActor`**：调用点全部在 SwiftUI 的按钮/手势回调里（本来就在主线程），
/// 加了反而会让 `View` 的非 body 辅助方法（如 `ParameterSlider.resetToDefault()`）
/// 产生一堆不必要的隔离检查问题。
enum Haptics {

    /// 全局开关（后续可接到设置页）
    static var isEnabled = true

    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// 预热：进入相机页时调一次，让第一次快门也有干脆的手感
    static func prepareAll() {
        lightImpact.prepare()
        mediumImpact.prepare()
        rigidImpact.prepare()
        selection.prepare()
    }

    /// 快门
    static func shutter() {
        guard isEnabled else { return }
        rigidImpact.impactOccurred(intensity: 0.85)
    }

    /// 对焦锁定
    static func focus() {
        guard isEnabled else { return }
        lightImpact.impactOccurred(intensity: 0.7)
    }

    /// 滑块刻度
    static func tick() {
        guard isEnabled else { return }
        selection.selectionChanged()
    }

    /// 模式切换
    static func modeChanged() {
        guard isEnabled else { return }
        mediumImpact.impactOccurred(intensity: 0.6)
    }

    /// 保存成功
    static func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    /// 出错
    static func warning() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }
}
