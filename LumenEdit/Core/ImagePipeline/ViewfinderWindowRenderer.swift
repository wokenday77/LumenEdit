import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// 窗内自绘渲染器（`docs/26` 刀 1 · ⑥ 视场一致）。
///
/// ## 数据流
/// `CaptureSessionController` 的**常驻** `AVCaptureVideoDataOutput`（420v，文件私有 sink 收帧）
/// → `draw(pixelBuffer:)` → 把**遮幅中心裁切区域** fit 渲染进窗 drawable。
/// 背景预览层与此完全无关（刀 2 才换）—— "窗 == 成片"由
/// 「同源帧 + 渲染/拍照共用同一套裁切纯函数」构造性成立，不依赖任何黑盒缩放。
///
/// ## 纪律（check_swift 第 13 组守着）
/// - 本文件**禁止出现 AVCapture 符号**：窗不认识会话，帧由会话层推过来（o14）。
/// - 渲染只经 `RenderContext` 注入的唯一 `CIContext`；**本文件不得出现 `CIContext(` 构造**（o15）。
/// - 逐帧零分配：几何按「帧尺寸 × 窗尺寸 × 遮幅档」缓存，变化才重算
///   （每帧只有"取 drawable + 提交"两个动作）。
///
/// ## 限帧与丢帧
/// - 软件限 30fps：宿主时钟间隔不足 1/30s 的帧**直接丢弃**（不碰任何帧率弃用 API）。
/// - 会话侧 `alwaysDiscardsLateVideoFrames = true` 双保险（见控制器装配处）。
/// - 预览丢帧不是错误：任何一步不满足（无窗 / 无 drawable / 限帧窗口内）都静默跳过。
final class ViewfinderWindowRenderer {

    // MARK: - 依赖

    private let ciContext: CIContext
    private let outputColorSpace: CGColorSpace

    /// 内部串行化：`draw` 在会话投递队列，`attach/detach/setRatio` 在主线程。
    private let stateLock = NSLock()

    // MARK: - 状态（全部受 stateLock 保护）

    private weak var metalLayer: CAMetalLayer?
    private var maskHeightOverWidth: CGFloat = 4.0 / 3.0
    private var lastPresentedAt: Double = 0
    private var cacheKey: FrameKey?
    private var cropRect = CGRect.zero
    private var drawTransform = CGAffineTransform.identity
    private var drawBounds = CGRect.zero

    /// 几何缓存键：三元组任一变化 → 重算。
    private struct FrameKey: Equatable {
        let frameWidth: Int
        let frameHeight: Int
        let drawableWidth: Int
        let drawableHeight: Int
        let ratioTag: Int
    }

    init(renderContext: RenderContext) {
        self.ciContext = renderContext.context
        self.outputColorSpace = renderContext.outputColorSpace
    }

    // MARK: - UI 侧（主线程）

    /// 窗视图挂载（幂等；SwiftUI 的 make/update 都会调）。
    func attach(_ layer: CAMetalLayer) {
        stateLock.lock()
        metalLayer = layer
        stateLock.unlock()
    }

    /// 窗视图拆除（SwiftUI dismantle）。必须显式调：流还在投帧，弱引用要尽快断开。
    func detach() {
        stateLock.lock()
        metalLayer = nil
        stateLock.unlock()
    }

    /// 遮幅档变化（CameraView 随 `fnRatio` 传入）。几何缓存按键自动失效。
    func setRatio(_ heightOverWidth: CGFloat) {
        stateLock.lock()
        maskHeightOverWidth = heightOverWidth
        stateLock.unlock()
    }

    // MARK: - 会话侧（投递队列）

