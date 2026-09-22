import Metal
import QuartzCore
import SwiftUI
import UIKit

/// 窗内自绘视图（`docs/26` 刀 1）：遮幅开口处的 Metal 表面。
///
/// ## 为什么是独立一块 UIView + CAMetalLayer
/// 帧由会话层推给 `ViewfinderWindowRenderer`、渲染进本视图的 layer ——
/// 本视图**不认识会话**：整个文件不得出现 AVCapture / AVFoundation 符号（o14）。
///
/// - `isUserInteractionEnabled = false`：点按穿透给下层预览容器
///   （批六 ③ 点按对焦链路零改动 —— 预览层和它的坐标换算原样保留）。
/// - `isOpaque` + 黑底：首帧未到时与预览层黑底一致，不会"闪白"。
/// - 帧停止投递（打断 / 退后台）时 Metal 保持最后一帧 —— 冻结而不是黑屏；
///   恢复后新帧自动跟上（Mac 验证项：打断自愈，对照探针"重挂救不回"——自绘路径无此问题）。
/// - 窗的**矩形几何**在 CameraView 侧统一算（`FrameRatioGeometry.windowRect`，
///   与黑边遮幅同一个函数）；本视图只负责把 Metal 表面铺满给定矩形。
struct ViewfinderWindowView: UIViewRepresentable {

    /// 当前遮幅档（喂给渲染器做中心裁切；随 `fnRatio` 变化自动失效几何缓存）
    let ratio: FrameRatio
    let renderer: ViewfinderWindowRenderer

    func makeUIView(context: Context) -> WindowHostView {
        let view = WindowHostView()
        bind(view)
        return view
    }

    func updateUIView(_ view: WindowHostView, context: Context) {
        bind(view)
    }

    static func dismantleUIView(_ view: WindowHostView, coordinator: ()) {
        view.renderer = nil
        view.detachFromRenderer()
    }

    private func bind(_ view: WindowHostView) {
        view.renderer = renderer
        renderer.attach(view.metalLayer)
        renderer.setRatio(ratio.heightOverWidth)
    }
}

/// 承载 `CAMetalLayer` 的宿主视图。
final class WindowHostView: UIView {

    let metalLayer = CAMetalLayer()
    fileprivate weak var renderer: ViewfinderWindowRenderer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        metalLayer.isOpaque = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("WindowHostView 只支持代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 关掉隐式动画：与预览层同一套处理（见 PreviewContainerView.layoutSubviews）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }

    fileprivate func detachFromRenderer() {
        renderer?.detach()
    }
}
