import SwiftUI
import UIKit

/// 拍摄模式切换条。
///
/// 版式对齐网页原型 `.mode-tabs` / `.mode-tab`（2026-09-17 第九轮定稿），
/// 并在同日按"真机可用性"复核过一轮（字号 / 间距 / 触控热区）：
///
/// | 项 | 原型 | 这里 |
/// |---|---|---|
/// | 底色 | **无背景、无描边** | 同 |
/// | 字号 / 字重 | 11.5 / 选中 700、未选中 600 | **13**（窄屏 12）／字重同原型 |
/// | 颜色 | 选中 `#fff`，未选中 `rgba(255,255,255,.5)` | 同 |
/// | 档间距 | `gap: 10px` + 档位 `padding: 0` | **间距改由热区内边距产生**（18，窄屏 12） |
/// | 命中区 | 只有文字本身（约 23×26pt） | **44×44**（HIG 下限） |
/// | 「实况」档 | Live Photo 同心圆图标 | 同，图标 18 → **20**（配 13pt 文字） |
///
/// ## 为什么不照抄原型的写法
///
/// 原型是 CSS 稿，`padding: 0` 的档位在真机上可点区域只剩文字本身 ——「照片」只有
/// 约 23×26pt，「实况」档（纯图标）更小。所以：
///
/// 1. **命中宽度** = `max(内容 + 两端内边距, 44)`。用 `.frame(minWidth: 44)` 表达下限；
///    内容本来就宽的档（「Log 实况」52pt）自然更宽，热区跟着内容走。
/// 2. **命中高度** = 44，靠"行高 30 + 上下各溢出 7pt"实现。溢出的落点已经核算过
///    （上溢只到安全区下沿 +3pt，碰不到状态栏；下溢落在副行中段的空白里），
///    **不抢任何控件的点击** —— 账记在 `Theme.Size.modeTabHitHeight` 的注释里。
/// 3. `HStack` 的 `spacing` 固定为 **0**，档间距只有"内边距"这一个来源。
///    （曾把内边距与 spacing 叠加，视觉间距实际是文档写的两倍，连累整条宽度预算算错。）
///
/// ## 窄屏自动降档
///
/// 13pt 那版总宽 202pt，而 375pt 机型（SE / mini）的中段只有 197pt。
/// 用 `ViewThatFits` 声明两套度量，装不下就自动换 12pt + 档间距 12（总宽 191.6pt）——
/// 比用 `GeometryReader` 手算宽度简单，也不会在首帧闪一下错的字号。
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
        ViewThatFits(in: .horizontal) {
            bar(isCompact: false, spacing: Theme.Size.modeSelectorSpacing)
            bar(isCompact: true, spacing: Theme.Size.modeSelectorCompactSpacing)
        }
    }

    // MARK: - 条与档位

    private func bar(isCompact: Bool, spacing: CGFloat) -> some View {
        // spacing 固定 0：档间距离只由每档的内边距产生（见类型注释第 3 条）
        HStack(spacing: 0) {
            ForEach(CaptureSessionMode.allCases) { mode in
                item(for: mode, isCompact: isCompact, spacing: spacing)
            }
        }
        // 注意：**没有胶囊底、没有描边** —— 原型的模式条是一行无背景文字，
        // 选中态靠"白色加粗"表达（早先那版实心 accent 胶囊已被原型第九轮改掉）。
    }

    private func item(
        for mode: CaptureSessionMode,
        isCompact: Bool,
        spacing: CGFloat
    ) -> some View {
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
                content(for: mode, isSelected: isSelected, isCompact: isCompact)
            }
            .foregroundStyle(color(isSelected: isSelected, isAvailable: isAvailable))
            // 视觉高度 26（原型）
            .frame(height: Theme.Size.modeSelectorHeight)
            // 命中宽度：内容 + 两端各半个档间距，且不低于 HIG 下限
            .padding(.horizontal, spacing / 2)
            .frame(minWidth: Theme.Size.modeTabMinHitWidth)
            // 命中高度 44：行高只有 30，上下各溢出 7pt（溢出只落在空白处）
            .frame(height: Theme.Size.modeTabHitHeight)
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
    private func content(
        for mode: CaptureSessionMode,
        isSelected: Bool,
        isCompact: Bool
    ) -> some View {
        if mode == .livePhoto {
            LivePhotoCircleIcon(size: Theme.Size.modeSelectorGlyphSize)
        } else {
            Text(mode.displayName)
                .font(Theme.Typography.modeTitle(selected: isSelected, compact: isCompact))
                // fixedSize 有两个作用：文字不换行、不被压缩；
                // 同时让 ViewThatFits 量到的是真实宽度（否则可能量到"能塞多小塞多小"的值）
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
