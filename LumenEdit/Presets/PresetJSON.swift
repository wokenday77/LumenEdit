import Foundation

/// 预设数据在「人可读 CSS」与「机器可读 JSON」两种序列化里共用的格式化工具。
///
/// 为什么单拎出来：`FilterCatalog` / `StyleCatalog` / `SceneCatalog` 三处都要把数值
/// 写成原型那种"能短则短"的写法（`0.75` 而不是 `0.750`，`1` 而不是 `1.0`），
/// 各写一份必然漂移，比对脚本就会误报。
enum PresetJSON {

    /// 数值短写法：整数去掉小数点，小数原样（0.75 → "0.75"、1.0 → "1"、-6.0 → "-6"）
    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// CSS 渐变角度：0 → `to top`、180 → `to bottom`，其余用 `Ndeg`
    static func cssAngle(_ deg: Double) -> String {
        if deg == 0 { return "to top" }
        if deg == 180 { return "to bottom" }
        return "\(trim(deg))deg"
    }

    /// 百分比（0 → "0%"、55 → "55%"）
    static func percent(_ v: Double) -> String {
        "\(trim(v))%"
    }

    /// 把一组叠加层序列化成原型 `tints` 那样的一维数组
    static func tintsJSON(_ tints: [TintLayer]) -> String {
        let items = tints.map { t -> String in
            let blend = t.blend.rawValue
            switch t {
            case .solid(let c, _):
                return "{\"kind\":\"solid\",\"b\":\"\(c.cssRGBA)\",\"m\":\"\(blend)\"}"
            case .linearGradient(let stops, let angle, _):
                let body = stops
                    .map { "\($0.color.cssRGBA) \(percent($0.position))" }
                    .joined(separator: ", ")
                return "{\"kind\":\"gradient\",\"b\":\"linear-gradient(\(cssAngle(angle)), \(body))\",\"m\":\"\(blend)\"}"
            }
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// 把一组色块序列化成 JSON 字符串数组
    static func swatchesJSON(_ swatches: [String]) -> String {
        "[" + swatches.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
}
