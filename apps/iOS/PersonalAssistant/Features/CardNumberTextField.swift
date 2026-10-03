import SwiftUI
import UIKit

/// 支持实时分组并保留光标位置的卡号输入框。
struct CardNumberTextField: UIViewRepresentable {
    @Binding var value: String
    let name: String

    /// 创建输入协调器；参数：无；返回值：负责字符替换及光标定位的协调器。
    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }
    /// 创建系统输入框；参数：context 为生命周期上下文；返回值：数字键盘输入框，支持字号缩放与辅助功能。
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "卡号或后四位"
        field.accessibilityLabel = "卡号或后四位"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = .numberPad
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    /// 同步外部资料；参数：field 为系统输入框，context 为协调器上下文；返回值：无，相同文本不重设，避免移动输入光标。
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.owner = self
        let formatted = CardNumberFormat.display(value, name: name)
        if field.text != formatted { field.text = formatted }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var owner: CardNumberTextField
        /// 初始化输入协调器；参数：owner 为当前绑定与卡名；返回值：协调器，不修改资料。
        init(owner: CardNumberTextField) { self.owner = owner }
        /// 接管字符替换；参数：textField 为输入框，range 为 UTF-16 替换范围，string 为输入或粘贴文本；返回值：false，已手动更新格式、绑定和光标。
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let old = textField.text ?? ""
            guard let swiftRange = Range(range, in: old) else { return false }
            var prefix = String(old[..<swiftRange.lowerBound])
            // 删除分隔空格时同步删除前一位，避免空格自动补回导致退格无效。
            if string.isEmpty && !old[swiftRange].isEmpty && old[swiftRange].allSatisfy(\.isWhitespace) && !prefix.isEmpty {
                prefix.removeLast()
            }
            let beforeCursor = CardNumberFormat.normalized(prefix + string)
            let raw = beforeCursor + CardNumberFormat.normalized(String(old[swiftRange.upperBound...]))
            let formatted = CardNumberFormat.display(raw, name: owner.name)
            textField.text = formatted
            owner.value = raw
            // 按非分隔字符计数重新定位，保证中间插入、删除及粘贴后光标不跳到末尾。
            var count = 0
            var offset = 0
            for character in formatted {
                if count >= beforeCursor.count { break }
                offset += String(character).utf16.count
                if !character.isWhitespace { count += 1 }
            }
            if let position = textField.position(from: textField.beginningOfDocument, offset: offset) {
                textField.selectedTextRange = textField.textRange(from: position, to: position)
            }
            return false
        }
    }
}
