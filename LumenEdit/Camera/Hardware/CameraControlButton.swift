import AVFoundation
import AVKit
import UIKit

/// 相机控制按钮接入（iPhone 16 及之后的侧边快门）。
///
/// ## ⚠️ 归属框架（2026-09-16 第一次云端 CI 编译才发现，已修正）
/// `AVCaptureEventInteraction` 与 `AVCaptureEvent` **属于 AVKit，不属于 AVFoundation**。
/// 官方文档路径是 `developer.apple.com/documentation/AVKit/AVCaptureEventInteraction`。
/// 只 `import AVFoundation` 会得到 `cannot find type 'AVCaptureEventInteraction' in scope`。
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
/// 4. 启停**同时做两件事**：把开关同步给系统的 `isEnabled`，并在回调里 return。
///    官方文档已确认 `isEnabled` 存在，且明确写了：置为 false 会**恢复系统按钮的默认行为**——
///    所以只靠回调 return 是不够的，系统会认为按钮已被 App 接管却什么都不做。
/// 5. 初始化签名**只有** `init(handler:)` 与 `init(primary:secondary:)` 两种，
///    **不存在 `primaryAction:` 标签**（那是 SwiftUI `onCameraCaptureEvent` 的参数名）。
final class CameraControlButton {

    /// 全按触发（相当于按下快门键）
    var onShutter: (() -> Void)?

    /// 禁用时不响应任何事件（保存过程中用它挡住重复触发）
    var isEnabled: Bool = true {
        didSet { interaction?.isEnabled = isEnabled }
    }

    private var interaction: AVCaptureEventInteraction?
    private weak var hostView: UIView?

    /// 挂到承载预览的视图上。重复调用是安全的（只挂一次）。
    func attach(to view: UIView) {
        guard interaction == nil else { return }

        let interaction = AVCaptureEventInteraction(handler: { [weak self] event in
            self?.handle(event)
        })
        interaction.isEnabled = isEnabled
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
