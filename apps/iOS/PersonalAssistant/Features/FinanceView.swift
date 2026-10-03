import SwiftUI

struct FinanceView: View {
    /// 构建财务首页；参数：无；返回值：默认当月统计、资产滑动卡片及可操作流水，共用流水页面的数据与操作逻辑。
    var body: some View { TransactionsView(financeHome: true) }
}
struct AccountsView: View {
    @Environment(AppStore.self) private var store
    @State private var creating = false
    @State private var edited: FinancialAccount?
    @State private var archived: FinancialAccount?
    @State private var confirmingDeletion = false
    @State private var impact: AccountImpact?
    @State private var error: String?
    @State private var busy = false
    @State private var collapsed: Set<String> = []
    @State private var hideAmounts = false
    /// 生成非空用途分组；参数：无；返回值：目录顺序的组与账户，未知目录时仍显示全部账户。
    private var groups: [(id: String, title: String, accounts: [FinancialAccount])] {
        let sections = AccountKindCatalog.bundled?.sections ?? [.init(id: "funds", title: "资金账户"), .init(id: "credit", title: "信用账户"), .init(id: "investment", title: "理财账户")]
        // 映射回调接收目录分组、返回账户分组；过滤回调去除空组，不丢弃有效账户。
        return sections.map { section in
            (id: section.id, title: section.title, accounts: store.accounts.filter { AccountPresentation.section($0) == section.id })
        }.filter { !$0.accounts.isEmpty }
    }
    /// 构建账户列表；参数：无；返回值：按用途分组的账户及小计，点击查看流水，侧滑修改或删除。
    var body: some View {
        List {
            if let error { InlineError(message: error) }
            if store.accounts.isEmpty { ContentUnavailableView("还没有账户", systemImage: "wallet.bifold") }
            ForEach(groups, id: \.id) { group in
                Section {
                    if !collapsed.contains(group.id) {
                        ForEach(group.accounts) { account in
                            // 导航回调无参数；返回固定账户范围的流水页，返回后保留分组折叠状态。
                            NavigationLink { TransactionsView(scopedAccountID: account.id) } label: { accountRow(account) }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    // 修改回调无参数、无返回值；打开当前账户编辑表单，不触发行导航。
                                    Button { edited = account } label: {
                                        Label("修改", systemImage: "pencil")
                                    }.tint(.accentColor).accessibilityLabel("修改账户：\(account.name)")
                                    // 删除回调无参数、无返回值；先查询影响，再请求确认，禁止整行滑动直接删除。
                                    Button(role: .destructive) { Task { await prepareArchive(account) } } label: {
                                        Label("删除", systemImage: "trash")
                                    }.labelStyle(.iconOnly).tint(.red).accessibilityLabel("删除账户：\(account.name)")
                                }
                        }
                    }
                } header: {
                    // 折叠回调无参数、无返回值；只改变当前组的可见状态，不重新请求数据。
                    Button {
                        withAnimation { if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) } }
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.title).font(.subheadline.bold()).foregroundStyle(Color.primary)
                            Text("(\(group.accounts.count))").font(.caption)
                            Spacer(minLength: 8)
                            let debt = group.id == "credit" || group.id == "payable"
                            Text("\(debt ? "欠款" : "余额"): \(displayAmount(AccountPresentation.total(group.accounts) * (debt ? -1 : 1)))")
                                .font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                            Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.caption)
                        }.foregroundStyle(.secondary).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).textCase(nil)
                        // 移除系统组标题的额外内缩，使标题与账户卡片外缘对齐。
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .accessibilityLabel("\(group.title)，\(group.accounts.count)个账户，\(collapsed.contains(group.id) ? "展开" : "收起")")
                }
            }
        }.listStyle(.insetGrouped).listSectionSpacing(16)
            .navigationTitle("账户").navigationBarTitleDisplayMode(.inline).disabled(busy)
            .refreshable { await reloadAccounts() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 隐私按钮回调无参数、无返回值；隐藏或显示当前列表的账户金额及分组小计。
                    Button(hideAmounts ? "显示金额" : "隐藏金额", systemImage: hideAmounts ? "eye.slash" : "eye") { hideAmounts.toggle() }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加账户", systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) { AccountEditor(account: nil) }.sheet(item: $edited) { AccountEditor(account: $0) }
            .alert("删除账户？", isPresented: $confirmingDeletion, presenting: archived) { account in
                Button("取消", role: .cancel) { archived = nil }
                // 捕获确认时的账户；参数、返回值均无，避免弹窗关闭后异步任务丢失目标。
                Button("删除", role: .destructive) { Task { await archive(account) } }
            } message: { account in
                Text("当前余额 \(Values.money(account.balance))。删除后账户退出列表和当前资产统计；关联的 \(impact?.transactions ?? 0) 笔流水、\(impact?.snapshots ?? 0) 条余额快照保留。")
            }
    }
    /// 格式化可隐藏金额；参数：value 为精确元金额；返回值：金额或隐私占位符，无副作用。
    private func displayAmount(_ value: Decimal) -> String { hideAmounts ? "••••" : AccountPresentation.money(value) }

    /// 绘制账户行；参数：account 为有效账户；返回值：名称旁标注不计入状态、下方显示账户类型，右侧金额保持统一字号与右对齐，不因名称长度缩小；无网络副作用。
    private func accountRow(_ account: FinancialAccount) -> some View {
        let provider = AccountProvider.resolve(type: account.accountType, institution: account.institution)
        let typeName = provider.type == "bank" ? (provider.isCredit ? "信用卡" : "储蓄卡") : provider.name
        return HStack(alignment: .center, spacing: 12) {
            // 图标组件统一裁掉素材外围留白，所有账户采用相同视觉尺寸。
            AccountProviderIcon(provider: provider, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                // 不计入状态紧随名称，不再独占一行；标签保留完整宽度，长名称在剩余空间换行。
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(account.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !account.includeInNetWorth {
                        Text("不计入").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                accountDetail(account, typeName: typeName).font(.caption).foregroundStyle(.secondary)
                if !account.notes.isEmpty { Text(account.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            // 金额列不参与名称的宽度压缩；长名称在左列换行，所有金额沿卡片同一右边距排列。
            VStack(alignment: .trailing, spacing: 5) {
                Text(displayAmount(AccountPresentation.balance(account)))
                    .font(.subheadline).monospacedDigit().foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                if let total = AccountPresentation.loanTotal(account) {
                    Text("总贷款：\(displayAmount(total))").font(.caption).foregroundStyle(.secondary)
                } else {
                    creditAvailable(account).font(.caption).foregroundStyle(.secondary)
                }
            }.multilineTextAlignment(.trailing).layoutPriority(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    /// 绘制类型和最近账期；参数：account 为账户，typeName 为产品类型；返回值：信用账户显示最近日程，普通账户只显示类型。
    private func accountDetail(_ account: FinancialAccount, typeName: String) -> some View {
        let credit = AccountProvider.resolve(type: account.accountType, institution: account.institution).isCredit
        let hint = credit || account.institution == "贷款" ? AccountPresentation.cycleHint(account) : ""
        return Text(hint.isEmpty ? typeName : "[\(typeName)] \(hint)").fixedSize(horizontal: false, vertical: true)
    }

    /// 绘制可用额度；参数：account 为账户；返回值：有额度的信用账户显示精确额度，其余为空视图。
    @ViewBuilder private func creditAvailable(_ account: FinancialAccount) -> some View {
        if account.institution != "贷款", AccountProvider.resolve(type: account.accountType, institution: account.institution).isCredit,
           let value = AccountPresentation.availableCredit(account) {
            Text("可用额度: \(displayAmount(value))").fixedSize()
        }
    }

    /// 刷新账户和资产摘要；参数：无；返回值：无；失败保留现有列表并展示错误。
    private func reloadAccounts() async {
        do { try await store.loadFinance(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    /// 读取删除影响后展示确认；参数：account 为账户；返回值：无；待确认流水或请求失败时不删除。
    private func prepareArchive(_ account: FinancialAccount) async {
        guard !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let result: AccountImpact = try await store.api.request("/finance/accounts/\(account.id)/impact")
            guard (result.pending ?? 0) == 0 else {
                error = "该账户有 \(result.pending ?? 0) 条待确认流水，请先在交易流水中确认或作废后再删除。"
                return
            }
            impact = result; archived = account; confirmingDeletion = true
        }
        catch { self.error = error.localizedDescription }
    }
    /// 执行已确认删除；参数：account 为确认弹窗捕获的账户；返回值：无；保留历史流水，成功后刷新统计。
    private func archive(_ account: FinancialAccount) async {
        guard !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do { try await store.api.mutate("/finance/accounts/\(account.id)", method: "DELETE"); store.accounts.removeAll { $0.id == account.id }; archived = nil; try await store.loadFinance() }
        catch { self.error = error.localizedDescription }
    }
}
private struct AccountImpact: Decodable { let transactions: Int; let snapshots: Int; let pending: Int? }

struct AccountEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: FinancialAccount?
    @State private var loan = LoanAccountDraft()
    /// 判断当前选项是否为贷款；参数：无；返回值：是否启用专属贷款资料，不使用账户名称推断。
    private var isLoan: Bool { provider.institution == "贷款" }
    @State private var name = ""
    @State private var provider = AccountProvider.defaultBank
    @State private var populated = false
    @State private var hasChoice = false
    @State private var choosingProvider = false
    @State private var number = ""
    @State private var cards: [AccountCard] = []
    @State private var balance = "0.00"
    @State private var include = true
    @State private var debt = "0.00"
    @State private var creditLimit = "0.00"
    @State private var billingDay = 0
    @State private var repaymentDay = 0
    @State private var billDayInclusive = true
    @State private var selectable = true
    @State private var amountField = "账户余额"
    @State private var hasPendingAmountCalculation = false
    @State private var reminderDays = -1
    @State private var reminderTime = Calendar.current.date(from: DateComponents(hour: 10)) ?? Date()
    @State private var notes = ""
    @State private var busy = false
    @State private var amountKeyboardVisible = false
    @FocusState private var focusedField: String?
    @State private var error: String?
    @State private var original: [String: Any] = [:]
    /// 规范化名称；参数无；返回去除首尾空白的名称，空值不允许保存。
    private var savedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 规范化选填余额；参数无；返回元金额字符串，空值按零处理。
    private var openingBalance: String { balance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0.00" : balance.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 规范化卡号输入；参数：无；返回值：移除空白的卡号，未修改的历史掩码原样保留；保存层仍只保留尾号。
    private var savedCardNumber: String { number == account?.maskedAccountNumber ? number : number.components(separatedBy: .whitespacesAndNewlines).joined() }
    /// 校验选填卡号；参数：无；返回值：空值、四位尾号、12–19 位完整卡号或未修改的历史掩码为 true，不推断卡片真实性。
    private var validCardNumber: Bool { savedCardNumber.isEmpty || number == account?.maskedAccountNumber || savedCardNumber.range(of: #"^([0-9]{4}|[0-9]{12,19})$"#, options: .regularExpression) != nil }
    /// 校验共用账单的卡片；参数：无；返回值：非信用账户或所有卡片合法时为 true，最多 30 张。
    private var validCards: Bool { !provider.isCredit || isLoan || (cards.count <= 30 && cards.allSatisfy { (try? $0.normalized()) != nil }) }
    /// 构建资料字段；参数无；返回 PATCH/POST 资料，保留历史尾号，不从名称猜测卡号。
    private var fields: [String: Any] {
        var result: [String: Any] = ["name": savedName, "accountType": provider.type, "institution": provider.institution, "maskedAccountNumber": savedCardNumber, "includeInNetWorth": include, "notes": notes, "selectable": selectable]
        if provider.isCredit && !isLoan {
            // 卡片映射回调输入表单卡片、返回白名单资料；脱敏后才进入本机队列，余额仍只属于账户。
            result["cards"] = cards.map { draft in
                let card = (try? draft.normalized()) ?? draft
                return ["id": card.id, "name": card.name, "maskedAccountNumber": card.maskedAccountNumber]
            }
            result["maskedAccountNumber"] = ""
        }
        if isLoan {
            // 合并回调输入旧值与新值，返回新值；未启用计划的旧贷款不补写空字段。
            result.merge(loan.fields) { _, new in new }
            if account != nil { result["currentDebt"] = debt }
            result["reminderDays"] = reminderDays; result["reminderTime"] = reminderTimeText
        } else if provider.isCredit {
            // 合并回调以旧值、新值为输入并返回新值；信用设置仅在信用账户提交。
            result.merge(["currentDebt": debt, "creditLimit": creditLimit, "billingDay": billingDay, "repaymentDay": repaymentDay, "billDayInclusive": billDayInclusive, "reminderDays": reminderDays, "reminderTime": reminderTimeText]) { _, new in new }
        }
        return result
    }
    /// 格式化提醒时间；参数：无；返回值：本地时区的 HH:mm，不依赖语言地区的时制设置。
    private var reminderTimeText: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        return String(format: "%02d:%02d", parts.hour ?? 10, parts.minute ?? 0)
    }
    /// 校验保存条件；参数无；返回名称、余额及文本长度是否满足服务端约束。
    private var valid: Bool { !savedName.isEmpty && savedName.utf8.count <= 128 && provider.institution.utf8.count <= 128 && notes.utf8.count <= 2000 && Values.validMoney(openingBalance) && (!isLoan || loan.valid) && (!provider.isCredit || (Values.validMoney(debt) && Values.validMoney(creditLimit) && !creditLimit.hasPrefix("-") && (reminderDays < 0 || (isLoan ? (loan.enabled || repaymentDay > 0) : repaymentDay > 0)))) }

    var body: some View {
        Group {
            if account == nil && !hasChoice {
                // 首次选择使用独立导航栈，选中后退出所有银行／自定义层级，不创建账户。
                NavigationStack {
                    AccountProviderPicker(selection: $provider) { hasChoice = true }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                }
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 16) {
                            VStack(spacing: 0) {
                                // 机构选择保留真实标志；参数、返回值无，只切换选择路径，不清空资料。
                                Button { focusedField = nil; amountKeyboardVisible = false; choosingProvider = true } label: {
                                    HStack(spacing: 12) {
                                        AccountProviderIcon(provider: provider, size: 44)
                                        Text(provider.name).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        Spacer(minLength: 8)
                                        if provider.type == "bank" {
                                            Text(provider.isCredit ? "信用卡" : "储蓄卡").font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                    }.frame(minHeight: 58).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("选择账户，当前为\(provider.name)")
                                Divider()
                                inputRow("账户名称", text: $name, placeholder: nameExample)
                                if provider.type == "bank" && !isLoan && !provider.isCredit {
                                    Divider()
                                    inputRow("卡号", text: $number, placeholder: "选填")
                                        .keyboardType(.numberPad)
                                }
                                Divider()
                                inputRow("账户备注", text: $notes, placeholder: "点击填写备注（可不填）")
                            }
                            .padding(.horizontal, 18).padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))

                            if provider.isCredit && !isLoan { cardFields }
                            if isLoan {
                                LoanAccountFields(draft: $loan, accountID: account?.id)
                                if account != nil {
                                    amountRow("剩余本金", value: debt)
                                        .padding(.horizontal, 18).padding(.vertical, 6)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
                                }
                            } else if provider.isCredit {
                                VStack(spacing: 0) {
                                    amountRow("当前欠款", value: debt)
                                    Divider()
                                    amountRow("总信用额度", value: creditLimit)
                                    Divider()
                                    dayRow("账单日", selection: $billingDay)
                                    Divider()
                                    dayRow("还款日期", selection: $repaymentDay)
                                    Divider()
                                    Toggle("出账日账单计入当期", isOn: $billDayInclusive).tint(.green).frame(minHeight: 54)
                                }
                                .padding(.horizontal, 18).padding(.vertical, 6)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
                            }
                            VStack(spacing: 0) {
                                if !provider.isCredit {
                                    if account == nil { amountRow("账户余额", value: openingBalance) }
                                    else { LabeledContent("账户余额", value: Values.money(balance)).frame(minHeight: 54) }
                                    Divider()
                                }
                                LabeledContent("账户币种", value: "人民币 (CNY)").frame(minHeight: 54)
                                Divider()
                                Toggle("计入净资产", isOn: $include).tint(.green).frame(minHeight: 54)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
                            if provider.isCredit {
                                VStack(spacing: 0) {
                                    // 菜单选择器在 ScrollView 中不显示自身标题，使用独立标签保证字段名常驻。
                                    LabeledContent("还款提醒") {
                                        Picker("还款提醒", selection: $reminderDays) {
                                            Text("不提醒").tag(-1)
                                            Text("当天提醒").tag(0)
                                            Text("提前一天＋当天").tag(1)
                                            Text("提前三天＋当天").tag(3)
                                            Text("提前七天＋当天").tag(7)
                                        }.pickerStyle(.menu).labelsHidden().tint(.primary)
                                            .accessibilityLabel("还款提醒")
                                    }.frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                    if reminderDays >= 0 {
                                        Divider()
                                        DatePicker("提醒时间", selection: $reminderTime, displayedComponents: .hourAndMinute).frame(minHeight: 54)
                                    }
                                }
                                .padding(.horizontal, 18).padding(.vertical, 6)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
                                if reminderDays >= 0 && !isLoan && repaymentDay == 0 { InlineError(message: "请先设置还款日期。") }
                            }
                            Toggle("记账时可被选择", isOn: $selectable).tint(.green).frame(minHeight: 54)
                                .padding(.horizontal, 18).padding(.vertical, 6)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
                            if provider.isCredit && (!Values.validMoney(debt) || !Values.validMoney(creditLimit) || creditLimit.hasPrefix("-")) {
                                InlineError(message: "请输入有效金额，信用额度不能为负数。")
                            }
                            if !name.isEmpty && savedName.utf8.count > 128 { InlineError(message: "账户名称过长，请缩短。") }
                            if notes.utf8.count > 2000 { InlineError(message: "账户备注过长，请缩短。") }
                            if !validCardNumber { InlineError(message: "请输入 12–19 位卡号或后四位") }
                            if !validCards { InlineError(message: "请填写卡片名称及有效卡号或后四位") }
                            if !Values.validMoney(openingBalance) { InlineError(message: "请输入有效余额，最多两位小数。") }
                            if let error { InlineError(message: error) }
                        }
                        .frame(maxWidth: 600)
                        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 28)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if amountKeyboardVisible {
                            AmountKeyboard(value: amountBinding, hasPendingCalculation: $hasPendingAmountCalculation, title: amountField + " · CNY") {
                                // 完成输入仅收起键盘；参数、返回值无，将中间编辑状态规范化为可保存金额。
                                if amountBinding.wrappedValue == "-" || amountBinding.wrappedValue.isEmpty { amountBinding.wrappedValue = "0" }
                                if amountBinding.wrappedValue.hasSuffix(".") { amountBinding.wrappedValue.removeLast() }
                                amountKeyboardVisible = false
                            }.id(amountField)
                        }
                    }
                    .onChange(of: focusedField) { _, field in
                        // 开始输入名称或备注时收起金额键盘；field 为新焦点，返回无。
                        if field != nil { amountKeyboardVisible = false }
                    }
                    .navigationTitle(account == nil ? "添加账户" : "编辑账户").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            // 返回保持本次草稿；参数、返回值无，新建回到账户选择，编辑关闭资料页。
                            Button {
                                focusedField = nil; amountKeyboardVisible = false
                                if account == nil { hasChoice = false } else { dismiss() }
                            } label: {
                                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                            }.accessibilityLabel(account == nil ? "返回选择账户" : "取消编辑").disabled(busy)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            // 提交回调参数、返回值无；仅显式点击创建／保存才执行网络写入。
                            Button { Task { await save() } } label: {
                                Group {
                                    if busy { ProgressView().tint(.white) }
                                    else { Image(systemName: "checkmark").font(.title3.weight(.semibold)) }
                                }
                                .frame(width: 44, height: 44)
                                .foregroundStyle(.white)
                                .background(valid && !hasPendingAmountCalculation ? Color.accentColor : Color.secondary, in: Circle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(account == nil ? "创建账户" : "保存账户")
                                .disabled(busy || !valid || !validCardNumber || !validCards || hasPendingAmountCalculation)
                        }
                    }
                    .disabled(busy)
                    .navigationDestination(isPresented: $choosingProvider) {
                        AccountProviderPicker(selection: $provider) { choosingProvider = false }
                    }
                }
            }
        }.interactiveDismissDisabled(busy).task { populate() }
    }
    /// 返回当前金额草稿绑定；参数：无；返回值：欠款、额度或余额绑定，不执行保存。
    private var amountBinding: Binding<String> {
        switch amountField {
        case "当前欠款", "剩余本金": return $debt
        case "总信用额度": return $creditLimit
        default: return $balance
        }
    }
    /// 绘制金额入口；参数：title 为字段名，value 为金额草稿；返回值：打开专用键盘的按钮，无网络副作用。
    private func amountRow(_ title: String, value: String) -> some View {
        // 点击回调无参数、无返回值；结束文本输入并切换金额编辑目标。
        Button { focusedField = nil; amountField = title; amountKeyboardVisible = true } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }.frame(minHeight: 54).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(value) 元，点击输入")
    }
    /// 绘制带常驻左侧标签的每月日期选择；参数：title 为标签，selection 为 0（未设置）或 1 至 31 的日期绑定；返回值：右侧原位菜单，无网络副作用。
    private func dayRow(_ title: String, selection: Binding<Int>) -> some View {
        LabeledContent(title) {
            Picker(title, selection: selection) {
                Text("未设置").tag(0)
                // 日期行构造回调；参数 day 为合法日号；返回值为带选择标签的文本。
                ForEach(1...31, id: \.self) { day in Text("每月\(day)日").tag(day) }
            }.pickerStyle(.menu).labelsHidden().tint(.primary)
                .accessibilityLabel(title)
        }.frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
    }
    /// 按选中机构提供名称示例；参数无；返回占位文本，不替用户自动命名。
    private var nameExample: String {
        if provider.type == "bank" { return "如：\(provider.name)\(provider.isCredit ? "信用卡" : "储蓄卡") 8888" }
        return "如：我的\(provider.name)"
    }

    /// 绘制可自适应输入行；参数：title 为固定标签，text 为草稿绑定，placeholder 为示例；返回输入视图，无网络副作用。
    private func inputRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                Text(title).fixedSize()
                TextField(title, text: text, prompt: Text(placeholder), axis: .vertical)
                    .multilineTextAlignment(.trailing).frame(minWidth: 160)
                    .focused($focusedField, equals: title)
                    .lineLimit(1...4).accessibilityLabel(title == "账户名称" ? "账户名称，必填" : title)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                TextField(title, text: text, prompt: Text(placeholder), axis: .vertical)
                    .focused($focusedField, equals: title)
                    .lineLimit(1...5).accessibilityLabel(title == "账户名称" ? "账户名称，必填" : title)
            }
        }.frame(minHeight: 54).padding(.vertical, 6)
    }
    /// 构建共用账单卡片表单；参数：无；返回值：可添加、编辑和删除卡片的内联区域，操作仅改变草稿。
    private var cardFields: some View {
        AccountCardWallet(cards: $cards, provider: provider, accountID: account?.id)
    }
    /// 首次初始化；参数无；返回无；编辑保留全部原值，新建必须先选择账户，返回时不重置草稿，旧信用卡尾号显示为首张卡。
    private func populate() {
        guard !populated else { return }
        populated = true
        if let account { hasChoice = true; name = account.name; provider = .resolve(type: account.accountType, institution: account.institution); number = account.maskedAccountNumber; balance = account.balance; include = account.includeInNetWorth; notes = account.notes }
        cards = account?.cards ?? []
        if cards.isEmpty, provider.isCredit, !isLoan, !number.isEmpty {
            cards = [AccountCard(id: "legacy", name: name, maskedAccountNumber: number)]
        }
        loan = LoanAccountDraft(account: account)
        if let account {
            debt = account.balance.hasPrefix("-") ? String(account.balance.dropFirst()) : (Decimal(string: account.balance) == 0 ? "0.00" : "-" + account.balance)
            creditLimit = account.creditLimit ?? "0.00"
            reminderDays = account.reminderDays ?? -1
            // 时间解析回调将数字分量转为整数，非法分量忽略，完整两段才回显。
            let time = (account.reminderTime ?? "10:00").split(separator: ":").compactMap { Int($0) }
            if time.count == 2 { reminderTime = Calendar.current.date(from: DateComponents(hour: time[0], minute: time[1])) ?? reminderTime }
            billingDay = account.billingDay ?? 0; repaymentDay = account.repaymentDay ?? 0
            billDayInclusive = account.billDayInclusive ?? true; selectable = account.selectable ?? true
        }
        original = fields
        // 旧单卡字段以真实持久值作为 PATCH 基线，迁移卡片时清除旧入口，避免删除卡片后仍按旧尾号命中。
        if provider.isCredit && !isLoan, let account {
            original["maskedAccountNumber"] = account.maskedAccountNumber
            original["cards"] = (account.cards ?? []).map { ["id": $0.id, "name": $0.name, "maskedAccountNumber": $0.maskedAccountNumber] }
        }
    }
    /// 保存资料；参数无；返回无；阻止重复提交及空名称，PATCH 仅实际变化；信用欠款校准由服务端留存快照，普通期初余额仅创建时发送。
    private func save() async {
        guard !busy, valid, validCardNumber, validCards else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            // 显式启用提醒时才请求系统权限；拒绝则留在表单，避免保存一个无法执行的提醒。
            if provider.isCredit && reminderDays >= 0 && !store.isPreview {
                guard try await CreditReminders.authorize() else { error = "请在系统设置中允许通知，或关闭还款提醒。"; return }
            }
            if let account {
                let patch = Values.patch(original: original, edited: fields)
                if !patch.isEmpty { try await store.api.mutate("/finance/accounts/\(account.id)", method: "PATCH", body: patch) }
            } else {
                var body = fields; if !provider.isCredit && !isLoan { body["balance"] = openingBalance }; body["currency"] = "CNY"
                try await store.api.mutate("/finance/accounts", body: body)
            }
            dismiss(); await store.refreshAfterMutation(.finance)
        } catch { self.error = error.localizedDescription }
    }
}
