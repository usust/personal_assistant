import SwiftUI

nonisolated struct ConsumptionInstallmentPlan: Decodable {
    var categoryId: Int? = nil
    var description: String? = nil
    let name: String
    let periods: Int
    var interestCreditMode: String? = nil
    var debtMode: String? = nil
    var startPeriod: Int? = nil
    var restoredCredit: String? = nil
    let firstDate: String
    let interest: String
    let interestMode: String
    let rounding: String
    let remainder: String
    let principal: String
    let total: String
    let posted: Int
    let rows: [ConsumptionInstallmentRow]
}
nonisolated struct ConsumptionInstallmentRow: Decodable, Identifiable {
    var id: Int { period }
    let period: Int
    let date: String
    let principal: String
    let interest: String
    let amount: String
    let transactionId: Int
    let status: String
}

struct ConsumptionInstallmentView: View {
    let bill: FinanceTransaction
    var editingExisting = false
    @Environment(\.dismiss) private var dismiss
    @State private var originalPayload: [String: Any] = [:]
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var categoryID = 0
    @State private var notes = ""
    @State private var editingNotes = false
    // 预留开关仅保存本次页面状态，默认关闭；不提交接口、不参与试算或统计，后续再接入业务。
    @State private var reimbursement = false
    @State private var excludeFromCashFlow = false
    @State private var excludeFromBudget = false
    @State private var periods = 0
    @State private var editingPeriods = false
    // 起始期数控制生成范围；专项恢复额只影响可用额度，不作为收入或余额入账。
    @State private var startPeriod = 1
    @State private var restoredCredit = ""
    @State private var editingStartPeriod = false
    @State private var editingRestoredCredit = false
    @State private var firstDate = Date.now
    @State private var interest = "0.00"
    @State private var debtMode = "spread"
    @State private var interestCreditMode = "spread"
    @State private var interestMode = "spread"
    @State private var rounding = "round"
    @State private var remainder = "first"
    @State private var plan: ConsumptionInstallmentPlan?
    @State private var saved = false
    @State private var busy = false
    @State private var error: String?
    @State private var activeOption: InstallmentOption?
    @State private var editingName = false
    @State private var initialized = false
    /// 判断是否可试算；参数：无；返回值：名称非空、期数为 2–480 且利息金额合法时为 true。
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (2...480).contains(periods) && startPeriod >= 1 && startPeriod <= periods && Values.validMoney(interest, positive: false) }
    /// 构建消费分期表单；参数：无；返回值：名称入口、账单资料、预留开关、分期规则和试算结果。
    var body: some View {
        Form {
            if !saved {
                Section("账单信息") {
                    // 名称保持标签和值分离；点击整行打开编辑，取消不会改动草稿。
                    Button { editingName = true } label: {
                        HStack(spacing: 16) {
                            Text("分期名称").foregroundStyle(.primary).fixedSize()
                            Spacer(minLength: 0)
                            Text(name.isEmpty ? "点此设置" : name)
                                .foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("分期名称，\(name.isEmpty ? "点此设置" : name)")
                    LabeledContent("分期本金", value: Values.money(bill.amount))
                    LabeledContent("分期账户", value: store.accounts.first { $0.id == bill.accountId }?.name ?? "已归档账户")
                    LabeledContent("账单币种", value: "人民币 (CNY)")
                }
                Section {
                    TransactionCategorySelector(title: "账单分类", type: "expense", selection: $categoryID)
                    Button { editingNotes = true } label: {
                        HStack(spacing: 16) {
                            Text("账单备注").foregroundStyle(.primary).fixedSize()
                            Spacer(minLength: 0)
                            Text(notes.isEmpty ? "点此设置" : notes).foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Section {
                    Toggle("是否报销", isOn: $reimbursement)
                    Toggle("不计收支", isOn: $excludeFromCashFlow)
                    Toggle("不计预算", isOn: $excludeFromBudget)
                }
                Section("分期设置") {
                    Button { editingPeriods = true } label: {
                        HStack(spacing: 16) {
                            Text("分期总期数").foregroundStyle(.primary).fixedSize()
                            Spacer(minLength: 0)
                            Text(periods == 0 ? "点此设置" : "\(periods) 期").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    DatePicker("首期入账日期", selection: $firstDate, displayedComponents: .date)
                    settingRow("开始生成账单的期数", value: startPeriod == 0 ? "点此设置" : "第 \(startPeriod) 期") { editingStartPeriod = true }
                    settingRow("额度恢复（分期专项额度）", value: restoredCredit.isEmpty ? "点此设置（可不填）" : Values.money(restoredCredit)) { editingRestoredCredit = true }
                    settingRow("欠款计入方式", value: debtMode == "upfront" ? "创建时一次性计入" : "分期计入") { activeOption = .debt }
                }
                Section("利息") {
                    HStack { Text("利息总额"); TextField("0.00", text: $interest).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    settingRow("利息入账方式", value: interestMode == "first" ? "首期入账" : "分期入账") { activeOption = .interest }
                    settingRow("利息占用额度方式", value: interestCreditMode == "upfront" ? "创建时一次性占用" : "分期占用") { activeOption = .interestCredit }
                }
                Section("余数计算规则") {
                    settingRow("计算方式", value: rounding == "floor" ? "向下取整" : "四舍五入") { activeOption = .rounding }
                    LabeledContent("计算精度", value: "小数点后 2 位")
                    settingRow("分期后差额纳入", value: remainder == "last" ? "末期" : "首期") { activeOption = .remainder }
                    // 点击回调无参数、无返回值；整行居中展示，沿用原有试算及禁用条件。
                    Button { Task { await preview() } } label: {
                        Text("试算分期").frame(maxWidth: .infinity, alignment: .center)
                            .contentShape(Rectangle())
                    }.disabled(!valid || busy)
                }
            }
            if let plan {
                Section(saved ? plan.name : "分期试算") {
                    LabeledContent("本息合计", value: Values.money(plan.total))
                    LabeledContent("开始生成账单的期数", value: "第 \(max(1, plan.startPeriod ?? 1)) 期")
                    LabeledContent("利息占用额度方式", value: plan.interestCreditMode == "upfront" ? "创建时一次性占用" : "分期占用")
                    LabeledContent("额度恢复", value: Values.money(plan.restoredCredit ?? "0.00"))
                    LabeledContent("欠款计入方式", value: plan.debtMode == "upfront" ? "创建时一次性计入" : "分期计入")
                    LabeledContent("入账进度", value: "\(plan.posted) / \(plan.rows.count)")
                }
                Section("每期账单") {
                    ForEach(plan.rows) { row in
                        if saved && row.status != "deleted" {
                            // 详情变更回调无参数、无返回值；读取最新计划，保留当前页面及分期规则。
                            NavigationLink {
                                InstallmentTransactionDetail(transactionID: row.transactionId) { await reload() }
                            } label: { installmentRow(row) }
                        } else {
                            installmentRow(row)
                        }
                    }
                }
            }
            if let error { InlineError(message: error) }
        }
        .navigationTitle(editingExisting ? "编辑消费分期" : "消费分期").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editingExisting {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
            }
            if !saved {
                ToolbarItem(placement: .confirmationAction) {
                    // 点击回调无参数、无返回值；有效试算后直接保存，提交期间阻止重复操作。
                    Button { Task { await save() } } label: {
                        Image(systemName: "checkmark").font(.title3.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("保存分期")
                        .disabled(busy || !valid || plan == nil)
                }
            }
        }
        .disabled(busy).interactiveDismissDisabled(busy).navigationBarBackButtonHidden(busy)
        .task { await initialize() }
        .sheet(item: $activeOption) { option in
            InstallmentOptionSheet(option: option, selection: optionBinding(option))
                .presentationDetents([.height(240)])
                .presentationDragIndicator(.visible)
                .presentationCompactAdaptation(.sheet)
        }
        .sheet(isPresented: $editingStartPeriod) {
            InstallmentPeriodsEditor(periods: $startPeriod, title: "开始生成账单的期数", minimum: 1, maximum: periods > 0 ? periods : 480)
        }
        .sheet(isPresented: $editingRestoredCredit) { InstallmentRecoveryEditor(amount: $restoredCredit) }
        .onChange(of: periods) { _, value in
            // 总期数减少时清除越界起始期，防止保留自相矛盾的输入。
            if startPeriod > value { startPeriod = 0 }
        }
        .sheet(isPresented: $editingPeriods) { InstallmentPeriodsEditor(periods: $periods) }
        .sheet(isPresented: $editingName) { InstallmentNameEditor(name: $name) }
        .sheet(isPresented: $editingNotes) { InstallmentNameEditor(name: $notes, title: "账单备注", allowsEmpty: true, byteLimit: 2000) }
        .onChange(of: draftKey) { _, _ in if !saved { plan = nil } }

    }
    /// 返回选项对应的草稿绑定；参数：option 为本页支持的设置项；返回值：字段双向绑定，选择后触发原有试算失效机制。
    private func optionBinding(_ option: InstallmentOption) -> Binding<String> {
        switch option {
        case .debt: return $debtMode
        case .interestCredit: return $interestCreditMode
        case .interest: return $interestMode
        case .rounding: return $rounding
        case .remainder: return $remainder
        }
    }
    /// 绘制单期期次摘要；参数：row 为试算或已保存计划中的期次；返回值：金额、日期和真实状态，已删除期次仅保留审计展示。
    private func installmentRow(_ row: ConsumptionInstallmentRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("第 \(row.period) 期"); Spacer(); Text(Values.money(row.amount)).monospacedDigit() }
            Text("\(row.date) · 本金 \(row.principal) · 利息 \(row.interest)").font(.caption).foregroundStyle(.secondary)
            if saved {
                Text(row.status == "posted" ? "已入账" : row.status == "deleted" ? "已删除" : "待入账")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    /// 绘制右箭头设置行；参数：title 为字段名，value 为当前值或占位，action 为无参数无返回值的打开编辑回调；返回值：支持窄屏换行的入口。
    private func settingRow(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    /// 生成试算失效标识；参数：无；返回值：资料或规则变化时不同的草稿键。
    private var draftKey: String { "\(interestCreditMode)|\(debtMode)|\(startPeriod)|\(restoredCredit)|\(categoryID)|\(notes)|\(name)|\(periods)|\(Values.day(firstDate))|\(interest)|\(interestMode)|\(rounding)|\(remainder)" }
    /// 生成分期请求；参数：无；返回值：包含分类与备注的规则，分类 0 和空备注表示显式清空。
    private var payload: [String: Any] { ["interestCreditMode": interestCreditMode, "debtMode": debtMode, "startPeriod": startPeriod, "restoredCredit": restoredCredit.isEmpty ? "0.00" : restoredCredit, "categoryId": categoryID, "description": notes, "name": name, "periods": periods, "firstDate": Values.day(firstDate), "interest": interest, "interestMode": interestMode, "rounding": rounding, "remainder": remainder] }
    /// 初始化账单分期；参数：无；返回值：无，已保存时读取服务端计划，失败保留错误。
    private func initialize() async {
        guard !initialized else { return }
        initialized = true
        categoryID = bill.categoryId ?? 0; notes = bill.description
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        firstDate = formatter.date(from: bill.transactionDate) ?? .now
        if bill.status == "installment" || bill.installmentParentId != nil {
            saved = !editingExisting
            await reload()
            if editingExisting, let current = plan {
                name = current.name; periods = current.periods
                firstDate = formatter.date(from: current.firstDate) ?? firstDate
                startPeriod = max(1, current.startPeriod ?? 1)
                restoredCredit = current.restoredCredit ?? "0.00"
                debtMode = current.debtMode?.isEmpty == false ? current.debtMode! : "spread"
                interestCreditMode = current.interestCreditMode?.isEmpty == false ? current.interestCreditMode! : "spread"
                interest = current.interest; interestMode = current.interestMode
                rounding = current.rounding; remainder = current.remainder
                categoryID = current.categoryId ?? bill.categoryId ?? 0
                notes = current.description ?? bill.description
                originalPayload = payload
                plan = nil
            }
        }
    }
    private var parentID: Int { bill.installmentParentId ?? bill.id }
    /// 重载完整计划；参数：无；返回值：无，失败显示错误，切换登录后丢弃旧结果。
    private func reload() async {
        let session = store.sessionID
        busy = true; defer { busy = false }
        do {
            let result: ConsumptionInstallmentPlan = try await store.api.request("/finance/transactions/\(parentID)/installment")
            guard session == store.sessionID else { return }
            plan = result; error = nil
        } catch { self.error = error.localizedDescription }
    }
    /// 请求权威试算；参数：无；返回值：无，不写账本，失败清除旧试算。
    private func preview() async {
        guard !busy else { return }
        let session = store.sessionID
        busy = true; defer { busy = false }; plan = nil
        do {
            let result: ConsumptionInstallmentPlan = try await store.api.request("/finance/transactions/\(bill.id)/installment-preview", method: "POST", body: payload)
            guard session == store.sessionID else { return }
            plan = result; error = nil
        }
        catch { self.error = error.localizedDescription }
    }
    /// 保存已试算规则；参数：无；返回值：无，创建使用转换接口，编辑仅 PATCH 实际改变字段，后端原子重算账单与余额，成功刷新账户并关闭编辑页。
    private func save() async {
        guard !busy && !saved && valid && plan != nil else { return }
        let session = store.sessionID
        busy = true; defer { busy = false }
        do {
            var fields = payload
            if editingExisting {
                // 比较闭包输入键值对，输出字段是否实际变化；保留显式零值和空备注。
                fields = payload.filter { key, value in
                    guard let original = originalPayload[key] as? NSObject, let current = value as? NSObject else { return true }
                    return !original.isEqual(current)
                }
                if fields.isEmpty { dismiss(); return }
            }
            let path = editingExisting ? "/finance/installments/\(bill.id)" : "/finance/transactions/\(bill.id)/installment"
            let result: ConsumptionInstallmentPlan = try await store.api.request(path, method: editingExisting ? "PATCH" : "POST", body: fields)
            guard session == store.sessionID else { return }
            plan = result; saved = true; error = nil; await store.refreshAfterMutation(.finance)
            if editingExisting { dismiss() }
        }
        catch { self.error = error.localizedDescription }
    }

}

/// 名称编辑使用独立草稿，只有完成才回写分期表单。
private struct InstallmentNameEditor: View {
    @Binding var name: String
    var title = "分期名称"
    var allowsEmpty = false
    var byteLimit = 128
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// 构建名称编辑面板；参数：无；返回值：输入框及取消、完成操作，允许清空和长度限制由调用方配置。
    var body: some View {
        NavigationStack {
            Form {
                TextField("请输入\(title)", text: $draft, axis: .vertical).lineLimit(1...4).focused($focused).submitLabel(.done)
                    .onSubmit { commit() }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { commit() }.disabled(!valid) }
                }
                .task { draft = name; focused = true }
        }.presentationDetents([.height(180)]).presentationDragIndicator(.visible)
    }
    /// 校验名称草稿；参数：无；返回值：符合调用方空值规则且不超过接口长度限制。
    private var valid: Bool {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (allowsEmpty || !value.isEmpty) && value.utf8.count <= byteLimit
    }
    /// 确认名称；参数：无；返回值：无，合法草稿回写绑定并关闭面板，否则保留输入。
    private func commit() {
        guard valid else { return }
        name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}

/// 分期期数编辑仅暂存输入，确认合法后回写主表单。
private struct InstallmentPeriodsEditor: View {
    @Binding var periods: Int
    var title = "分期总期数"
    var minimum = 2
    var maximum = 480
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// 解析期数；参数：无；返回值：配置范围内的纯数字整数，空值、小数、符号或越界输入返回 nil。
    private var value: Int? {
        guard !draft.isEmpty, draft.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = Int(draft), (minimum...maximum).contains(number) else { return nil }
        return number
    }
    /// 构建底部数字输入面板；参数：无；返回值：期数输入及取消、完成按钮，非法输入显示简短校验错误。
    var body: some View {
        NavigationStack {
            Form {
                TextField("请输入期数", text: $draft).keyboardType(.numberPad).focused($focused)
                if !draft.isEmpty && value == nil { Text("请输入 \(minimum)–\(maximum) 的整数").font(.caption).foregroundStyle(.red) }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { commit() }.disabled(value == nil) }
                }
                .task { draft = periods == 0 ? "" : String(periods); focused = true }
        }.presentationDetents([.height(200)]).presentationDragIndicator(.visible)
    }
    /// 确认期数；参数：无；返回值：无；仅合法输入回写并关闭，取消或非法输入不影响原期数。
    private func commit() {
        guard let value else { return }
        periods = value; dismiss()
    }
}

/// 可选的额度恢复输入，仅确认后回写页面草稿。
private struct InstallmentRecoveryEditor: View {
    @Binding var amount: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// 校验额度；参数：无；返回值：允许不填或合法非负金额，最多两位小数。
    private var valid: Bool { draft.isEmpty || Values.validMoney(draft, positive: false) }
    /// 构建额度输入面板；参数：无；返回值：可取消、可清空的十进制输入框。
    var body: some View {
        NavigationStack {
            Form {
                TextField("请输入金额（可不填）", text: $draft).keyboardType(.decimalPad).focused($focused)
                if !valid { Text("请输入有效金额，最多两位小数").font(.caption).foregroundStyle(.red) }
            }.navigationTitle("额度恢复").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { commit() }.disabled(!valid) }
                }.task { draft = amount; focused = true }
        }.presentationDetents([.height(200)]).presentationDragIndicator(.visible)
    }
    /// 确认可选金额；参数：无；返回值：无；合法输入回写草稿，空字符串表示未设置。
    private func commit() {
        guard valid else { return }
        amount = draft; dismiss()
    }
}

/// 分期设置中的有限选项，共用底部选择面板。
private enum InstallmentOption: String, Identifiable {
    case debt, interestCredit, interest, rounding, remainder
    /// 返回面板标识；参数：无；返回值：稳定的设置项键。
    var id: String { rawValue }
    /// 返回面板标题；参数：无；返回值：与表单入口一致的名称。
    var title: String {
        switch self {
        case .debt: return "欠款计入方式"
        case .interestCredit: return "利息占用额度方式"
        case .interest: return "利息入账方式"
        case .rounding: return "计算方式"
        case .remainder: return "分期后差额纳入"
        }
    }
    /// 返回允许选项；参数：无；返回值：服务端键与用户文案组成的有序列表。
    var choices: [(value: String, title: String)] {
        switch self {
        case .debt: return [("spread", "分期计入"), ("upfront", "创建时一次性计入")]
        case .interestCredit: return [("spread", "分期占用"), ("upfront", "创建时一次性占用")]
        case .interest: return [("spread", "分期入账"), ("first", "首期入账")]
        case .rounding: return [("round", "四舍五入"), ("floor", "向下取整")]
        case .remainder: return [("first", "首期"), ("last", "末期")]
        }
    }
}

/// 底部选项面板，点击立即回写并关闭，取消保持原选择。
private struct InstallmentOptionSheet: View {
    let option: InstallmentOption
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    /// 绘制底部选项；参数：无；返回值：标题、选项及取消入口，不执行保存请求。
    var body: some View {
        VStack(spacing: 0) {
            Text(option.title).font(.headline).padding(.top, 24).padding(.bottom, 12)
            ForEach(option.choices, id: \.value) { choice in
                // 点击回调无参数、无返回值；只修改当前字段并关闭选项面板。
                Button {
                    selection = choice.value
                    dismiss()
                } label: {
                    HStack {
                        Text(choice.title)
                        Spacer()
                    }.padding(.horizontal, 24).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .accessibilityAddTraits(selection == choice.value ? .isSelected : [])
            }
            Button("取消") { dismiss() }.padding(.top, 12)
            Spacer(minLength: 0)
        }
    }
}
