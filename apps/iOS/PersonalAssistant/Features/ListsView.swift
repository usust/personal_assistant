import SwiftUI

struct ListsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var edited: TaskList?
    @State private var deleted: TaskList?
    @State private var error: String?
    var body: some View {
        List {
            if let error { InlineError(message: error) }
            if store.lists.isEmpty { ContentUnavailableView("创建你的第一个清单", systemImage: "folder.badge.plus", description: Text("例如：生活、工作、阅读。")) }
            ForEach(store.lists) { list in
                Button { edited = list } label: {
                    HStack { SymbolTile(symbol: "folder.fill", color: .listColor(list.color)); VStack(alignment: .leading) { Text(list.name).foregroundStyle(.primary); Text(list.remark).font(.caption).foregroundStyle(.secondary) } }
                }.swipeActions { Button("删除", role: .destructive) { deleted = list } }
            }
        }.navigationTitle("我的清单")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }; ToolbarItem(placement: .primaryAction) { Button("新建清单", systemImage: "plus") { creating = true } } }
            .sheet(isPresented: $creating) { ListEditor(list: nil) }
            .sheet(item: $edited) { ListEditor(list: $0) }
            .alert("删除清单？", isPresented: Binding(get: { deleted != nil }, set: { if !$0 { deleted = nil } })) {
                Button("取消", role: .cancel) { deleted = nil }
                Button("删除", role: .destructive) { if let list = deleted { Task { await remove(list) } } }
            } message: { Text("此操作会同时删除清单中的全部任务和子任务，无法撤销。") }
    }
    /// 删除清单及任务；参数：list 为已确认清单；返回值：无；级联删除已确认清单，失败显示错误。
    private func remove(_ list: TaskList) async {
        do { try await store.api.mutate("/task-lists/\(list.id)", method: "DELETE"); store.lists.removeAll { $0.id == list.id }; store.tasks.removeAll { $0.listId == list.id }; deleted = nil }
        catch { self.error = error.localizedDescription }
    }
}
struct ListEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let list: TaskList?
    @State private var name = ""
    @State private var remark = ""
    @State private var color = "#14B8A6"
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("清单名称", text: $name)
                TextField("备注", text: $remark, axis: .vertical)
                Picker("颜色", selection: $color) {
                    Text("青绿").tag("#14B8A6"); Text("海蓝").tag("#3B82F6"); Text("鸢紫").tag("#8B5CF6"); Text("暖橙").tag("#F97316")
                    if !["#14B8A6", "#3B82F6", "#8B5CF6", "#F97316"].contains(color) { Text("现有颜色").tag(color) }
                }
                if let error { InlineError(message: error) }
            }.navigationTitle(list == nil ? "新建清单" : "编辑清单").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= 128) { Task { await save() } } }
                .interactiveDismissDisabled(busy)
                .task { name = list?.name ?? ""; remark = list?.remark ?? ""; color = list?.color ?? "#14B8A6" }
        }
    }
    /// 保存清单；参数：无；返回值：无；编辑只发送变化的白名单字段，创建使用系统图标名称。
    private func save() async {
        busy = true; defer { busy = false }
        do {
            let edited: [String: Any] = ["name": name.trimmingCharacters(in: .whitespaces), "remark": remark, "color": color]
            if let list {
                let fields = Values.patch(original: ["name": list.name, "remark": list.remark, "color": list.color], edited: edited)
                if !fields.isEmpty { try await store.api.mutate("/task-lists/\(list.id)", method: "PATCH", body: fields) }
            } else { var fields = edited; fields["icon"] = "folder"; try await store.api.mutate("/task-lists", body: fields) }
            dismiss(); await store.refreshAfterMutation(.tasks)
        } catch { self.error = error.localizedDescription }
    }
}
