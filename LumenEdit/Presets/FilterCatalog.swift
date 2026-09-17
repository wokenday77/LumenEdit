import Foundation

/// 滤镜目录 —— **全工程 14 个滤镜的唯一真源**。
///
/// 数据来源：网页原型 `prototype/index.html` 的 `FILTERS` 数组，
/// 由 `tools/check_presets.js` 自动比对（含 CSS 表达式反算校验）。
/// **改这里就不要改原型，反之亦然** —— 脚本会把不一致吼出来。
enum FilterCatalog {

    /// 全部滤镜（顺序与原型一致，滤镜条按此顺序渲染）
    static let all: [FilterDefinition] = [

        FilterDefinition(
            id: "f_portra160",
            displayName: "柔暖胶片",
            reference: "对标 Kodak Portra 160",
            intensity: 0.75,
            grade: ColorGrade(contrast: 0.96, saturate: 0.88, brightness: 1.03, sepia: 0.12),
            tints: [
                .solid(color: RGBAColor(r: 255, g: 236, b: 200, a: 0.10), blend: .softLight)
            ],
            swatches: ["#8E8778", "#C9A98C", "#F2E2C8"]
        ),

        FilterDefinition(
            id: "f_portra400",
            displayName: "浓暖胶片",
            reference: "对标 Kodak Portra 400",
            intensity: 0.75,
            grade: ColorGrade(contrast: 0.97, saturate: 0.93, brightness: 1.03, sepia: 0.17),
            tints: [
                .solid(color: RGBAColor(r: 255, g: 224, b: 178, a: 0.13), blend: .softLight)
            ],
            swatches: ["#8A7F6C", "#CDA88A", "#F5E0BE"]
        ),

        FilterDefinition(
            id: "f_classicchrome",
            displayName: "纪实冷调",
            reference: "对标 Fujifilm Classic Chrome",
            intensity: 0.80,
            grade: ColorGrade(contrast: 1.12, saturate: 0.82, brightness: 0.98, hueRotate: -6),
            tints: [
                .solid(color: RGBAColor(r: 60, g: 90, b: 120, a: 0.10), blend: .multiply)
            ],
            swatches: ["#4E5A63", "#8C8880", "#E8E3D8"]
        ),

        FilterDefinition(
            id: "f_mono",
            displayName: "中高对比黑白",
            reference: "对标 Ilford HP5 Plus",
            intensity: 0.85,
            grade: ColorGrade(contrast: 1.15, brightness: 1.02, grayscale: 1),
            tints: [],
            swatches: ["#2E2E2E", "#8A8A8A", "#E6E6E6"]
        ),

        FilterDefinition(
            id: "f_creamskin",
            displayName: "暖白柔肤",
            reference: "对标主流 App 奶油肌类",
            intensity: 0.70,
            grade: ColorGrade(contrast: 0.93, saturate: 0.92, brightness: 1.07, sepia: 0.10),
            tints: [
                .solid(color: RGBAColor(r: 255, g: 225, b: 205, a: 0.16), blend: .softLight)
            ],
            swatches: ["#A08B7E", "#E0C4AE", "#FBEEDF"]
        ),

        FilterDefinition(
            id: "f_softglow",
            displayName: "柔光通透",
            reference: "对标 VSCO G3 方向",
            intensity: 0.65,
            grade: ColorGrade(contrast: 0.95, saturate: 0.98, brightness: 1.07),
            tints: [
                .solid(color: RGBAColor(r: 255, g: 255, b: 255, a: 0.12), blend: .softLight)
            ],
            swatches: ["#8E9AA6", "#C6CDD2", "#F7F9FA"]
        ),

        FilterDefinition(
            id: "f_clearsmooth",
            displayName: "通透哑光",
            reference: "对标主流 App 透白 / 净透",
            intensity: 0.70,
            grade: ColorGrade(contrast: 0.88, saturate: 0.92, brightness: 1.05),
            tints: [
                .solid(color: RGBAColor(r: 190, g: 190, b: 185, a: 0.16), blend: .screen)
            ],
            swatches: ["#9A968F", "#CFC9BF", "#F4F0E9"]
        ),

        FilterDefinition(
            id: "f_vividskin",
            displayName: "质感红润",
            reference: "对标主流 App 甜橘 / 阳光肤",
            intensity: 0.70,
            grade: ColorGrade(contrast: 1.03, saturate: 1.12, brightness: 1.02, hueRotate: -4),
            tints: [
                .solid(color: RGBAColor(r: 255, g: 170, b: 140, a: 0.12), blend: .softLight)
            ],
            swatches: ["#8C6A5A", "#CC9779", "#F6D9BF"]
        ),

        FilterDefinition(
            id: "f_vivid",
            displayName: "高饱和风光",
            reference: "对标 VSCO C1",
            intensity: 0.80,
            grade: ColorGrade(contrast: 1.06, saturate: 1.35, brightness: 1.02),
            tints: [],
            swatches: ["#3B5F4A", "#7FA86B", "#D8E8C0"]
        ),

        // 唯一带「双渐变叠层」的滤镜：上方压冷青、下方压暖橙（阴影冷 / 高光暖）
        FilterDefinition(
            id: "f_tealorange",
            displayName: "冷青暖橙",
            reference: "对标 Lightroom Cinematic",
            intensity: 0.85,
            grade: ColorGrade(contrast: 1.12, saturate: 1.05),
            tints: [
                .linearGradient(
                    stops: [
                        GradientStop(color: RGBAColor(r: 0, g: 80, b: 110, a: 0.28), position: 0),
                        GradientStop(color: RGBAColor(r: 0, g: 80, b: 110, a: 0), position: 55)
                    ],
                    angleDeg: 0,            // CSS `to top`
                    blend: .softLight
                ),
                .linearGradient(
                    stops: [
                        GradientStop(color: RGBAColor(r: 255, g: 170, b: 80, a: 0.24), position: 0),
                        GradientStop(color: RGBAColor(r: 255, g: 170, b: 80, a: 0), position: 55)
                    ],
                    angleDeg: 180,          // CSS `to bottom`
                    blend: .softLight
                )
            ],
            swatches: ["#2F4F5E", "#8A8578", "#E0A56A"]
        ),

        FilterDefinition(
            id: "f_hdr",
            displayName: "HDR 质感",
            reference: "对标 Lightroom HDR / 主流 AI HDR",
            intensity: 0.70,
            grade: ColorGrade(contrast: 1.08, saturate: 1.18, brightness: 1.03),
            tints: [
                .solid(color: RGBAColor(r: 200, g: 200, b: 195, a: 0.14), blend: .softLight)
            ],
            swatches: ["#4A4A4A", "#9E9A92", "#EFEDE8"]
        ),

        FilterDefinition(
            id: "f_faded",
            displayName: "电影褪色",
            reference: "对标 VSCO F2 / Film-Inspired Soft Ember",
            intensity: 0.80,
            grade: ColorGrade(contrast: 0.86, saturate: 0.78, brightness: 1.04, sepia: 0.22),
            tints: [
                .solid(color: RGBAColor(r: 120, g: 90, b: 60, a: 0.12), blend: .overlay)
            ],
            swatches: ["#6E6355", "#A89478", "#E8DCC6"]
        ),

        FilterDefinition(
            id: "f_moody",
            displayName: "低调暗影",
            reference: "对标 VSCO M5 复古低饱和",
            intensity: 0.80,
            grade: ColorGrade(contrast: 1.05, saturate: 0.80, brightness: 0.90),
            tints: [
                .solid(color: RGBAColor(r: 30, g: 25, b: 20, a: 0.16), blend: .multiply)
            ],
            swatches: ["#2A2520", "#6E6154", "#C4B49A"]
        ),

        FilterDefinition(
            id: "f_hongkong",
            displayName: "暖琥珀绿",
            reference: "对标《花样年华》色调方向",
            intensity: 0.80,
            grade: ColorGrade(contrast: 1.06, saturate: 1.02, brightness: 0.97, sepia: 0.14, hueRotate: -8),
            tints: [
                .solid(color: RGBAColor(r: 180, g: 140, b: 60, a: 0.14), blend: .softLight),
                .solid(color: RGBAColor(r: 40, g: 80, b: 45, a: 0.10), blend: .overlay)
            ],
            swatches: ["#3E4A32", "#9A8A5E", "#E8C98A"]
        )
    ]

    /// 按 id 查（不存在返回 nil）
    static func filter(id: String?) -> FilterDefinition? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    // MARK: - 供检查脚本读取的机器可读快照

    /// 把目录导出成与原型 JS 同构的 JSON 文本。
    ///
    /// 用途：`tools/check_presets.js` 拿它和 `prototype/index.html` 里的 FILTERS 逐条核对。
    /// 之所以要"导出"而不是让脚本去解析 Swift 源码 —— 解析 Swift 太脆，
    /// 让 Swift 自己吐出一份规范 JSON 最稳。
    static func machineReadableJSON() -> String {
        var rows: [String] = []
        for f in all {
            rows.append("""
            {"id":"\(f.id)","name":"\(f.displayName)","ref":"\(f.reference)",\
            "intensity":"\(PresetJSON.trim(f.intensity))",\
            "css":"\(f.grade.cssExpression)",\
            "tints":\(PresetJSON.tintsJSON(f.tints)),\
            "sw":\(PresetJSON.swatchesJSON(f.swatches))}
            """)
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }
}
