import SwiftUI

/// 取景器三分构图线（顶栏「网格」图标控制开关）。
///
/// 只画线，**不接收触摸** —— 取景器上的"点按任意处对焦"必须照常穿透过去
/// （`.allowsHitTesting(false)`，与实况角标同一处理）。
///
/// 线用 `Path` + `.stroke` 直接画，不用 `Divider`/`Rectangle` 去拼：
/// 后者在等分位置会因为自身的对齐方式产生半像素偏移，四条线的粗细看起来会不一致。
///
/// 粗细走 `Theme.Size.gridLineWidth`（**1.0pt**，2026-09-17 由 0.5 提上来 ——
/// 真机反馈"网格线太细"：0.5pt 在 3x 屏上只有 1.5 物理像素，被抗锯齿摊淡了）。
struct GridOverlayView: View {

    /// 等分数。3 = 三分构图线（相机 App 的行业标准）。
    private static let divisions = 3
    /// 线的透明度：在明亮画面上要看得见、在暗画面上又不能抢戏。
    private static let lineOpacity = 0.28

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for index in 1..<Self.divisions {
                    let ratio = CGFloat(index) / CGFloat(Self.divisions)

                    let x = geometry.size.width * ratio
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))

                    let y = geometry.size.height * ratio
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(
                Theme.Palette.primaryText.opacity(Self.lineOpacity),
                lineWidth: Theme.Size.gridLineWidth
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
