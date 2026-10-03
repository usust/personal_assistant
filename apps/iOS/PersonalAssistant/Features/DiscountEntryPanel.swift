import SwiftUI

/// 优惠金额底部输入面板；value 为优惠草稿绑定，originalAmount 为支出原金额（转账传 nil）；完成才回写，不直接保存账本。
struct DiscountEntryPanel: View {
    @Binding var value: String
    var originalAmount: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var populated = false
    @State private var replace = true
    @State private var operand: String?
    @State private var operation: String?
    @State private var error: String?
    private let gap: CGFloat = 4

    /// 构建紧凑金额面板；参数：无；返回值：关闭／完成、金额框及四列专用键盘，常态面板高 320 点、错误时增高容纳提示，不弹系统键盘，取消保留原值。
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                // 关闭回调无参数、无返回值；丢弃本次尚未确认的优惠编辑。
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .foregroundStyle(.secondary).accessibilityLabel("取消优惠输入")
                Spacer()
                Text("优惠").font(.headline)
                Spacer()
                Button("完成") { complete() }.frame(minWidth: 44, minHeight: 44)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    if let operand, let operation { Text(operand + " " + operation).font(.caption).foregroundStyle(.secondary) }
                    Text(draft.isEmpty ? "请输入优惠" : draft)
                        .font(.body).monospacedDigit().foregroundStyle(draft.isEmpty ? .secondary : .primary)
                        .lineLimit(1).minimumScaleFactor(0.5).frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityLabel("优惠金额，" + (draft.isEmpty ? "未输入" : draft))
                // 清空回调无参数、无返回值；同时重置未完成算式，不影响主页面金额。
                Button { clear() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary).frame(width: 36, height: 44) }
                    .accessibilityLabel("清空优惠")
            }.padding(.horizontal, 14).frame(minHeight: 44)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            if let error { InlineError(message: error) }
            GeometryReader { geometry in
                let width = max(0, (geometry.size.width - gap * 3) / 4)
                HStack(alignment: .top, spacing: gap) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: 3), spacing: gap) {
                        // 网格回调输入数字键名，返回仅编辑当前操作数的按键。
                        ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "删除"], id: \.self) { key in
                            Button { input(key) } label: {
                                Group {
                                    if key == "删除" { Image(systemName: "delete.left") }
                                    else { Text(key) }
                                }.font(.title3).frame(maxWidth: .infinity).frame(height: 44)
                                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel(key == "删除" ? "删除一位" : key)
                        }
                    }.frame(width: width * 3 + gap * 2)
                    VStack(spacing: gap) {
                        operatorMenu("+ ×", operations: ["+", "×"])
                        operatorMenu("− ÷", operations: ["−", "÷"])
                        Button { complete() } label: {
                            Text("完成").font(.headline).foregroundStyle(.black)
                                .frame(maxWidth: .infinity).frame(height: 92)
                                .background(Color.yellow, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }.frame(width: width)
                }
            }.frame(height: 188)
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
            .frame(maxWidth: 600).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .presentationDetents([.height(error == nil ? 320 : 360)])
            .task {
                // 初始化回调无参数、无返回值；零值显示占位提示，首次输入替换旧金额。
                guard !populated else { return }; populated = true
                draft = (Decimal(string: value) ?? 0) == 0 ? "" : value
            }
    }
    /// 构建运算选择键；参数：title 为显示文案，operations 为允许的运算符；返回值：选择后暂存当前操作数的菜单，不直接写入金额。
    private func operatorMenu(_ title: String, operations: [String]) -> some View {
        Menu {
            // 菜单回调接收运算符，按钮回调无参数、无返回值，仅更新计算草稿。
            ForEach(operations, id: \.self) { symbol in Button(symbol) { setOperation(symbol) } }
        } label: {
            Text(title).font(.title3).foregroundStyle(.primary).frame(maxWidth: .infinity).frame(height: 44)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    /// 输入数字或删除；参数：key 为键名；返回值：无；文本金额保持两位小数限制，首次数字替换已有金额。
    private func input(_ key: String) {
        draft = AmountKeypad.apply(key, to: draft, replace: replace && key != "删除")
        replace = false; error = nil
    }
    /// 清空当前计算；参数：无；返回值：无；仅修改面板内部状态。
    private func clear() { draft = ""; operand = nil; operation = nil; replace = true; error = nil }
    /// 暂存运算；参数：symbol 为支持的运算符；返回值：无；连续运算按输入顺序计算，重复点击运算符仅替换符号。
    private func setOperation(_ symbol: String) {
        if operation != nil && !replace && !calculate() { return }
        operand = normalized(draft); operation = symbol; replace = true; error = nil
    }
    /// 规范金额文本；参数：raw 为草稿；返回值：空串变为 0、移除末尾小数点后的文本，无副作用。
    private func normalized(_ raw: String) -> String { raw.isEmpty ? "0" : raw.hasSuffix(".") ? String(raw.dropLast()) : raw }
    /// 计算未完成算式；参数：无；返回值：成功为 true；除零、负数或越界保留算式并显示错误，金额按分四舍五入。
    private func calculate() -> Bool {
        guard let operand, let operation else { return true }
        guard let result = AmountKeypad.calculate(operand, operation: operation, rhs: normalized(draft)) else {
            error = "计算结果无效，请检查金额或除数。"; return false
        }
        draft = result; self.operand = nil; self.operation = nil
        return true
    }
    /// 确认优惠；参数：无；返回值：无；校验结果后回写绑定并关闭，失败保留输入，关闭按钮始终可取消。
    private func complete() {
        if operation != nil && replace { error = "请输入第二个金额。"; return }
        guard calculate() else { return }
        let result = normalized(draft)
        guard Values.validMoney(result), let amount = Decimal(string: result), amount >= 0 else { error = "请输入有效优惠金额。"; return }
        if let originalAmount, let original = Decimal(string: originalAmount), original > 0, amount >= original {
            error = "优惠须小于原金额。"; return
        }
        value = result; dismiss()
    }
}
