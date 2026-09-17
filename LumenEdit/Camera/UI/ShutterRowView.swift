import SwiftUI

/// 快门排（常驻 · 浮层）：相册缩略图 · 快门（绝对居中）· ⤢ · 风格预览方块。
///
/// 版式对齐网页原型 `.shutter-row`（80px 高，`padding: 0 18`）：
/// ```
/// [ 相册缩略图 50×50 ]      ● 快门 60（绝对居中）      [ ⤢ 36×36 ]  [ 风格方块 50×50 ]
/// ```
///
/// ## 与原型的三处对应
///
/// 1. **快门绝对居中**（原型 `.shutter-center{ position:absolute; left:50% }`）——
///    用 `ZStack` 天然居中实现。原型注释记过一次教训：早年用 flex 默认排布，
///    整排挤在左边、快门偏左，后来才改成绝对居中。
/// 2. **⤢ 不在右侧组里**，绝对定位：`屏幕中线 + 快门视觉半径 + 间距 + 自身半径`。
///    全部用令牌表达 —— 2-5b 把快门放大 1.3 倍时，把半径乘上 scale 即可让 ⤢ 自动右移，
///    与快门同一条动画曲线（原型 `--shutter-scale` 就是这么做的）。
/// 3. **左右两组**：常态下左边只有缩略图、右边只有风格方块。
///    原型里两组还各有一个「前置 / 设置」**镜像按钮**（放大态才出现，
///    与本行图标行的那对同一行为）—— 属 2-5b，这里不放。
///
/// ## 本件的诚实边界
///
/// - **⤢**：先把按钮放对位置；**放大态本体是 2-5b**（`docs/09`），点击先说明
/// - **风格方块**：内层目前是深色占位 —— "当前风格"的选择状态要等模块 #6（场景/风格条），
///   实时渲染要等 P4（`docs/09` 第六节的未决项）；点击先说明
///
/// 录制计时徽标**不在这条排里**：它上浮的位置现在被焦段条占了（2-3 新增），
/// 所以挪到取景器顶部居中（Apple 相机的做法），见 `CameraView` 的顶部 overlay。
struct ShutterRowView: View {

    let thumbnailImage: UIImage?
    let onThumbnailTap: () -> Void

    let isShutterBusy: Bool
    let isRecording: Bool
    let isShutterEnabled: Bool
    let onShutterTap: () -> Void

