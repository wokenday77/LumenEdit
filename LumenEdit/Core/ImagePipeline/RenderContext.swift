import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import UIKit

/// 全局渲染中枢：整个 App 只保留**一个** `CIContext`。
///
/// 为什么必须单例：
/// - `CIContext` 内部持有 Metal 管线状态与中间结果缓存，每个实例都是几百 MB 级别的开销。
///   多个实例并存会导致预览掉帧、内存暴涨。
/// - 修图页实时预览、Live Photo 逐帧处理、视频逐帧导出走同一个 context，
///   才能保证四条链路的渲染结果像素级一致（这正是「取景器看到什么，导出就是什么」的基础）。
///
/// 色彩空间约定见 `ColorSpaces.swift`。这里只强调一点：
/// **工作空间固定用线性 sRGB，不跟随屏幕**，否则同一份参数在不同设备上出来的颜色会不一样。
final class RenderContext {

    /// 唯一的渲染上下文
    let context: CIContext

    /// 工作色彩空间：线性 sRGB（扩展范围，保留 HDR 余量）
    let workingColorSpace: CGColorSpace

    /// 默认输出色彩空间：Display P3（iPhone 拍摄的原始色域）
    let outputColorSpace: CGColorSpace

    /// 实际使用的后端名称，调试浮层会显示。为 "CPU" 说明 Metal 不可用，性能会明显下降。
    let backendName: String

    init() {
        let working = ColorSpaces.extendedLinearSRGB
        workingColorSpace = working
        outputColorSpace = ColorSpaces.displayP3

        if let device = MTLCreateSystemDefaultDevice() {
            backendName = device.name
            context = CIContext(
                mtlDevice: device,
                options: [
                    .workingColorSpace: working,
                    // 输出空间也固定成工作空间，最终写文件时再显式转到目标色彩空间。
                    // 这样中间任何一步都不会被系统偷偷做一次色彩转换。
                    .outputColorSpace: working,
                    .cacheIntermediates: true,
                    .highQualityDownsample: true,
                ]
            )
        } else {
            backendName = "CPU"
            context = CIContext(
                options: [
                    .workingColorSpace: working,
                    .outputColorSpace: working,
                    .cacheIntermediates: true,
                ]
            )
        }

        DebugLog.shared.info("render", "CIContext 初始化完成，后端=\(backendName)")
    }

    // MARK: - 输出

    /// 渲染成 CGImage。
    /// - Parameter colorSpace: 传 nil 表示用默认的 Display P3。
    func makeCGImage(from image: CIImage, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let target = colorSpace ?? outputColorSpace
        let extent = image.extent.isInfinite ? CGRect(x: 0, y: 0, width: 1, height: 1) : image.extent
        guard !extent.isEmpty else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: target)
    }

    /// 渲染成 UIImage，方便直接塞进 SwiftUI 的 Image。
    /// 注意 `UIImage` 只用于**预览缩略图**，导出走 `PhotoExporter` 走 ImageIO，不做二次编码。
    func makeUIImage(from image: CIImage, colorSpace: CGColorSpace? = nil) -> UIImage? {
        guard let cgImage = makeCGImage(from: image, colorSpace: colorSpace) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
