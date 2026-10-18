import SwiftUI

/// 用户主动粘贴文本后本机识别，所有关键字段经明确确认才保存；原文仅存在本页内存。
struct TextBookkeepingView: View {
    var initialAccountID: Int? = nil
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var draft = TextBookkeepingDraft()
    @State private var note = ""
    @State private var date = Calendar.current.startOfDay(for: .now)
    @State private var dateWasAdjusted = false
    @State private var reviewing = false
    @State private var loading = true
    @State private var busy = false
    @State private var saved = false
    @State private var invalidated = false
    @State private var error: String?
    @State private var submission = TextBookkeepingSubmission()
    @State private var originLedger: FinanceLocalStore?
    @State private var originSessionID: UUID?
    @State private var originCloudSessionID: UUID?
    @State private var originSpaceKey: String?
    @State private var originServer = ""
    @State private var originToken: String?

    /// 检查草稿所属空间和会话；参数：无；返回值：本机路由、账本对象及身份均未变化时 true；禁止预览或登录切换期间写入，防止回退网络保存。
    private var isCurrent: Bool {
        !invalidated && !store.isPreview && !store.isAuthenticating && originLedger != nil &&
        store.finance === originLedger && store.api.localFinance === originLedger && store.api.localFinanceError == nil &&
        store.sessionID == originSessionID && store.cloudSessionID == originCloudSessionID &&
        store.finance?.activeKey == originSpaceKey && store.api.baseURL == originServer && store.api.token == originToken
    }

    /// 读取允许记账的人民币账户；参数：无；返回值：当前空间真实账户，不自动选择第一项；无副作用。
    private var accounts: [FinancialAccount] { store.accounts.filter { $0.selectable != false && $0.currency == "CNY" } }

    /// 检查确认表单；参数：无；返回值：全部必要字段有效且属于原会话时 true；不自动补金额、分类或账户。
    private var valid: Bool {
        isCurrent && ["expense", "income", "transfer"].contains(draft.type) &&
        TextBookkeepingParser.canonicalAmount(draft.amount) != nil && !draft.dateNeedsCorrection &&
        TextBookkeepingParser.date(day: draft.day, time: draft.time) != nil &&
        accounts.contains(where: { $0.id == draft.accountID }) &&
        (draft.type != "transfer" || (draft.accountID != draft.targetAccountID && accounts.contains(where: { $0.id == draft.targetAccountID }))) &&
        (draft.type == "transfer" || draft.categoryID == 0 || store.categories.contains(where: { !$0.deleted && $0.id == draft.categoryID && $0.type == draft.type })) &&
        draft.counterparty.utf8.count <= 128 && note.utf8.count <= 2000
    }

