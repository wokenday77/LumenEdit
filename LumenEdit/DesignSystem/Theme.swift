import SwiftUI

/// 设计令牌。
///
/// 相机页与修图页都是深色，颜色集中在这里定义，避免各页面各写一套
/// `Color.black.opacity(x)`，改一次要翻遍全工程。
enum Theme {

    // MARK: - 颜色

    enum Palette {
        /// 取景器底色
        static let canvas = Color.black
        /// 浮层面板
        static let panel = Color(white: 0.09)
        /// 面板上的次级按钮/胶囊
        static let panelElevated = Color(white: 0.16)
        /// 分隔线与描边
        static let stroke = Color.white.opacity(0.14)
        static let primaryText = Color.white
        static let secondaryText = Color.white.opacity(0.62)
        static let tertiaryText = Color.white.opacity(0.38)
        /// 主强调色（与 AccentColor 保持一致的金黄）
        static let accent = Color(red: 0.949, green: 0.686, blue: 0.235)
        static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
        /// 对焦方框
        static let focusIndicator = Color(red: 1.0, green: 0.83, blue: 0.25)
        /// 录制指示
        static let recording = Color(red: 1.0, green: 0.23, blue: 0.19)
    }

    // MARK: - 间距

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 34
    }

    // MARK: - 圆角

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let pill: CGFloat = 999
    }

    // MARK: - 尺寸

    enum Size {
        static let shutterDiameter: CGFloat = 74
        static let shutterRingWidth: CGFloat = 5
        static let thumbnailSide: CGFloat = 52
        static let modeSelectorHeight: CGFloat = 34
        static let topBarHeight: CGFloat = 46
    }

    // MARK: - 字体

    enum Typography {
        static let value = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let label = Font.system(size: 11, weight: .medium, design: .rounded)
        static let modeTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let toast = Font.system(size: 13, weight: .medium, design: .rounded)
        static let mono = Font.system(size: 11, design: .monospaced)
    }
}
