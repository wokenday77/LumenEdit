import Foundation

/// 一个「风格」预设：滤镜 + 一套额外参数 + UI 徽标。
///
/// ## 与 FilterDefinition 的关系（容易搞混，说清楚）
/// - **FilterDefinition**：单纯的色彩变换，是「叠在画面上的颜色层」。
/// - **StylePreset**：面向"一键成片"的完整配方，**可以引用一个滤镜**（也可以不引用），
///   并带自己的 `grade` / `tints`。两者的参数**故意不完全相同** ——
///   风格在滤镜基础上还带自己的取舍（例如风格 `portra160` 的 brightness 是 1.02，
///   而滤镜 `f_portra160` 是 1.03）。**这不是笔误，是与原型一致的设计。**
///
/// ## 真源
/// 数据来自网页原型 `prototype/index.html` 的 `STYLES` 数组，
/// 由 `tools/check_presets.js` 比对。
struct StylePreset: Identifiable, Equatable, Codable {

    let id: String
    let displayName: String
    /// 内部对标说明 —— **只用于文档与注释，不出现在 UI**
    let reference: String
    /// UI 徽标文案（一行参数摘要，展示在风格卡上）
    let badge: String
    /// 色彩调整
    let grade: ColorGrade
    /// 叠加层
    let tints: [TintLayer]
    /// 引用的滤镜 id；nil 表示这个风格不挂 LUT（纯参数风格）
    let filterId: String?
    /// 该风格应用滤镜时的强度（字符串形式存原值，如 "0.75"）
    let filterIntensity: String
}

/// 风格目录 —— 10 个风格的真源
enum StyleCatalog {