    /// ⤢ 放大拍摄布局是否开启（2-5b）：开启后本排变高、快门放大、左右两组竖排
    let isZoomOn: Bool
    let onZoomTap: () -> Void
    let onStyleTap: () -> Void
    /// 放大态淡入的镜像按钮 —— 与底部图标行的「前置 / 设置」**同一行为**
    /// （原型：图标行整行让位后由这两个按钮顶上，两者不会同时可见）
    let onFrontCamera: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ZStack {
            // 左右两组：常态各只有一个控件；放大态转**竖排**（镜像按钮在上、控件在下）
            HStack(alignment: .center) {
                leftGroup
                Spacer(minLength: 0)
                rightGroup
            }

            // 快门：ZStack 天然居中
            shutter

            // ⤢：绝对定位（偏移全部由令牌推出，见注释）
            zoomButton
        }
        .padding(.horizontal, Theme.Size.shutterRowHorizontalPadding)
        .frame(
            height: isZoomOn
                ? Theme.Size.shutterRowZoomHeight
                : Theme.Size.shutterRowHeight
        )
    }

    /// 快门视觉缩放：常态 1，放大态 1.3（原型 `--shutter-scale`）
    private var shutterScale: CGFloat {
        isZoomOn ? Theme.Size.shutterZoomScale : 1
    }

    // MARK: - 左右两组

    private var leftGroup: some View {
        VStack(spacing: 0) {
            if isZoomOn {
                mirrorButton(
                    symbol: "arrow.triangle.2.circlepath.camera",
                    label: "前置",
                    action: onFrontCamera
                )
                Spacer(minLength: 0)
            }
            CaptureThumbnail(image: thumbnailImage, onTap: onThumbnailTap)
        }
        .frame(maxHeight: .infinity)
    }

    private var rightGroup: some View {
        VStack(spacing: 0) {
            if isZoomOn {
                mirrorButton(symbol: "gearshape", label: "设置", action: onSettings)
                Spacer(minLength: 0)
            }
            styleThumb
        }
        .frame(maxHeight: .infinity)
    }

    /// 放大态的镜像按钮（50×44，图标 19px 比图标行大一号 —— 这就是"放大"）。
    ///
    /// ⚠️ 用**条件插入**而不是 `opacity(0)`：占位会把 ⤢ 顶进快门的命中区
    ///（原型注释实测踩过：visibility:hidden 会占位，display:none 才不占位）。
    private func mirrorButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Size.toolRowInnerSpacing) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.Size.mirrorGlyphSize, weight: .medium))
                    .foregroundStyle(Theme.Palette.toolRowText)
                Text(label)
                    .font(.system(size: Theme.Size.toolRowLabelSize))
                    .foregroundStyle(Theme.Palette.toolRowLabel)
            }
            .frame(
                width: Theme.Size.mirrorButtonWidth,
                height: Theme.Size.mirrorButtonHeight
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 快门

    private var shutter: some View {
        ShutterButton(
            isBusy: isShutterBusy,
            isRecording: isRecording,
            isEnabled: isShutterEnabled,
            action: onShutterTap
        )
        // 整体缩放（原型 `transform: scale(var(--shutter-scale))`）——
        // 环与内芯一起放大，⤢ 的偏移也乘同一个 scale，三者同步
        .scaleEffect(shutterScale)
    }

    // MARK: - ⤢

    private var zoomButton: some View {
        Button(action: onZoomTap) {
            Image(systemName: isZoomOn
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: Theme.Size.zoomGlyphSize, weight: .semibold))
                .foregroundStyle(isZoomOn ? Theme.Palette.ok : Theme.Palette.secondaryText)
                .frame(width: Theme.Size.zoomButtonSide, height: Theme.Size.zoomButtonSide)
                .background(
                    Circle().fill(
                        isZoomOn ? Theme.Palette.ok.opacity(0.16) : Color.white.opacity(0.09)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // 原型 left: calc(50% + 直径/2 × scale + gap)；ZStack 已把它放在中线上，
        // 所以这里只需要"快门**视觉**半径 + 间距 + 自身半径"—— 快门放大时 ⤢ 自动右移。
        .offset(
            x: Theme.Size.shutterDiameter / 2 * shutterScale
                + Theme.Size.zoomGap
                + Theme.Size.zoomButtonSide / 2
        )
        .accessibilityLabel(isZoomOn ? "退出放大拍摄布局" : "放大拍摄布局")
        .accessibilityAddTraits(isZoomOn ? [.isSelected] : [])
    }

    // MARK: - 风格方块

    /// 风格预览方块：彩色渐变描边 + 深色内层（内层的实时预览等模块 #6 / P4）。
    private var styleThumb: some View {
        Button(action: onStyleTap) {
            RoundedRectangle(cornerRadius: Theme.Size.styleThumbCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: Self.styleGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: Theme.Size.styleThumbSide, height: Theme.Size.styleThumbSide)
                .overlay(
                    RoundedRectangle(
                        cornerRadius: Theme.Size.styleThumbInnerCornerRadius,
                        style: .continuous
                    )
                    .fill(Theme.Palette.styleThumbInner)
                    .padding(Theme.Size.styleThumbBorderPadding)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("场景与风格")
    }

    /// 渐变描边的四段色（原型 `linear-gradient(135deg,#ffd23c,#ff7a59,#8b7bff,#34d058)`），
    /// `135deg` = 左上到右下。单用途装饰色，集中在这一个常量里。
    private static let styleGradient: [Color] = [
        Self.color(0xFFD23C), Self.color(0xFF7A59), Self.color(0x8B7BFF), Self.color(0x34D058)
    ]

    private static func color(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - 快门按钮（从 CameraView 迁入）

/// 快门：白环 + 白芯；录制中内芯变红色圆角方块（"停止录制"的行业标准形态）。
private struct ShutterButton: View {

    let isBusy: Bool
    /// 是否正在录制视频 —— 录制中内芯变红方块，且**必须保持可用**（唯一的停止入口）
    let isRecording: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: Theme.Size.shutterRingWidth)
                    .frame(width: Theme.Size.shutterDiameter, height: Theme.Size.shutterDiameter)

                if isRecording {
                    // 录制中：红色圆角方块 = 点它停止录制。
                    // ⚠️ 尺寸用**独立的录制态令牌**（26pt）而不是拍照态的 46pt ——
                    // 方块的四个角到中心比圆远得多，46pt 会插进白色环带里。
                    RoundedRectangle(
                        cornerRadius: Theme.Size.shutterRecordingCoreRadius,
                        style: .continuous
                    )
                    .fill(Theme.Palette.recording)
                    .frame(
                        width: Theme.Size.shutterRecordingCoreSize,
                        height: Theme.Size.shutterRecordingCoreSize
                    )
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: Theme.Size.shutterCoreSize, height: Theme.Size.shutterCoreSize)
                        // 拍摄/保存时内芯收缩，和系统相机的反馈一致（原型 .66）
                        .scaleEffect(isBusy ? 0.66 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: isBusy)

                    if isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.black)
                    }
                }
            }
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.18), value: isRecording)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
        .accessibilityLabel(isRecording ? "停止录制" : "快门")
    }
}
