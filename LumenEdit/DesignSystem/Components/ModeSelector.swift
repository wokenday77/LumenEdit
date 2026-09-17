import SwiftUI
import UIKit

/// 拍摄模式切换条。
///
/// 版式对齐网页原型 `.mode-tabs` / `.mode-tab`（2026-09-17 第九轮定稿）：
///
/// | 项 | 原型 | 这里 |
/// |---|---|---|
/// | 底色 | **无背景、无描边**（早先的"实心 accent 胶囊"已废弃） | 同 |
/// | 档位内边距 | `padding: 0` | 视觉为 0；命中用的 5pt 透明内边距见下 |
/// | 字号 / 字重 | 11.5 / 选中 700、未选中 600 | 同 |
/// | 颜色 | 选中 `#fff`，未选中 `rgba(255,255,255,.5)` | 同 |
/// | 档间距 | `gap: 10px` | 同（指文字之间的视觉间距） |
/// | 「实况」档 | Live Photo 同心圆图标，不用文字 | 同（复用 `LivePhotoCircleIcon`） |
///
/// **命中区**：原型档位 `padding: 0`，可点区域就只有文字本身（「照片」约 23×26pt），
/// 在真机上偏小。这里改成 `HStack(spacing: 0)` + 每档 `.padding(.horizontal, 档间距/2)`：
/// 相邻两档**文字**的视觉间距仍是 10（与原型完全一致），
/// 但每档可点区域各向外扩 5pt，且**互不重叠**。
/// 纵向同理，把命中高度从 26 提到主行高 30（文字仍垂直居中，观感不变）。
///
/// 未实现的模式**显式置灰并加锁图标**，点击时由上层给出明确提示。
/// 不做"点了没反应"——那是最容易被误判成「相机坏了」的情况。
/// （当前四个模式都已交付，这条分支不会触发；留着是为了以后加模式时不必重新想。）
struct ModeSelector: View {

    let selection: CaptureSessionMode
    let onTap: (CaptureSessionMode) -> Void

    /// 「实况」档图标与文字之间的间距（原型 `.mode-tab{ gap:4px }`）。
    /// 现在每档要么是图标要么是文字，用不到它；留着是为了以后某档做成"图标 + 文字"
    /// 时不必自己拍一个数。
    private static let glyphTextSpacing: CGFloat = 4

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CaptureSessionMode.allCases) { mode in
                item(for: mode)
            }
        }
        // 注意：**没有胶囊底、没有描边**。
        // 原型的模式条是一行无背景文字，选中态靠"白色加粗"表达
        // —— 早先那版"实心 accent 胶囊 + 每档 16pt 内边距"已被原型第九轮改掉，
        // 它也是让顶栏放不下的原因（四档 267.4pt，而两行顶栏只给它 224pt）。
    }

    private func item(for mode: CaptureSessionMode) -> some View {
        let isSelected = mode == selection
        let isAvailable = mode.isImplemented

        return Button {
            onTap(mode)
        } label: {
            HStack(spacing: Self.glyphTextSpacing) {
                if !isAvailable {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                content(for: mode, isSelected: isSelected)
            }
            .foregroundStyle(color(isSelected: isSelected, isAvailable: isAvailable))
            // 视觉高度 26（原型），命中高度 30（主行高）：内容垂直居中，观感不变
            .frame(height: Theme.Size.modeSelectorHeight)
            .padding(.horizontal, Theme.Size.modeSelectorSpacing / 2)
            .frame(height: Theme.Size.topBarRow1Height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: mode, isSelected: isSelected))
    }

    /// 档位内容。
    ///
    /// 「实况」用 Live Photo 同心圆图标 —— 与系统相机的 LIVE 标、顶栏的实况角标
    /// 是同一套图标语言，也与原型一致（原型注释：「不再用「实况」文字」）。
    /// 图标颜色走 `.foreground`，跟着上面的 `foregroundStyle`，所以"选中转白"是自动的。
    @ViewBuilder
    private func content(for mode: CaptureSessionMode, isSelected: Bool) -> some View {
        if mode == .livePhoto {
            LivePhotoCircleIcon(size: Theme.Size.modeSelectorGlyphSize)
        } else {
            Text(mode.displayName)
                .font(Theme.Typography.modeTitle(selected: isSelected))
                .fixedSize()
        }
    }

    private func color(isSelected: Bool, isAvailable: Bool) -> Color {
        if !isAvailable { return Theme.Palette.tertiaryText }
        return isSelected ? Theme.Palette.primaryText : Theme.Palette.modeInactive
    }

    private func accessibilityLabel(for mode: CaptureSessionMode, isSelected: Bool) -> String {
        // 图标化的「实况」档没有文字，标签必须把名字补上，否则 VoiceOver 只会念"按钮"
        var label = mode.displayName
        if !mode.isImplemented { label += "，暂未开放" }
        if isSelected { label += "，已选中" }
        return label
    }
}

/// 左下角相册缩略图按钮
struct CaptureThumbnail: View {

    let image: UIImage?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Theme.Palette.panelElevated
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                }
            }
            .frame(width: Theme.Size.thumbnailSide, height: Theme.Size.thumbnailSide)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开系统相册")
    }
}