    static let all: [StylePreset] = [

        StylePreset(
            id: "portra160",
            displayName: "柔暖人像",
            reference: "对标 Kodak Portra 160",
            badge: "高光 −20 · 阴影 +10 · 色温 +300K",
            grade: ColorGrade(contrast: 0.96, saturate: 0.88, brightness: 1.02, sepia: 0.12),
            tints: [
                .solid(color: RGBAColor(r: 255, g: 236, b: 200, a: 0.10), blend: .softLight)
            ],
            filterId: "f_portra160",
            filterIntensity: "0.75"
        ),

        StylePreset(
            id: "portra400",
            displayName: "浓暖人像",
            reference: "对标 Kodak Portra 400",
            badge: "高光 −15 · 阴影 +14 · 色温 +450K · 颗粒 7",
            grade: ColorGrade(contrast: 0.97, saturate: 0.93, brightness: 1.02, sepia: 0.16),
            tints: [
                .solid(color: RGBAColor(r: 255, g: 225, b: 180, a: 0.13), blend: .softLight)
            ],
            filterId: "f_portra400",
            filterIntensity: "0.75"
        ),

        StylePreset(
            id: "classicchrome",
            displayName: "纪实冷调",
            reference: "对标 Fujifilm Classic Chrome",
            badge: "对比 +12 · 饱和 −14 · 高光 −10 · 色温 −200K",
            grade: ColorGrade(contrast: 1.10, saturate: 0.82, brightness: 0.99, hueRotate: -6),
            tints: [
                .solid(color: RGBAColor(r: 60, g: 90, b: 120, a: 0.10), blend: .multiply)
            ],
            filterId: "f_classicchrome",
            filterIntensity: "0.80"
        ),

        // 无 LUT 的纯参数风格
        StylePreset(
            id: "macaron",
            displayName: "糖果粉调",
            reference: "对标主流修图 App 马卡龙类",
            badge: "对比 −20 · 饱和 −18 · 高光 −40 · 色调 +18",
            grade: ColorGrade(contrast: 0.88, saturate: 0.85, brightness: 1.07, hueRotate: 8),
            tints: [
                .linearGradient(
                    stops: [
                        GradientStop(color: RGBAColor(r: 255, g: 190, b: 225, a: 0.24), position: 0),
                        GradientStop(color: RGBAColor(r: 200, g: 205, b: 255, a: 0.18), position: 100)
                    ],
                    angleDeg: 160,
                    blend: .softLight
                )
            ],
            filterId: nil,
            filterIntensity: "0.80"
        ),

        StylePreset(
            id: "creamskin",
            displayName: "暖白肤色",
            reference: "对标主流修图 App 奶油肌类",
            badge: "高光 −50 · 阴影 +16 · 色温 +400K · 降噪 +10",
            grade: ColorGrade(contrast: 0.93, saturate: 0.92, brightness: 1.06, sepia: 0.10),
            tints: [
                .solid(color: RGBAColor(r: 255, g: 225, b: 205, a: 0.16), blend: .softLight)
            ],
            filterId: "f_creamskin",
            filterIntensity: "0.70"
        ),

        StylePreset(
            id: "tealorange",
            displayName: "冷青暖橙",
            reference: "对标 Lightroom Cinematic / Cinematic II",
            badge: "对比 +12 · 高光 −10 · 阴影 +8 · 暗角 12",
            grade: ColorGrade(contrast: 1.12, saturate: 1.05),
            tints: [
                .linearGradient(
                    stops: [
                        GradientStop(color: RGBAColor(r: 0, g: 80, b: 110, a: 0.26), position: 0),
                        GradientStop(color: RGBAColor(r: 0, g: 80, b: 110, a: 0), position: 55)
                    ],
                    angleDeg: 0,            // CSS `to top`
                    blend: .softLight
                ),
                .linearGradient(
                    stops: [
                        GradientStop(color: RGBAColor(r: 255, g: 170, b: 80, a: 0.22), position: 0),
                        GradientStop(color: RGBAColor(r: 255, g: 170, b: 80, a: 0), position: 55)
                    ],
                    angleDeg: 180,          // CSS `to bottom`
                    blend: .softLight
                )
            ],
            filterId: "f_tealorange",
            filterIntensity: "0.85"
        ),

        StylePreset(
            id: "hongkong",
            displayName: "暖琥珀胶片",
            reference: "对标《花样年华》色调方向",
            badge: "对比 +6 · 高光 −25 · 阴影 +10 · 色温 +600K · 颗粒 8",
            grade: ColorGrade(contrast: 1.05, saturate: 1.02, brightness: 0.98, sepia: 0.14, hueRotate: -8),
            tints: [
                .solid(color: RGBAColor(r: 180, g: 140, b: 60, a: 0.14), blend: .softLight),
                .solid(color: RGBAColor(r: 40, g: 80, b: 45, a: 0.10), blend: .overlay)
            ],
            filterId: "f_hongkong",
            filterIntensity: "0.80"
        ),

        // 无 LUT 的纯参数风格
        StylePreset(
            id: "japanese",
            displayName: "透亮淡青",
            reference: "对标 VSCO F2 褪色哑光方向",
            badge: "对比 −10 · 亮度 +12 · 阴影 +20 · 色温 −150K",
            grade: ColorGrade(contrast: 0.90, saturate: 0.90, brightness: 1.12),
            tints: [
                .solid(color: RGBAColor(r: 210, g: 240, b: 235, a: 0.16), blend: .screen)
            ],
            filterId: nil,
            filterIntensity: "0.75"
        ),

        StylePreset(
            id: "mono",
            displayName: "中高对比黑白",
            reference: "对标 Ilford HP5 Plus",
            badge: "对比 +15 · 阴影 −12 · 结构 +20 · 颗粒 12",
            grade: ColorGrade(contrast: 1.15, brightness: 1.02, grayscale: 1),
            tints: [],
            filterId: "f_mono",
            filterIntensity: "0.85"
        ),

        StylePreset(
            id: "faded",
            displayName: "褪色胶片",
            reference: "对标 VSCO F2 / Lightroom Vintage",
            badge: "对比 −18 · 阴影 +25 · 色温 +350K · 颗粒 8",
            grade: ColorGrade(contrast: 0.86, saturate: 0.78, brightness: 1.04, sepia: 0.22),
            tints: [
                .solid(color: RGBAColor(r: 120, g: 90, b: 60, a: 0.12), blend: .overlay)
            ],
            filterId: "f_faded",
            filterIntensity: "0.80"
        )
    ]

    static func style(id: String?) -> StylePreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// 与原型 `STYLES` 同构的机器可读 JSON，供 `tools/check_presets.js` 比对
    static func machineReadableJSON() -> String {
        var rows: [String] = []
        for s in all {
            let filter = s.filterId.map { "\"\($0)\"" } ?? "null"
            rows.append("""
            {"id":"\(s.id)","name":"\(s.displayName)","ref":"\(s.reference)",\
            "badge":"\(s.badge)","css":"\(s.grade.cssExpression)",\
            "tints":\(PresetJSON.tintsJSON(s.tints)),\
            "filter":\(filter),"fi":"\(s.filterIntensity)"}
            """)
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }
}
