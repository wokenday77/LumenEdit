import SwiftUI

/// 风格的缩略预览面 —— **风格卡与快门排风格方块共用同一套画法**。
///
/// ## 现在画什么（P4 之前）
///
/// 原型是"示例图 + 该风格的滤镜链"实时渲染出来的。Swift 侧 P4（修图引擎）之前没有渲染链路，
/// 所以这里用**该风格所引用滤镜的 `swatches` 三色渐变**作为占位 —— 它能表达"这个风格偏什么色调"，
/// 且数据已就绪（`StylePreset.filterId` → `FilterDefinition.swatches`）。
///
/// 纯参数风格（`filterId == nil`，即不挂 LUT 的那一类）拿不到 swatches → 用**中性渐变**兜底。
///
/// P4 接上渲染链路后，这里换成真实渲染即可，调用点不用改（这正是抽成组件的意义）。
///
/// ## 两种外观
///
/// - `.filled`：整块填充渐变（风格卡的缩略图，74×50）
/// - `.border(width:)`：只留一圈渐变描边、内衬深色（快门排的风格方块，50×50）
///
/// 原型里两块用的是同一张"当前风格"的预览，所以它们必须同源 —— 这也是抽组件的原因。
struct StyleThumbnailView: View {

    /// 缩略图的外观
    enum Appearance {
        /// 整块填充
        case filled
        /// 渐变描边：内衬 `width` 宽的深色
        case border(width: CGFloat)
    }

    let style: StylePreset
    let size: CGSize
    let cornerRadius: CGFloat
    let appearance: Appearance

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(gradient)
            .frame(width: size.width, height: size.height)
            .overlay {
                if case .border(let width) = appearance {
                    RoundedRectangle(
                        cornerRadius: max(cornerRadius - width, 0),
                        style: .continuous
                    )
                    .fill(Theme.Palette.styleThumbInner)
                    .padding(width)
                }
            }
    }

    // MARK: - 渐变取色

    private var gradient: LinearGradient {
        LinearGradient(
            colors: Self.colors(for: style),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 取该风格的代表色：优先用它引用的滤镜的 `swatches`，没有滤镜则用中性色。
    static func colors(for style: StylePreset) -> [Color] {
        if let filterId = style.filterId,
           let filter = FilterCatalog.all.first(where: { $0.id == filterId }),
           filter.swatches.count >= 2 {
            return filter.swatches.map(color(from:))
        }
        return Self.fallbackColors
    }

    /// 中性兜底（纯参数风格用）：三段灰，视觉上"没有明显色调倾向"
    private static let fallbackColors: [Color] = [
        Color(white: 0.30), Color(white: 0.48), Color(white: 0.66)
    ]

    /// `#RRGGBB` → `Color`；解析不出来就退回中性灰，绝不让界面出现空白块
    private static func color(from hex: String) -> Color {
        var value: UInt64 = 0
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard Scanner(string: trimmed).scanHexInt64(&value) else {
            return Color(white: 0.45)
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}
