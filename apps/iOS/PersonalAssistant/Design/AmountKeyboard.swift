import SwiftUI

/// 账户金额计算键盘；value 为已确认金额，hasPendingCalculation 表示未完成算式，title 为标题，onDone 为关闭回调；无返回值，不直接保存账户。
struct AmountKeyboard: View {
    @Binding var value: String
    @Binding var hasPendingCalculation: Bool
    var title: String = "账户余额 · CNY"
    let onDone: () -> Void
    @State private var draft = "0"
    @State private var calculation = AmountCalculation()
    private let keys = ["清空", "删除", "÷", "×", "7", "8", "9", "−", "4", "5", "6", "+", "1", "2", "3", "=", "0", "00", ".", "完成"]

    /// 构建四列计算键盘；参数：无；返回值：算式、结果与独立运算键，错误时显示校验信息。
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let operand = calculation.operand, let operation = calculation.operation {
                        Text(operand + " " + operation).font(.caption).foregroundStyle(.secondary)
                    }
                    AmountText(value: draft, emphasis: .compact)
                }
            }.accessibilityElement(children: .combine)
            if let error = calculation.error { InlineError(message: error) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                // 网格回调输入键名，返回编辑草稿或确认结果的按钮，不执行网络写入。
                ForEach(keys, id: \.self) { key in
                    Button { input(key) } label: {
                        Text(key).font(key.count > 1 && key != "00" ? .body.weight(.medium) : AppVisualStyle.keypadFont)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(AmountKeyStyle(emphasized: key == "完成", foreground: key == "完成" ? .white : ["+", "−", "×", "÷", "="].contains(key) ? .accentColor : .primary))
                        .accessibilityLabel(["+": "加", "−": "减", "×": "乘", "÷": "除", "=": "等于"][key] ?? key)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: 600).frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
            // 生命周期回调无参数、无返回值；载入表单金额，离开时丢弃未完成算式并解除提交锁定。
            .onAppear { draft = value; hasPendingCalculation = false }
            .onDisappear { hasPendingCalculation = false }
    }

    /// 处理输入与完成；参数：key 为键名；返回值：无；仅把无待计算步骤的数字写回绑定，完成自动求值，失败保持键盘打开。
    private func input(_ key: String) {
        if key == "完成" {
            guard calculation.evaluate(draft: &draft) else { return }
            value = draft; hasPendingCalculation = false; onDone()
        } else {
            calculation.input(key, draft: &draft)
            hasPendingCalculation = calculation.operation != nil
            if !hasPendingCalculation { value = draft }
        }
    }
}