    /// 构建输入与候选确认两步表单；参数：无；返回值：复用系统颜色、统一分类入口及日期控件的页面；取消不写入，提交期间保护关闭与重复点击。
    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineError(message: error) } }
                if loading { Section { ProgressView("加载账户…") } }
                if reviewing { confirmationFields } else { inputFields }
            }
            .disabled(busy || loading || invalidated)
            .navigationTitle(reviewing ? "确认记账" : "文本记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 取消回调无参数、返回值无；只丢弃内存文本和草稿，保存期间不能关闭。
                    Button("取消") { text = ""; dismiss() }.disabled(busy)
                }
                if reviewing {
                    ToolbarItem(placement: .confirmationAction) {
                        // 确认回调无参数、返回值无；只启动一次显式提交，字段未补全时不可保存。
                        Button("确认记账") { Task { await save() } }.disabled(busy || saved || !valid)
                    }
                }
            }
            // 首次任务无参数、返回值无；只读取本机账户和分类，不外发用户文本。
            .task { await loadOptions() }
            // 类型回调接收新旧类型、返回值无；清理不兼容分类，避免把收入分类带入支出或转账。
            .onChange(of: draft.type) { _, value in
                if value == "transfer" || store.categories.first(where: { !$0.deleted && $0.id == draft.categoryID })?.type != value { draft.categoryID = 0 }
            }
            // 以下身份观察回调接收新旧标识、返回值无；原空间失效后立即清理敏感文本并禁止继续保存。
            .onChange(of: store.sessionID) { _, _ in invalidate() }
            .onChange(of: store.cloudSessionID) { _, _ in invalidate() }
            .onChange(of: store.finance?.activeKey) { _, _ in invalidate() }
            .onChange(of: store.api.baseURL) { _, _ in invalidate() }
            .onChange(of: store.api.token) { _, _ in invalidate() }
            .onChange(of: store.isAuthenticating) { _, value in if value { invalidate() } }
        }
        .interactiveDismissDisabled(busy)
    }

    /// 构建主动粘贴入口；参数：无；返回值：多行系统文本框及“识别”按钮，不读取剪贴板或系统短信，不自动触发解析。
    private var inputFields: some View {
        Section {
            TextEditor(text: $text).frame(minHeight: 220).privacySensitive()
                .accessibilityLabel("交易文本")
            if text.count > TextBookkeepingParser.maximumLength { InlineError(message: "单次最多识别 4000 字符") }
            // 识别回调无参数、返回值无；只在点击后执行本机规则，不创建交易或请求 AI。
            Button("识别", action: recognize)
                .disabled(!isCurrent || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > TextBookkeepingParser.maximumLength)
        } header: { Text("交易文本") } footer: { Text("仅在本机识别") }
    }

    /// 展示全部入账关键字段；参数：无；返回值：可修改类型、金额、账户、分类、日期时间、交易对象和备注的确认表单，原文不作为备注或请求字段。
    @ViewBuilder private var confirmationFields: some View {
        if !dateWasAdjusted {
            let notices = draft.notices.filter { $0 != "请选择账户" && $0 != "请选择交易类型" }
            if !notices.isEmpty {
                Section {
                    ForEach(notices, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        Section {
            Picker("类型", selection: $draft.type) {
                if draft.type.isEmpty { Text("请选择").tag("") }
                Text("支出").tag("expense"); Text("收入").tag("income"); Text("转账").tag("transfer")
            }
            HStack {
                Text("金额（元）")
                TextField("请填写", text: $draft.amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .accessibilityLabel("金额（元）")
            }
            accountPicker(draft.type == "transfer" ? "转出账户" : "账户", selection: $draft.accountID)
            if draft.type == "transfer" { accountPicker("转入账户", selection: $draft.targetAccountID, excluding: draft.accountID) }
            if ["expense", "income"].contains(draft.type) {
                TransactionCategorySelector(title: "分类", type: draft.type, selection: $draft.categoryID)
            }
            SystemDateTimeInput(title: "日期和时间", selection: dateSelection,
                                displayValue: draft.dateNeedsCorrection ? "请重新设置" : nil)
            TextField("交易对象", text: $draft.counterparty)
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...5)
        }
        Section {
            // 回改回调无参数、返回值无；回到保留的内存原文，不写入或重置重试请求 ID。
            Button("修改原文") { reviewing = false; error = nil }
            if busy { ProgressView("保存中…") }
        }
    }

    /// 构建原生账户选择字段；参数：title 为字段标题、selection 为草稿 ID 绑定、excluding 为需排除的转出账户；返回值：带空占位的真实账户选择器，无默认第一项或写入副作用。
    private func accountPicker(_ title: String, selection: Binding<Int>, excluding: Int = 0) -> some View {
        Picker(title, selection: selection) {
            Text("请选择").tag(0)
            ForEach(accounts.filter { $0.id != excluding }) { account in Text(account.name).tag(account.id) }
        }
    }

    /// 连接共用日期选择面板；参数：无；返回值：读取当前候选、仅在用户确认后清除非法日期标记的绑定；无账本副作用。
    private var dateSelection: Binding<Date> {
        // 读取回调无参数、返回面板初值；写入回调接收确认后的时刻、返回值无，缺失/非法原文不被静默替换。
        Binding(get: { date }, set: { value in
            date = value; draft.day = Values.day(value); draft.time = Values.time(value)
            draft.dateNeedsCorrection = false; dateWasAdjusted = true
        })
    }

    /// 读取本机表单选项并绑定原会话；参数：无；返回值：无；路由不可用不走网络，失败显示错误，不覆盖其他会话。
    private func loadOptions() async {
        guard originSessionID == nil else { return }
        originSessionID = store.sessionID; originCloudSessionID = store.cloudSessionID
        originLedger = store.finance; originSpaceKey = store.finance?.activeKey
        originServer = store.api.baseURL; originToken = store.api.token
        defer { loading = false }
        guard isCurrent else { invalidate(); return }
        do {
            try await store.loadFinance()
            guard isCurrent else { invalidate(); return }
        } catch { if isCurrent { self.error = error.localizedDescription } }
    }

    /// 在本机解析用户原文并进入确认；参数：无；返回值：无；不支持的交易留在输入页，未知字段留空，原文不落盘或外发。
    private func recognize() {
        guard isCurrent, !busy, !saved else { return }
        let result = TextBookkeepingParser.parse(text, accounts: store.accounts, categories: store.categories, initialAccountID: initialAccountID)
        guard result.blockingReason == nil else { error = result.blockingReason; return }
        draft = result; note = ""; error = nil; dateWasAdjusted = false
        // 非法日期只为选择面板提供内部初值；摘要仍显示“请重新设置”，明确确认前 valid 始终为 false。
        date = TextBookkeepingParser.date(day: result.day, time: result.time) ?? Calendar.current.startOfDay(for: .now)
        reviewing = true
    }

    /// 使原会话草稿失效；参数：无；返回值：无；清空敏感原文和候选，要求用户从新空间重新打开，绝不把旧资料写到新账户。
    private func invalidate() {
        guard originSessionID != nil else { return }
        invalidated = true; text = ""; draft = TextBookkeepingDraft(); note = ""; reviewing = false
        error = "账户已变化，请重新打开文本记账"
    }

    /// 显式保存一次确认交易；参数：无；返回值：无；只提交交易白名单到本机财务路由，相同 payload 失败重试沿用 requestId，成功后刷新错误不会再次开放保存。
    private func save() async {
        guard !busy, !saved, valid, let amount = TextBookkeepingParser.canonicalAmount(draft.amount) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var fields: [String: Any] = ["type": draft.type, "amount": amount, "accountId": draft.accountID,
                                         "transactionDate": draft.day, "transactionTime": draft.time,
                                         "counterparty": draft.counterparty, "description": note, "fee": "0.00"]
            if draft.type == "transfer" { fields["targetAccountId"] = draft.targetAccountID }
            else if draft.categoryID > 0 { fields["categoryId"] = draft.categoryID }
            let body = try submission.body(for: fields)
            guard isCurrent else { invalidate(); return }
            try await store.api.mutate("/finance/transactions", body: body)
        } catch {
            if isCurrent { self.error = error.localizedDescription }
            return
        }
        // 主写入成功立即成为终态；刷新独立执行，不进入上面的保存失败分支，也不保留原文。
        saved = true; text = ""
        guard isCurrent else { return }
        dismiss()
        await store.refreshAfterMutation(.finance)
    }
}
