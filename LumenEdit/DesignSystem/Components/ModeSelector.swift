import SwiftUI
import UIKit

/// 拍摄模式切换条。
///
/// 未实现的模式**显式置灰并加锁图标**，点击时由上层给出明确提示。
/// 不做"点了没反应"——那是最容易被误判成「相机坏了」的情况。
struct ModeSelector: View {

    let selection: CaptureSessionMode
    let onTap: (CaptureSessionMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CaptureSessionMode.allCases) { mode in
                item(for: mode)
            }
        }
        .padding(3)
        .background(
            Capsule().fill(Theme.Palette.panel.opacity(0.75))
        )
        .overlay(
            Capsule().stroke(Theme.Palette.stroke, lineWidth: 0.5)
        )
    }

    private func item(for mode: CaptureSessionMode) -> some View {
        let isSelected = mode == selection
        let isAvailable = mode.isImplemented

        return Button {
            onTap(mode)
        } label: {
            HStack(spacing: 4) {
                if !isAvailable {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(mode.displayName)
                    .font(Theme.Typography.modeTitle)
            }
            .foregroundStyle(textColor(isSelected: isSelected, isAvailable: isAvailable))
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.Size.modeSelectorHeight)
            .background(
                Capsule().fill(isSelected && isAvailable
                    ? Theme.Palette.accent
                    : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: mode, isSelected: isSelected))
    }

    private func textColor(isSelected: Bool, isAvailable: Bool) -> Color {
        if !isAvailable { return Theme.Palette.tertiaryText }
        return isSelected ? Color.black : Theme.Palette.primaryText
    }

    private func accessibilityLabel(for mode: CaptureSessionMode, isSelected: Bool) -> String {
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
