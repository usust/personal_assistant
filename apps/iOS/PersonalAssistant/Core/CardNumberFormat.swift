import Foundation

/// 卡号展示分组与存储归一化；不会补齐、截断或改变号码字符。
nonisolated enum CardNumberFormat {
    /// 移除展示分隔符；参数：value 为输入或已保存号码；返回值：去除空白及连字符后的原始内容，星号等遮罩保留。
    static func normalized(_ value: String) -> String {
        value.filter { !$0.isWhitespace && $0 != "-" }
    }
    /// 生成遮罩或主动查看的号码；参数：value 为完整号码、尾号或历史遮罩，name 为卡名，revealed 为是否查看；返回值：完整号码保留前后四位、中间按实际长度遮罩，尾号查看时仅显示数字，空值返回四个星号。
    static func presentation(_ value: String, name: String, revealed: Bool) -> String {
        let raw = normalized(value)
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return "****" }
        if revealed { return display(raw.allSatisfy(\.isNumber) ? raw : String(digits.suffix(4)), name: name) }
        // 完整卡号保留前后四位，中间星号数量等于实际隐藏位数。
        if raw.allSatisfy(\.isNumber), (12...19).contains(raw.count) {
            return display(String(raw.prefix(4)) + String(repeating: "*", count: raw.count - 8) + raw.suffix(4), name: name)
        }
        // 历史尾号不推测缺失位数，继续保留原有遮罩。
        let hidden = raw.allSatisfy(\.isNumber) ? max(4, raw.count - 4) : max(4, raw.filter { $0 == "*" }.count)
        let masked = String(repeating: "*", count: hidden) + digits.suffix(4)
        return display(masked, name: name)
    }
    /// 分组显示卡号；参数：value 为原始号码，name 为卡名用于识别运通；返回值：普通号码每四位分组，运通不超过十五位时采用 4–6–5，遮罩保持原样。
    static func display(_ value: String, name: String) -> String {
        let raw = normalized(value)
        guard !raw.isEmpty, raw.allSatisfy({ $0.isNumber || $0 == "*" }) else { return value }
        let amex = name.contains("运通") || name.lowercased().contains("amex") || name.lowercased().contains("american express") || raw.hasPrefix("34") || raw.hasPrefix("37")
        let sizes = amex && raw.count <= 15 ? [4, 6, 5] : []
        var result: [String] = []
        var remaining = raw[...]
        var group = 0
        while !remaining.isEmpty {
            let size = group < sizes.count ? sizes[group] : 4
            result.append(String(remaining.prefix(size)))
            remaining = remaining.dropFirst(min(size, remaining.count))
            group += 1
        }
        return result.joined(separator: " ")
    }
}
