import AVFoundation
import SwiftUI
import UIKit

/// 取景预览（UIKit 桥接）。
///
/// SwiftUI 没有 `AVCaptureVideoPreviewLayer` 的等价物，所以这一层必须用
/// `UIViewRepresentable` 包 UIKit。
///
/// **点按对焦的手势也放在这一层**，这是刻意的决定：
/// `captureDevicePointConverted(fromLayerPoint:)` 需要的是**预览层坐标系**里的点，
/// 而预览层只存在于 UIKit 这边。如果在 SwiftUI 用 `onTapGesture` 拿坐标，
/// 还要自己把 SwiftUI 坐标换算到预览层坐标，缩放模式（`resizeAspectFill` 会裁切）
/// 下极易错位。放在 UIKit 层就是一行转换，不会错。
struct PreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    /// 点按回调：同时给出视图坐标（画对焦方框用）与设备归一化坐标（设对焦点用）
    var onFocusTap: (_ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void

    /// 相机控制按钮（硬件快门）触发
    var onHardwareShutter: () -> Void

    /// 保存过程中禁用硬件快门，避免重复触发
    var isShutterEnabled: Bool

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.onFocusTap = onFocusTap
        view.onHardwareShutter = onHardwareShutter
        view.setSession(session)
        view.setShutterEnabled(isShutterEnabled)
        return view
    }

    func updateUIView(_ view: PreviewContainerView, context: Context) {
        view.onFocusTap = onFocusTap
        view.onHardwareShutter = onHardwareShutter
        view.setSession(session)
        view.setShutterEnabled(isShutterEnabled)
    }

    static func dismantleUIView(_ view: PreviewContainerView, coordinator: ()) {
        view.teardown()
    }
}

/// 承载 `AVCaptureVideoPreviewLayer` 的容器视图，同时负责点按手势与硬件快门接入。
final class PreviewContainerView: UIView {

    let previewLayer = AVCaptureVideoPreviewLayer()

    var onFocusTap: ((CGPoint, CGPoint) -> Void)?
    var onHardwareShutter: (() -> Void)?

    private let cameraControlButton = CameraControlButton()
    private var tapRecognizer: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        addGestureRecognizer(tap)
        tapRecognizer = tap

        cameraControlButton.onShutter = { [weak self] in
            self?.onHardwareShutter?()
        }
        cameraControlButton.attach(to: self)
    }

    required init?(coder: NSCoder) {
        fatalError("PreviewContainerView 只支持代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 关掉隐式动画：否则布局变化时预览层会做一段肉眼可见的"飘移"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - 外部接口

    func setSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
            DebugLog.shared.debug("preview", "预览层已绑定会话")
        }
    }

    func setShutterEnabled(_ enabled: Bool) {
        cameraControlButton.isEnabled = enabled
    }

    func teardown() {
        cameraControlButton.detach()
        if let tapRecognizer {
            removeGestureRecognizer(tapRecognizer)
        }
        tapRecognizer = nil
        previewLayer.session = nil
    }

    // MARK: - 手势

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let viewPoint = gesture.location(in: self)
        guard bounds.contains(viewPoint) else { return }

        // 预览层坐标 → 设备归一化坐标（0~1，原点左上）。
        // 这是 AVFoundation 唯一认可的坐标形式，不要自己做线性换算——
        // 在 resizeAspectFill 下画面被裁切过，线性换算一定错。
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)

        DebugLog.shared.debug(
            "preview",
            "点按对焦 view=(\(Int(viewPoint.x)),\(Int(viewPoint.y))) "
            + "device=(\(String(format: "%.2f", devicePoint.x)),\(String(format: "%.2f", devicePoint.y)))"
        )

        onFocusTap?(viewPoint, devicePoint)
    }
}