    /// 逐帧绘制。
    func draw(pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        let layer = metalLayer
        let ratio = maskHeightOverWidth
        stateLock.unlock()

        guard let layer else { return }

        // 软件限帧 30fps（宿主时钟）
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if lastPresentedAt > 0, now - lastPresentedAt < 1.0 / 30.0 { return }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let dw = Int(layer.drawableSize.width)
        let dh = Int(layer.drawableSize.height)
        guard w > 0, h > 0, dw > 0, dh > 0 else { return }

        let key = FrameKey(
            frameWidth: w,
            frameHeight: h,
            drawableWidth: dw,
            drawableHeight: dh,
            ratioTag: Int((ratio * 1000.0).rounded())
        )
        stateLock.lock()
        if cacheKey != key {
            cropRect = Self.windowCropRect(frameWidth: w, frameHeight: h, maskHeightOverWidth: ratio)
            drawTransform = Self.windowTransform(cropRect: cropRect, drawableWidth: dw, drawableHeight: dh)
            drawBounds = CGRect(x: 0, y: 0, width: dw, height: dh)
            cacheKey = key
            DebugLog.shared.debug(
                "viewfinder",
                "窗几何重算：帧 \(w)x\(h) → 窗 \(dw)x\(dh)"
                    + "，遮幅高宽比 \(String(format: "%.3f", ratio))"
                    + "，裁切 \(Int(cropRect.width))x\(Int(cropRect.height))"
            )
        }
        let transform = drawTransform
        let bounds = drawBounds
        let crop = cropRect
        stateLock.unlock()

        guard let drawable = layer.nextDrawable() else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: crop)
            .transformed(by: transform)
        guard let commandBuffer = drawable.commandBuffer else { return }
        ciContext.render(
            image,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: outputColorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastPresentedAt = now
    }

    // MARK: - 几何纯函数（check_swift 第 13 组同式复算；拍照裁切同口径）

    /// 竖排帧（旋转后，宽 < 高）按遮幅的**中心裁切矩形**。
    ///
    /// - `r == 帧高宽比`（4:3 档 vs 3:4 帧）→ 整帧（成片本就同幅）
    /// - `r > 帧高宽比`（16:9 档，窗更瘦长）→ 全高、裁宽 `h / r`
    /// - `r < 帧高宽比`（1:1 档，窗更矮）→ 全宽、裁高 `w * r`
    ///
    /// 拍照裁切（`PhotoCaptureService`，横片像素空间换算后 `pw = min(w, h·r)`）
    /// 用的是同一套比例口径 —— 窗里看到的就是成片。
    static func windowCropRect(frameWidth w: Int, frameHeight h: Int, maskHeightOverWidth r: CGFloat) -> CGRect {
        guard w > 0, h > 0, r > 0 else { return CGRect.zero }
        let fw = CGFloat(w)
        let fh = CGFloat(h)
        let frameRatio = fh / fw
        let cw: CGFloat
        let ch: CGFloat
        if r > frameRatio {
            ch = fh
            cw = fh / r
        } else if r < frameRatio {
            cw = fw
            ch = fw * r
        } else {
            cw = fw
            ch = fh
        }
        return CGRect(x: (fw - cw) / 2, y: (fh - ch) / 2, width: cw, height: ch)
    }

    /// 把裁切矩形映射到 drawable 全幅（含 Metal Y 翻转）。
    ///
    /// 为什么翻转：CI 图像空间原点在**左下**（y 向上），而 `CAMetalLayer` 呈现时纹理
    /// 第 0 行在**顶部** —— 不翻转会上下颠倒。对 CI 空间点的公式：
    /// `x′ = s·(x − minX)`，`y′ = dh − s·(y − minY)`，其中 `s = dw / 裁切宽`。
    /// ⚠️ Mac 首验点：若真机上窗内画面上下颠倒，把 `d` 分量的符号取反即可（一行）。
    static func windowTransform(cropRect: CGRect, drawableWidth dw: Int, drawableHeight dh: Int) -> CGAffineTransform {
        guard cropRect.width > 0, cropRect.height > 0, dw > 0, dh > 0 else { return .identity }
        let s = CGFloat(dw) / cropRect.width
        return CGAffineTransform(
            a: s,
            b: 0,
            c: 0,
            d: -s,
            tx: -cropRect.minX * s,
            ty: CGFloat(dh) + cropRect.minY * s
        )
    }
}
