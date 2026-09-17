import SwiftUI

/// Live Photo 同心圆图标（外圈点阵 + 中环 + 实心内点），纯 SwiftUI 自绘，零资源。
///
/// **为什么要自绘**：系统 SF Symbol 里没有一个跟 Apple 相机 LIVE 角标同款的同心圆，
/// `livephoto` 系列符号的观感与原型的图标语言对不上（原型也不用它）。
/// 整个图形只用圆，没有任何曲线拟合，自绘的代价就是几十行代码。
///
/// ## 几何：全部写在 24 单位的「设计坐标系」里，只有 `size` 一个旋钮
///
/// 数值**逐项对齐网页原型 `prototype/index.html` 的 `ICON_LIVE`**
/// （`viewBox="0 0 24 24"`）：点阵半径 10.5 / 点半径 1.15 / 12 个点（每 30°）/
/// 中环半径 6.6 描边 1.7 / 内点半径 2.4。
///
/// 这一条是照抄项目里踩过的坑：对焦圆盘曾出现"圆盘 340px、刻度半径却是 224px"，
/// 刻度全跑到盘外 —— 根因就是半径分散在两套坐标系里。现在所有半径都在同一个
/// 24 单位坐标系里、统一乘 `size / 24`，改 `size` 一处不会让比例关系脱节。
///
/// ## 颜色：跟父级 `foregroundStyle` 走（对应原型的 `currentColor`）
///
/// 用 `.foreground` 这个 `ShapeStyle`（iOS 13+，"the foreground style in the current
/// context"）而不是写死颜色：同一个图标在黄底角标上是深色、在模式条选中态是白色，
/// 调用处一个 `.foregroundStyle(...)` 就够，不需要给图标加颜色参数。
///
/// ## 角度用 `rotationEffect` 叠加，不调 `sin` / `cos`
///
/// 点的位置不靠三角函数算，而是「先沿正上方偏出轨道半径，再整体旋转 index × 30°」。
/// 两个好处：① 这个文件因此**只需要 `import SwiftUI`** —— `CGFloat` 上的 `cos`/`sin`
/// 重载来自 Foundation/CoreGraphics，多引一个模块就多一处本机无法编译验证的依赖；
/// ② 圆点旋转后仍是圆，不需要反向校正自身朝向。
struct LivePhotoCircleIcon: View {

    /// 图标边长（pt）。默认 18 = 原型里模式条「实况」档的尺寸；
    /// 黄底角标里用的是 14（见 `Theme.Size.liveBadgeIconSize`）。
    var size: CGFloat = 18

    // MARK: - 设计坐标系常量（24 单位空间，与原型 SVG 的 viewBox 一致）

    private static let designSize: CGFloat = 24
    private static let dotCount = 12
    /// 相邻两点的夹角：360 / 12 = 30°
    private static let dotStepDegrees: Double = 360.0 / Double(dotCount)
    /// 点阵所在圆的半径
    private static let dotOrbitRadius: CGFloat = 10.5
    private static let dotRadius: CGFloat = 1.15
    private static let ringRadius: CGFloat = 6.6
    private static let ringWidth: CGFloat = 1.7
    private static let coreRadius: CGFloat = 2.4

    /// 设计坐标系 → 实际尺寸的缩放系数
    private var scale: CGFloat { size / Self.designSize }

    var body: some View {
        ZStack {
            // 外圈点阵：0 号点在正上方，之后顺时针均分（与原型循环的起始角一致）
            ForEach(0..<Self.dotCount, id: \.self) { index in
                Circle()
                    .fill(.foreground)
                    .frame(
                        width: Self.dotRadius * 2 * scale,
                        height: Self.dotRadius * 2 * scale
                    )
                    // offset 不改变布局尺寸，所以下一步的旋转仍以 ZStack 中心为轴
                    .offset(y: -Self.dotOrbitRadius * scale)
                    .rotationEffect(.degrees(Double(index) * Self.dotStepDegrees))
            }

            // 中环：`.stroke` 是**居中描边**（`.strokeBorder` 才是内描边），
            // 与 SVG `stroke` 的语义一致，所以这里必须用 `.stroke`。
            Circle()
                .stroke(.foreground, lineWidth: Self.ringWidth * scale)
                .frame(
                    width: Self.ringRadius * 2 * scale,
                    height: Self.ringRadius * 2 * scale
                )

            // 实心内点
            Circle()
                .fill(.foreground)
                .frame(
                    width: Self.coreRadius * 2 * scale,
                    height: Self.coreRadius * 2 * scale
                )
        }
        .frame(width: size, height: size)
        // 纯装饰图形：不给它自己造无障碍元素，语义交给外层容器
        // （角标容器给「实况已开启」，模式条那一档以可点标签为准）。
        // 否则 VoiceOver 会在角标上多播报一次无意义的图形。
        .accessibilityHidden(true)
    }
}
