import AVFoundation
import UIKit

/// 相机控制按钮接入（iPhone 16 及之后的侧边快门）。
///
/// 用 `AVCaptureEventInteraction` 接管「全按」——它遵循 `UIInteraction` 协议，
/// 通过 `view.addInteraction(_:)` 挂到承载预览的 UIView 上就能收到事件，
/// **不需要任何机型判断**。
///
/// ## 几点必须说清楚的事
/// 1. **只在 App 处于前台时有效。** 锁屏状态下按相机按钮直接唤起第三方相机的能力
///    受系统限制，本 App 不做这件事，也不去尝试绕过。
/// 2. **没有相机按钮的设备上它不会触发**，属于优雅降级。**不要**去判断机型名称——
///    那会让新机型上市时需要改代码。
/// 3. 「轻按弹出系统滑杆」（Light Press）走的是 iOS 18 的 `AVCaptureControl` 体系，
///    和这里的全按快门是两套完全不同的机制，P2 再做。
/// 4. 启停**由本类自己管理**，不依赖系统对象的 `isEnabled` 属性（该属性在不同 SDK
///    版本上的可用性我没有条件在本机编译验证）。交互对象始终挂着，
///    禁用时在回调里直接 return——行为等价，但不会因为 API 差异编译失败。
/// 5. `AVCaptureEventInteraction` 的初始化签名以 Xcode 16 SDK 为准，
///    这里用的是带 `primaryAction:` 标签的显式形式，避免重载歧义。
final class CameraControlButton {

    /// 全按触发（相当于按下快门键）
    var onShutter: (() -> Void)?

    /// 禁用时不响应任何事件（保存过程中用它挡住重复触发）
    var isEnabled: Bool = true

    private var interaction: AVCaptureEventInteraction?
    private weak var hostView: UIView?

    /// 挂到承载预览的视图上。重复调用是安全的（只挂一次）。
    func attach(to view: UIView) {
        guard interaction == nil else { return }

        let interaction = AVCaptureEventInteraction(primaryAction: { [weak self] event in
            self?.handle(event)
        })
        view.addInteraction(interaction)
        self.interaction = interaction
        self.hostView = view

        DebugLog.shared.info("hardware", "相机控制按钮交互已挂载（无该按钮的设备上不会触发）")
    }

    func detach() {
        if let interaction, let hostView {
            hostView.removeInteraction(interaction)
        }
        interaction = nil
        hostView = nil
    }

    private func handle(_ event: AVCaptureEvent) {
        guard isEnabled else { return }

        switch event.phase {
        case .began:
            // 只在按下瞬间触发一次；.ended / .cancelled 不重复触发
            DebugLog.shared.info("hardware", "相机控制按钮全按")
            onShutter?()
        case .ended, .cancelled:
            break
        @unknown default:
            break
        }
    }
}
