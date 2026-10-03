import SwiftUI

/// 记账账户入口；selection 为草稿账户 ID（0 表示未选择），excluding 为转账中需排除的对方账户，onOpen 在打开时结束主页面文字输入，不修改账本。
struct TransactionAccountSelector: View {
    let title: String
    @Binding var selection: Int
    var excluding: Int = 0
    let onOpen: () -> Void
    @Environment(AppStore.self) private var store
    @State private var presented = false

    /// 构建紧凑账户入口和底部面板；参数：无；返回值：固定 14 点图标的按钮，点击展示搜索列表，选择只修改草稿。
    var body: some View {
        let selected = store.accounts.first { $0.id == selection }
        Button {
            onOpen(); presented = true
        } label: {
            HStack(spacing: 4) {
                if let selected {
                    AccountProviderIcon(provider: .resolve(type: selected.accountType, institution: selected.institution), size: 14)
                } else { Image(systemName: "creditcard") }
                Text(selected?.name ?? title).font(.caption2).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }.foregroundStyle(.primary).padding(.horizontal, 8).frame(height: 24)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel(title + "：" + (selected?.name ?? "未选择"))
            .sheet(isPresented: $presented) {
                TransactionAccountSelectionPanel(title: title, selection: $selection, excluding: excluding)
                    .presentationDetents([.fraction(0.72), .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
                    .presentationCompactAdaptation(.sheet)
            }
    }
}

/// 可搜索的单选账户面板；仅提供允许记账的账户，选择后收起，不执行资金操作。
private struct TransactionAccountSelectionPanel: View {
    let title: String
    @Binding var selection: Int
    let excluding: Int
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var addingAccount = false

    /// 筛选可用账户；参数：无；返回值：按账户原顺序排列的搜索结果，排除禁用账户和指定转出账户，支持账户及下属卡片名称、机构和尾号查询。
    private var accounts: [FinancialAccount] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 过滤回调输入账户，返回是否具备选择资格且符合当前搜索，不更改账户资料。
        return store.accounts.filter { account in
            account.selectable != false && account.id != excluding &&
            (keyword.isEmpty || ([account.name, account.institution, account.maskedAccountNumber] + (account.cards ?? []).flatMap { [$0.name, $0.maskedAccountNumber] }).contains { $0.localizedStandardContains(keyword) })
        }
    }
    /// 构建底部账户面板；参数：无；返回值：关闭、标题、添加账户、搜索及余额列表，新建完成后自动读取共享账户状态。
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // 关闭回调无参数、无返回值；保留原选择与记账草稿。
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭账户选择")
                Spacer(minLength: 4)
                Text(title).font(.headline)
                Spacer(minLength: 4)
                // 新建回调无参数、无返回值；使用现有账户编辑器，取消不会产生账户。
                Button("添加账户") { addingAccount = true }.font(.subheadline).frame(minHeight: 44)
            }.padding(.horizontal, 12).padding(.top, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("请输入账户名称", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("清空搜索")
                }
            }.padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                .padding(.horizontal, 16).padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if query.isEmpty {
                        Button { selection = 0; dismiss() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "creditcard.fill").foregroundStyle(.white).frame(width: 36, height: 36).background(.orange, in: Circle())
                                Text("不选择账户").font(.subheadline.weight(.medium))
                                Spacer()
                            }.foregroundStyle(.primary).frame(minHeight: 62).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    // 行回调输入账户，返回名称、类型与真实金额行；选择回调只保存 ID 并关闭面板。
                    ForEach(accounts) { account in
                        Button { selection = account.id; dismiss() } label: { accountRow(account) }.buttonStyle(.plain)
                        Divider()
                    }
                    if accounts.isEmpty {
                        Text(query.isEmpty ? "暂无可选账户" : "没有匹配的账户").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }.padding(.horizontal, 16)
            }.scrollDismissesKeyboard(.interactively)
        }.background(Color(uiColor: .secondarySystemGroupedBackground))
            .sheet(isPresented: $addingAccount) { AccountEditor(account: nil) }
    }
    /// 绘制账户选择行；参数：account 为有效可记账账户；返回值：图标、名称、类型、余额及信用可用额度，长名称自然换行，无网络副作用。
    private func accountRow(_ account: FinancialAccount) -> some View {
        let provider = AccountProvider.resolve(type: account.accountType, institution: account.institution)
        let typeName = provider.type == "bank" ? (provider.isCredit ? "信用卡" : "储蓄卡") : provider.name
        return HStack(spacing: 12) {
            AccountProviderIcon(provider: provider, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(account.notes.isEmpty ? typeName : "[\(typeName)] \(account.notes)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(AccountPresentation.money(AccountPresentation.balance(account))).font(.subheadline).monospacedDigit()
                if provider.isCredit, let available = AccountPresentation.availableCredit(account) {
                    Text("可用额度: " + AccountPresentation.money(available)).font(.caption2).foregroundStyle(.secondary)
                }
            }.fixedSize(horizontal: true, vertical: false).privacySensitive()
        }.foregroundStyle(.primary).padding(.vertical, 10).frame(minHeight: 64).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityAddTraits(selection == account.id ? .isSelected : [])
    }
}
