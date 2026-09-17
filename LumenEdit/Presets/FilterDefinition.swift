import Foundation

// MARK: - 色彩调整参数

/// 一组色彩调整参数。
///
/// 这里的字段**一一对应 CSS `filter` 的各个函数**，之所以不直接存那串 CSS 字符串，
/// 是因为 iOS 侧要把它翻译成 Core Image 参数（P4 的渲染管线直接吃这些数值）。
///
/// 反向地，`cssExpression` 从这些数值**算出来**，只服务两件事：
///   ① 给 `tools/check_presets.js` 与网页原型做一致性比对；
///   ② 原型侧调试时对得上。
/// 这样全工程只有**一份**参数，不会出现"改了 Swift 忘了改 JS"。
struct ColorGrade: Equatable, Codable {

    var contrast: Double = 1
    var saturate: Double = 1
    var brightness: Double = 1
    /// 0 ~ 1
    var sepia: Double = 0
    /// 角度（度）
    var hueRotate: Double = 0
    /// 0 ~ 1
    var grayscale: Double = 0

    /// 是否等于"不做任何调整"
    var isIdentity: Bool {
        self == ColorGrade()
    }

    /// 生成 CSS `filter` 表达式。
    ///
    /// ⚠️ 函数顺序沿用原型里的写法（grayscale → contrast → saturate → hue-rotate → brightness → sepia），
    /// **不要按字母序重排** —— 顺序变了字符串就不等于原型，比对脚本会误报。
    /// （脚本内部实际是解析成数值再比，但保持写法一致能让人肉比对也不费劲。）
    var cssExpression: String {
        var parts: [String] = []
        if grayscale != 0 { parts.append("grayscale(\(Self.num(grayscale)))") }
        if contrast != 1 { parts.append("contrast(\(Self.num(contrast)))") }
        if saturate != 1 { parts.append("saturate(\(Self.num(saturate)))") }
        if hueRotate != 0 { parts.append("hue-rotate(\(Self.num(hueRotate))deg)") }
        if brightness != 1 { parts.append("brightness(\(Self.num(brightness)))") }
        if sepia != 0 { parts.append("sepia(\(Self.num(sepia)))") }
        return parts.joined(separator: " ")
    }

    /// 去掉多余尾零：0.75 → "0.75"，1.0 → "1"，-6.0 → "-6"
    private static func num(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(value)
    }
}

// MARK: - 叠加层

/// 叠加在画面上的一个色层。
///
/// 对应原生型的 `tints: [{b, m}]`：`b` 是 CSS 背景（纯色或渐变），`m` 是混合模式。
/// 这里把纯色与渐变拆成两种 case —— iOS 侧渲染走的是完全不同的代码路径
/// （纯色 → `CIConstantColorGenerator` + 混合；渐变 → `CILinearGradient` + 混合）。
enum TintLayer: Equatable, Codable {

    /// 纯色层
    case solid(color: RGBAColor, blend: TintBlendMode)

    /// 线性渐变层。`angleDeg` 为 CSS 语法的角度（0° 指向正上，顺时针增大）
    case linearGradient(stops: [GradientStop], angleDeg: Double, blend: TintBlendMode)

    var blend: TintBlendMode {
        switch self {
        case .solid(_, let blend): return blend
        case .linearGradient(_, _, let blend): return blend
        }
    }

    /// 还原成原型的 CSS 背景表达式
    var cssBackground: String {
        switch self {
        case .solid(let color, _):
            return color.cssRGBA

        case .linearGradient(let stops, let angleDeg, _):
            let body = stops
                .map { "\($0.color.cssRGBA) \(Self.pct($0.position))" }
                .joined(separator: ", ")
            return "linear-gradient(\(Self.angleCSS(angleDeg)), \(body))"
        }
    }

    private static func pct(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))%" : "\(v)%"
    }

    private static func angleCSS(_ deg: Double) -> String {
        deg == deg.rounded() ? "\(Int(deg))deg" : "\(deg)deg"
    }
}

/// 渐变色标
struct GradientStop: Equatable, Codable {
    let color: RGBAColor
    /// 0 ~ 100
    let position: Double
}

/// 叠加层的混合模式（对应 CSS `mix-blend-mode`）
enum TintBlendMode: String, Equatable, Codable {
    case softLight = "soft-light"
    case multiply
    case overlay
    case screen
}

// MARK: - 通用颜色

/// 一个 RGBA 颜色（0~255 分量 + 0~1 alpha），带 CSS 序列化能力
struct RGBAColor: Equatable, Codable {
    let r: Int
    let g: Int
    let b: Int
    let a: Double

    /// `rgba(255, 236, 200, .10)` —— 空格与小数写法刻意对齐原型
    var cssRGBA: String {
        "rgba(\(r), \(g), \(b), \(Self.alpha(a)))"
    }

    /// 原型的 alpha 写法是 `.10` / `.26` / `0` 混用，这里统一成"能短则短"
    private static func alpha(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v == 1 { return "1" }
        // .10 / .26 / .13 —— 两位小数，去掉末尾 0
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("0") { s.removeFirst() }
        return s
    }
}

// MARK: - 滤镜定义

/// 一个滤镜（LUT 类预设）。
///
/// ## 这是「单一真源」
/// 网页原型 `prototype/index.html` 里的 `FILTERS`、iOS 的渲染参数、
/// 滤镜条缩略图、预设 JSON 分享 —— 四处都从这一份数据派生。
/// `tools/check_presets.js` 会把它与原型 JS 数据**逐条比对**，不一致直接报错。
struct FilterDefinition: Identifiable, Equatable, Codable {

    let id: String
    /// UI 显示名（自创名，规避商标）
    let displayName: String
    /// 内部对标说明 —— **只用于文档与注释，绝不出现在 UI 上**
    let reference: String
    /// 默认强度 0 ~ 1
    let intensity: Double
    /// 色彩调整
    let grade: ColorGrade
    /// 叠加层（可能为空）
    let tints: [TintLayer]
    /// 缩略图色块（3 个十六进制色，如 `#8E8778`）
    let swatches: [String]
}
