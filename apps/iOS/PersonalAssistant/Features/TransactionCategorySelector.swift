import SwiftUI

/// 共用分类入口；目录、已有分类和推荐项与分类管理保持一致。
struct TransactionCategorySelector: View {
    let title: String
    let type: String
    @Binding var selection: Int
    @Environment(AppStore.self) private var store
    @State private var choosing = false

    /// 构建统一右箭头入口；参数：无；返回值：点击打开底部目录，未选择时仅显示占位文案。
    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: 16) {
                Text(title).foregroundStyle(.primary).fixedSize()
                Spacer(minLength: 0)
                Text(store.categories.first { !$0.deleted && $0.id == selection }?.name ?? "点此设置")
                    .foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .sheet(isPresented: $choosing) {
                CategorySelectionPanel(type: type, selection: $selection)
                    .presentationDetents([.fraction(0.65), .large]).presentationDragIndicator(.visible)
            }
    }
}

private struct CategorySelectionPanel: View {
    let type: String
    @Binding var selection: Int
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    @State private var categoryTemplate: (group: CategoryGroup, item: CategoryTemplate)?
    @State private var draftID = 0

    /// 构建共用图标选择面板；参数：无；返回值：与记一笔完全相同的网格及底部子分类，保留真实选择与错误反馈。
    var body: some View {
        NavigationStack {
            ScrollView {
                if let error { InlineError(message: error).padding(.horizontal) }
                if busy { ProgressView("保存分类…") }
                TransactionCategoryPicker(type: type, categoryID: $draftID, categoryTemplate: $categoryTemplate) {
                    // 回调无参数、无返回值；真实分类直接返回，推荐项先解析真实 ID，失败保留草稿。
                    if let choice = categoryTemplate { Task { await select(choice.item, group: choice.group) } }
                    else { selection = draftID; dismiss() }
                }
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("选择分类").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
                .disabled(busy)
                .task { draftID = selection }
        }.interactiveDismissDisabled(busy)
    }
    /// 解析并选中推荐分类；参数：item 为管理目录模板，group 为其所属一级分组，分组收支类型须与本面板 type 一致；返回值：无。
    /// 副作用：刷新分类缓存，仅复用同类型同名活动分类；只有同名墓碑时 POST 创建新 ID 并追加缓存，保留原墓碑，成功后更新选择并关闭面板。
    /// 错误：请求失败显示错误并保留面板与草稿，不向外抛出；正在提交时直接返回。
    private func select(_ item: CategoryTemplate, group: CategoryGroup) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let latest: [TransactionCategory] = try await store.api.request("/finance/categories")
            store.categories = latest
            let category: TransactionCategory
            // 在 first 内排除墓碑，避免较早的历史同名记录遮蔽活动分类；没有活动分类时允许用新 ID 重建。
            if let existing = latest.first(where: { !$0.deleted && $0.type == type && $0.name.compare(item.name, options: .caseInsensitive) == .orderedSame }) {
                category = existing
            } else {
                category = try await store.api.request("/finance/categories", method: "POST", body: ["name": item.name, "type": type, "color": group.color, "groupKey": group.id, "icon": item.icon])
                store.categories.append(category)
            }
            selection = category.id; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
