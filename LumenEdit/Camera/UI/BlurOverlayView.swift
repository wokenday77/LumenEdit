import SwiftUI

/// 模糊转场浮层（物理架构 · `docs/20` 第三节）：盖在预览层上的 `UIVisualEffectView`。
///
/// ## 用途（预检 ⑧⑨）
///
/// 掩盖物理设备切换瞬间的预览黑屏 / 参数跳变 —— **顺序触发**：
/// `isLensSwitching = true` → 本浮层淡入（0.15s）→ **淡入完成回调里才真正换设备**
/// → 完成后 `isLensSwitching = false` → 淡出（0.25s）。模糊先完全盖住画面，
/// 切换快慢都不影响观感。
///
/// ## 实现说明
///
/// - `UIVisualEffectView` 的 `effect` 强度**不能直接动画**（UIKit 限制）——
///   标准做法是 SwiftUI 侧用 `.opacity` 驱动整个浮层的淡入淡出（本视图自身不做动画）。
/// - `isUserInteractionEnabled = false`：转场期间**点按对焦照常穿透**（模糊只是视觉）。
/// - **峰值段糊的可能是黑**（remove→add 之间预览黑几帧）—— "清晰→糊→黑一瞬→糊→清晰"
///   是预期行为不是 bug（`docs/20` 3.2 / 第五节验收口径）。
struct BlurOverlayView: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        // 转场是纯视觉：不接收触摸（点按对焦 / 其它手势照常穿透）
        container.isUserInteractionEnabled = false

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        blur.frame = container.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(blur)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 透明度由 SwiftUI 修饰链（.opacity）驱动，这里无需更新
    }
}
