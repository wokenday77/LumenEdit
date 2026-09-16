import SwiftUI

/// 点按对焦指示方框。
///
/// 用 `token` 而不是坐标来驱动动画：在同一个位置连点两次时，坐标没变，
/// `onChange(of: point)` 不会触发，方框就不会重新播动画——手感上会觉得"没反应"。
/// 每次点击让上层递增 token，动画一定重播。
struct FocusIndicatorView: View {

    let point: CGPoint
    let token: Int

    private let side: CGFloat = 76

    @State private var scale: CGFloat = 1.45
    @State private var opacity: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Theme.Palette.focusIndicator, lineWidth: 1.5)
            .frame(width: side, height: side)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(point)
            .allowsHitTesting(false)
            .onAppear { play() }
            .onChange(of: token) { _, _ in play() }
    }

    private func play() {
        // 先大后小地收进来，再淡出——和系统相机的对焦反馈一致
        scale = 1.45
        opacity = 1
        withAnimation(.easeOut(duration: 0.18)) {
            scale = 1.0
        }
        withAnimation(.easeIn(duration: 0.3).delay(0.85)) {
            opacity = 0
        }
    }
}
