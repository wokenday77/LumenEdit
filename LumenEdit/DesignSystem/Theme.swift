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

        /// Live Photo 角标（黄底同心圆）本体的边长与其中图标的边长。
        ///
        /// 对齐网页原型 `.live-badge`：22×22 黄底圆 + 14×14 图标（图标由
        /// `LivePhotoCircleIcon` 自绘，设计坐标系 24 单位，按 size/24 等比缩放）。
        static let liveBadgeSide: CGFloat = 22
        static let liveBadgeIconSize: CGFloat = 14

        /// 顶栏两侧的占位宽度。
        ///
        /// **左右必须等宽**，模式条的盒中心才等于屏幕中心 —— 这是网页原型
        /// `--tb-side-w` 的做法（原型注释：「把两侧块钉成同宽，盒中心回到屏中心」）。
        /// 取值 = 右侧齿轮按钮宽度（38）。
        ///
        /// 真机实测（iPhone 16 Pro / iOS 26.6，截图像素测量）：
        /// 屏宽 402pt、顶栏可用宽 370pt（402 − 左右各 16）、模式条四档宽 267.4pt。
        /// 中段 = 370 − 38×2 = **294pt**，模式条在它内部居中 → 两侧各余 **13.3pt**；
        /// 于是模式条盒中心 201.0pt = 屏中心，齿轮右端 386pt。
        /// 改造前是 ZStack 覆盖式布局（左侧没有等宽占位），模式条右端落在 334.7pt，
        /// 与右侧图标组起点 306.7pt 重叠 28pt，把「视频」二字盖掉了一半。
        ///
        /// ⚠️ **267.4pt 是"档位为纯文字、内边距 16pt"这个形态下的实测值。**
        /// 下面两种改动都会让它失效，改完必须重新测量并更新本注释：
        ///   1. 任务书模块 #2 会把「实况」档的文字换成 18pt 同心圆图标 → 该档变窄
        ///      （文字约 26pt → 图标 18pt），模式条整体随之变窄；
        ///   2. 真机若遇窄屏机型（如 iPhone SE 375pt 宽 → 可用 343pt），
        ///      343.4pt 的 38+267.4+38 就只剩 -0.4pt，此时才需要收窄档位内边距。
        /// 别把这几个数字当成常量用 —— 它们是"当前形态 + 当前机型"的结论。
        static let topBarSideWidth: CGFloat = 38
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
