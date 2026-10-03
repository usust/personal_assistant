import Foundation

/// 金额按键处理器：只用十进制文本编辑，避免浮点运算引入金额误差。
enum AmountKeypad {
    /// 应用按键；参数：key 为数字、小数点、正负、删除或清空，value 为当前金额，replace 表示首次数字替换原值；返回编辑后的文本，不接受两位以上小数或超过一万亿元的值，无副作用。
    static func apply(_ key: String, to value: String, replace: Bool = false) -> String {
        if key == "清空" { return "0" }
        if key == "删除" { return value.count > 1 ? String(value.dropLast()) : "0" }
        if key == "±" { return value.hasPrefix("-") ? String(value.dropFirst()) : "-" + value }
        guard key == "." || key == "00" || (key.count == 1 && "0123456789".contains(key)) else { return value }
        var next = replace ? (value.hasPrefix("-") ? "-0" : "0") : value
        if next.isEmpty || next == "-" { next += "0" }
        if key == "." {
            return next.contains(".") ? next : next + "."
        }
        if next == "0" || next == "-0" {
            next = (next.hasPrefix("-") ? "-" : "") + (key == "00" ? "0" : key)
        } else { next += key }
        let parts = next.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count < 3, (parts.count < 2 || parts[1].count <= 2),
              let amount = Decimal(string: next), abs(amount) <= Decimal(1_000_000_000_000 as Int64) else { return value }
        return next
    }
    /// 执行十进制金额计算；参数：lhs、rhs 为十进制文本，operation 为 +、−、×、÷，allowNegative 默认 false、账户余额计算可传 true；返回值：按分四舍五入的金额，除零、非法输入、不允许的负数或绝对值超过一万亿元返回 nil，无副作用。
    static func calculate(_ lhs: String, operation: String, rhs: String, allowNegative: Bool = false) -> String? {
        guard lhs.range(of: #"^-?[0-9]+(\.[0-9]*)?$"#, options: .regularExpression) != nil,
              rhs.range(of: #"^-?[0-9]+(\.[0-9]*)?$"#, options: .regularExpression) != nil,
              let left = Decimal(string: lhs), let right = Decimal(string: rhs),
              allowNegative || (left >= 0 && right >= 0) else { return nil }
        var result: Decimal
        switch operation {
        case "+": result = left + right
        case "−": result = left - right
        case "×": result = left * right
        case "÷": guard right != 0 else { return nil }; result = left / right
        default: return nil
        }
        guard !result.isNaN, (allowNegative || result >= 0), abs(result) <= Decimal(1_000_000_000_000 as Int64) else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 2, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
}

/// 账户金额计算状态；连续计算按按键顺序执行，未完成的算式不写入表单金额。
struct AmountCalculation {
    var operand: String?
    var operation: String?
    var replace = true
    var error: String?

    /// 处理计算按键；参数：key 为数字、编辑、四则运算或等号，draft 为当前操作数并在成功时原位更新；返回值：无；失败保留算式并记录简短错误，不访问账本。
    mutating func input(_ key: String, draft: inout String) {
        error = nil
        if key == "清空" {
            operand = nil; operation = nil; replace = true; draft = "0"
        } else if ["+", "−", "×", "÷"].contains(key) {
            // 还未输入右操作数时只更换运算符，避免重复按键产生意外计算。
            if operation != nil && !replace && !evaluate(draft: &draft) { return }
            operand = draft; operation = key; replace = true
        } else if key == "=" {
            if evaluate(draft: &draft) { replace = true }
        } else if key == "删除" && operation != nil && replace {
            // 删除尚未输入右操作数的符号，恢复左操作数继续编辑。
            operation = nil; operand = nil; replace = false
        } else {
            // 运算结果后的数字开启新数值，不继承上一结果的负号。
            let initial = replace ? "0" : draft
            draft = AmountKeypad.apply(key, to: key == "删除" ? draft : initial)
            replace = false
        }
    }

    /// 求出待处理算式；参数：draft 为当前操作数，成功后替换成结果；返回值：是否成功；无算式时直接成功，缺少右操作数、除零或越界时保留输入并设置错误。
    mutating func evaluate(draft: inout String) -> Bool {
        guard let operand, let operation else { return true }
        guard !replace else { error = "请输入第二个金额"; return false }
        if operation == "÷", Decimal(string: draft) == 0 { error = "除数不能为 0"; return false }
        guard let result = AmountKeypad.calculate(operand, operation: operation, rhs: draft, allowNegative: true) else {
            error = "金额无效或超出范围"; return false
        }
        draft = result; self.operand = nil; self.operation = nil
        return true
    }
}
