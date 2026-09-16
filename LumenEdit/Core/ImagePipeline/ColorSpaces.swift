import CoreGraphics
import Foundation

/// 色彩空间约定（P4 修图引擎与导出的唯一依据）。
///
/// **为什么现在就要定死**：iPhone 拍出来的照片是 Display P3 色域，而 Core Image 的默认
/// 工作空间是线性 sRGB。不做约定的话会出现两个经典问题：
///   1. 预览看着正常，导出后颜色"发灰"或"过饱和"；
///   2. 同一份调整参数，在不同设备/不同链路（照片 vs Live Photo vs 视频）下结果不一致。
///
/// 本项目的约定：
///   - **工作空间**：`extendedLinearSRGB`（线性、范围扩展），所有滤镜与调整都在这个空间里算；
///   - **输入**：保留原图自带的色彩配置，交给 Core Image 自动转到工作空间，不做手工假定；
///   - **输出**：默认写回 `displayP3`（保住拍摄时的色域）；用户显式选择"兼容性优先"时写 `sRGB`。
///
/// 关键点：**中间任何一步都不要再手动转色彩空间**。转换只发生在"进入工作空间"和
/// "写出文件"这两端，中间转来转去只会累积误差。
enum ColorSpaces {

    /// 线性 sRGB，扩展范围。作为 Core Image 的工作空间。
    static let extendedLinearSRGB: CGColorSpace =
        CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 标准 sRGB。用于"兼容性优先"的导出，以及需要严格 sRGB 的第三方场景。
    static let sRGB: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Display P3。iPhone 相机的原生色域，默认输出目标。
    static let displayP3: CGColorSpace =
        CGColorSpace(name: CGColorSpace.displayP3) ?? sRGB

    // MARK: - 选择

    /// 导出时的目标色彩空间。
    /// - Parameter preferWideGamut: `true` 写 P3（默认，保住色域）；`false` 写 sRGB（兼容性最好）。
    static func output(preferWideGamut: Bool) -> CGColorSpace {
        preferWideGamut ? displayP3 : sRGB
    }

    // MARK: - 诊断

    static func describe(_ space: CGColorSpace) -> String {
        guard let name = space.name else { return "unknown" }
        return name as String
    }

    static func isWideGamut(_ space: CGColorSpace) -> Bool {
        space === displayP3 || describe(space).lowercased().contains("p3")
    }
}
