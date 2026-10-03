import Foundation

@main struct CardNumberFormatTests {
    /// 验证分组及字符保留；参数：无；返回值：无；使用虚构号码，失败触发断言。
    static func main() {
        assert(CardNumberFormat.display("1234567890123456", name: "VISA") == "1234 5678 9012 3456")
        assert(CardNumberFormat.display("1234567890123456789", name: "银行卡") == "1234 5678 9012 3456 789")
        assert(CardNumberFormat.display("370000000000000", name: "运通") == "3700 000000 00000")
        assert(CardNumberFormat.display("3700000", name: "") == "3700 000")
        assert(CardNumberFormat.display("1234", name: "运通") == "1234")
        assert(CardNumberFormat.display("**** 1234", name: "VISA") == "**** 1234")
        assert(CardNumberFormat.normalized("1234-5678 9012 3456") == "1234567890123456")
        assert(CardNumberFormat.normalized("**** 1234") == "****1234")
        assert(CardNumberFormat.display("", name: "") == "")
        assert(CardNumberFormat.presentation("1234567890123456", name: "VISA", revealed: false) == "1234 **** **** 3456")
        assert(CardNumberFormat.presentation("370000000000000", name: "运通", revealed: false) == "3700 ****** *0000")
        assert(CardNumberFormat.presentation("1234567890123456789", name: "", revealed: false).filter { $0 == "*" }.count == 11)
        assert(CardNumberFormat.presentation("1234", name: "", revealed: false) == "**** 1234")
        assert(CardNumberFormat.presentation("**** 1234", name: "", revealed: true) == "1234")
        assert(CardNumberFormat.presentation("1234", name: "", revealed: true) == "1234")
        assert(CardNumberFormat.presentation("1234567890123456", name: "", revealed: true) == "1234 5678 9012 3456")
        assert(CardNumberFormat.presentation("123456789012", name: "", revealed: false) == "1234 **** 9012")
        assert(CardNumberFormat.presentation("1234-5678 9012 3456", name: "", revealed: false) == "1234 **** **** 3456")
        print("CardNumberFormat tests passed")
    }
}
