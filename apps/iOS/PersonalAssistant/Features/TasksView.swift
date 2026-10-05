import SwiftUI
import UIKit

/// 任务模块默认显示所有未归档任务，顶部原生控件切换清单及归档可见性，目录按钮用于管理清单。
struct TasksView: View {
    @State private var selectedListID = 0
    @State private var selectedTitle = "任务"
    @State private var selectedScope = "active"
    /// 构建任务首页；参数：无；返回值：保留全局 Tab 的任务树，无独立业务副作用。
    var body: some View {
        // 选择回调输入清单 ID、标题与任务范围，输出无；更新首页筛选并重建该范围的搜索和展开状态。
        TaskCollectionView(listID: selectedListID, title: selectedTitle, scope: selectedScope, isRoot: true) { id, title, scope in
            selectedListID = id
            selectedTitle = title
            selectedScope = scope
        }.id("\(selectedListID)-\(selectedScope)")
    }
}

/// 收起的清单目录；仅由任务首页按钮推入，保留清单管理与归档入口。
private struct TaskDirectoryView: View {
    /// 删除后的首页重置回调：参数为清单 ID、标题与范围；返回值无，恢复全部任务。
    let onSelect: (Int, String, String) -> Void
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false
    @State private var edited: TaskList?
    @State private var deleted: TaskList?
    /// 构建清单目录页面；参数：无；返回值：可返回任务首页的清单列表；回调仅修改呈现状态或启动只读刷新。
    var body: some View {
        List {
            if let notice = store.taskNotice { InlineError(message: notice); Button("刷新任务") { Task { await reload() } } }
            if loading && store.lists.isEmpty { ProgressView("加载清单…") }
            else if let error, store.lists.isEmpty { InlineError(message: error); Button("重新加载") { Task { await reload() } } }
            else {
                if let error { InlineError(message: error) }
                Section {
                    // 行回调输入已保存清单、输出无；行本身不响应点击，管理操作仅由滑动按钮触发。
                    ForEach(store.lists.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { list in
                        TaskDirectoryRow(
                            name: list.name, remark: list.remark,
                            symbol: TaskListAppearance.symbol(list.icon), color: .listColor(list.color),
                            count: store.tasks.filter { $0.listId == list.id && !$0.archived }.count
                        ).swipeActions(allowsFullSwipe: false) {
                            // 操作回调输入无、输出无；删除仅打开确认，编辑仅打开表单，使用系统图标与明确操作颜色。
                            Button(role: .destructive) { deleted = list } label: {
                                Label("删除", systemImage: "trash")
                            }.tint(.red).disabled(store.taskWriteBusy || store.taskWriteBlocked)
                            Button { edited = list } label: {
                                Label("编辑", systemImage: "pencil")
                            }.tint(.blue).disabled(store.taskWriteBusy || store.taskWriteBlocked)
                        }
                    }
                    if store.lists.isEmpty { ContentUnavailableView("创建第一个清单", systemImage: "folder.badge.plus"); Button("新建清单") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked) }
                    else if !search.isEmpty && !store.lists.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) { ContentUnavailableView.search(text: search) }
                    // 归档入口复用清单行并放在同一分组，保持图标、文字、间距和分隔线一致。
                    TaskDirectoryRow(name: "已归档", symbol: "archivebox", color: .accentColor)
                }
            }
        }.listStyle(.plain).navigationTitle("我的清单").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar).searchable(text: $search, prompt: "搜索清单")
            .toolbar { Button("新建清单", systemImage: "plus") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked) }
            .sheet(isPresented: $creating) { ListEditor(list: nil) }.sheet(item: $edited) { ListEditor(list: $0) }
            .alert("删除清单？", isPresented: Binding(
                get: { deleted != nil }, set: { if !$0 { deleted = nil } }
            )) {
                Button("取消", role: .cancel) { deleted = nil }
                Button("删除", role: .destructive) {
                    if let list = deleted { Task { await remove(list) } }
                }
            } message: { Text("此操作会同时删除清单中的全部任务和子任务，无法撤销。") }
            .task { await reload() }.refreshable { await reload() }
    }
    /// 删除已确认清单；参数：list 为已保存且经用户确认的清单；返回值：无；级联删除任务，失败保留数据并展示错误，未知结果不重发。
    private func remove(_ list: TaskList) async {
        let generation = store.cloudSessionID
        do {
            // 写回调参数无、返回值无；共享写保护防止重复提交，服务器确认后才清理本地快照。
            try await store.writeTask { try await store.api.mutate("/task-lists/\(list.id)", method: "DELETE") }
            store.lists.removeAll { $0.id == list.id }
            store.tasks.removeAll { $0.listId == list.id }
            deleted = nil
            onSelect(0, "任务", "active")
            await store.refreshTaskWrite()
        } catch {
            guard generation == store.cloudSessionID, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
    /// 刷新清单及任务快照；参数：无；返回值：无；失败保留缓存，取消及旧云身份反馈静默。
    private func reload() async {
        let generation = store.cloudSessionID
        loading = true; defer { if generation == store.cloudSessionID { loading = false } }
        do { try await store.loadTasks(); guard generation == store.cloudSessionID else { return }; error = nil }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
}

/// 清单目录统一行样式，供普通清单与归档入口共用。
private struct TaskDirectoryRow: View {
    let name: String
    var remark = ""
    let symbol: String
    let color: Color
    var count: Int? = nil

    /// 构建目录行；参数：无；返回值：统一图标底色、文字对齐与行间距的视图，数量为空时不展示，无副作用。
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.body.weight(.medium))
                if !remark.isEmpty { Text(remark).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let count { Text(count.formatted()).font(.subheadline).foregroundStyle(.secondary) }
        }.padding(.vertical, 2)
    }
}

/// 推入的清单内容页，连续内容面展示可展开树，不增加独立模块导航。
struct TaskCollectionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let listID: Int
    let title: String
    var scope = "active"
    var isRoot = false
    /// 首页范围更新回调；参数为清单 ID、标题和范围；返回值无，仅根页面提供。
    var onSelect: ((Int, String, String) -> Void)? = nil
    @State private var search = ""
    @State private var expanded: Set<Int> = []
    @State private var initializedTree = false
    @State private var editMode: EditMode = .inactive
    @State private var creating = false
    @State private var editingList = false
    @State private var deletingList = false
    @State private var error: String?
    @State private var loading = false
    @State private var openedTaskID: Int?
    @State private var editedTask: AssistantTask?
    @State private var deletedTask: AssistantTask?
    private var list: TaskList? { store.lists.first { $0.id == listID } }
    /// 判断任务是否属于当前清单及显示范围；参数：task 为已加载任务；返回值：是否显示，all 包含归档，archived 仅含归档，其他范围仅含未归档；无副作用。
    private func includesTask(_ task: AssistantTask) -> Bool {
        (listID == 0 || task.listId == listID) && (scope == "all" || task.archived == (scope == "archived"))
    }
    /// 当前范围的树节点；参数：无；返回值：节点、显示深度及各层后续分支标记；父不在范围内时成为有效根，搜索平列匹配节点；无副作用。
    private var rows: [(task: AssistantTask, depth: Int, guides: [Bool])] {
        // 树节点与展开入口复用相同范围，显示归档时保留父子关系，避免归档子任务无法展开。
        let scoped = store.tasks.filter { includesTask($0) }
        if !search.isEmpty { return scoped.filter { $0.title.localizedCaseInsensitiveContains(search) }.map { ($0, 0, []) } }
        let ids = Set(scoped.map(\.id))
        var result: [(task: AssistantTask, depth: Int)] = []
        var visited: Set<Int> = []
        /// 深度遍历树；参数：task为当前节点，depth为缩进深度；返回值：无；循环节点跳过，最多缩进三层以保留可读宽度。
        func append(_ task: AssistantTask, depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            result.append((task, min(depth, 3)))
            if expanded.contains(task.id) { for child in scoped where child.parentId == task.id { append(child, depth: depth + 1) } }
        }
        for task in scoped where !ids.contains(task.parentId ?? 0) { append(task, depth: 0) }
        // 转换回调输入行索引与节点、返回带分支标记的行；按可见树计算连线，末尾节点止于横向连接处，避免跨根节点连线。
        return result.enumerated().map { index, row in
            let guides = (0..<row.depth).map { level in
                // 层级回调输入零起始层级、返回是否存在后续同层分支；跳过后代，遇到更浅节点即结束当前分支。
                for next in result.dropFirst(index + 1) {
                    if next.depth < level + 1 { return false }
                    if next.depth == level + 1 { return true }
                }
                return false
            }
            return (row.task, row.depth, guides)
        }
    }
    /// 构建清单树；参数：无；返回值：普通内容面与原生推入导航；点击有下级的节点展开或收起，叶节点进入详情，写入口遵循共享保护。
    var body: some View {
        List {
            if let notice = store.taskNotice { InlineError(message: notice); Button("刷新任务") { Task { await reload() } } }
            if let error { InlineError(message: error); Button("重新加载") { Task { await reload() } } }
            if rows.isEmpty && error == nil {
                ContentUnavailableView(search.isEmpty ? scope == "archived" ? "暂无归档任务" : "暂无任务" : "没有匹配的任务", systemImage: "checklist")
                if search.isEmpty && scope != "archived" && (list != nil || isRoot) && !store.lists.isEmpty { Button("新建任务") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked) }
            }
            Section {
                // 树行回调输入节点与深度、输出详情导航及独立展开操作；展开不修改业务数据。
                ForEach(rows, id: \.task.id) { row in
                    let hasChildren = store.tasks.contains { $0.parentId == row.task.id && includesTask($0) }
                    // 点击回调参数无、返回无；树模式点击父节点切换展开，叶节点或平列搜索结果进入详情，无业务写入。
                    Button {
                        if search.isEmpty && hasChildren {
                            if expanded.contains(row.task.id) { expanded.remove(row.task.id) }
                            else { expanded.insert(row.task.id) }
                        } else { openedTaskID = row.task.id }
                    } label: {
                        TaskRow(task: row.task, showsContext: false, compact: true)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(search.isEmpty && hasChildren ? (expanded.contains(row.task.id) ? "收起下级" : "展开下级") : "查看详情")
                    // 长按交给原生列表拖拽排序，侧滑仅提供编辑、归档和删除，避免菜单抢占拖拽手势。
                    // 每层预留 20 点连线区，内容使用完整宽度；搜索结果不缩进，避免缺失祖先时暗示错误层级。
                    .padding(.leading, CGFloat(row.depth) * 20)
                    // 任务之间仅保留 1 点外部留白，内部信息通过 TaskRow 自身间距舒展排列。
                    .padding(.vertical, 1)
                    .overlay(alignment: .leading) {
                        if row.depth > 0 {
                            TaskTreeGuides(continuations: row.guides)
                                .frame(width: CGFloat(row.depth) * 20)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // 滑动操作回调参数无、返回无；写操作遵循共享保护，删除仅选择待确认任务，编辑仅打开表单。
                        Button("删除", systemImage: "trash", role: .destructive) { deletedTask = row.task }
                            .disabled(store.taskWriteBusy || store.taskWriteBlocked)
                        Button(row.task.archived ? "取消归档" : "归档", systemImage: "archivebox") {
                            Task { await archiveTask(row.task) }
                        }.tint(.orange).disabled(store.taskWriteBusy || store.taskWriteBlocked)
                        Button("编辑", systemImage: "pencil") { editedTask = row.task }
                            .tint(.blue).disabled(store.taskWriteBusy || store.taskWriteBlocked)
                    }
                }
                // 拖动回调输入源索引和插入位置、输出无；仅在同父序列中写入排序，不改变任务归属。
                .onMove { source, destination in Task { await reorder(source, to: destination) } }
            }
            // 不绘制行间或分组分隔线，仅保留缩进和树形虚线表达层级。
            .listSectionSeparator(.hidden)
        }.environment(\.editMode, $editMode).listStyle(.plain).navigationTitle(list?.name ?? title).navigationBarTitleDisplayMode(.inline).toolbar(isRoot ? .visible : .hidden, for: .tabBar)
            .toolbar { collectionToolbar }
            // 导航绑定读取详情任务 ID；关闭回调输入呈现状态、返回无，返回列表时清理 ID 并保留筛选和展开状态。
            .navigationDestination(isPresented: Binding(
                get: { openedTaskID != nil },
                set: { if !$0 { openedTaskID = nil } }
            )) {
                if let openedTaskID { TaskDetailView(taskID: openedTaskID) }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if isRoot { quickListSwitcher }
            }
            .sheet(isPresented: $creating) { TaskEditor(task: nil, parent: nil, preferredListID: listID) }
            .sheet(item: $editedTask) { task in TaskEditor(task: task, parent: nil) }
            // 确认绑定读取待删除任务；关闭回调输入呈现状态、返回无；取消清空选择，确认后才执行级联删除。
            .confirmationDialog("删除此任务及全部下级？", isPresented: Binding(
                get: { deletedTask != nil }, set: { if !$0 { deletedTask = nil } }
            ), titleVisibility: .visible) {
                Button("删除任务及下级", role: .destructive) {
                    if let task = deletedTask { Task { await removeTask(task) } }
                }
            }
            .sheet(isPresented: $editingList) { if let list { ListEditor(list: list) } }
            .confirmationDialog("删除清单及其中全部任务？", isPresented: $deletingList, titleVisibility: .visible) { Button("删除清单", role: .destructive) { Task { await removeList() } } }
            // 首次展示回调输入无、输出无；首页先刷新快照，再展开主任务；后续保留用户折叠状态。
            .task {
                if isRoot { await reload() }
                if !initializedTree {
                    expanded = Set(store.tasks.filter { (listID == 0 || $0.listId == listID) && $0.taskType == "main" }.map(\.id))
                    initializedTree = true
                }
            }
            .refreshable { await reload() }
    }
    /// 构建首页筛选栏；参数：无；返回值：左侧原生清单选择器及右侧紧凑归档勾选按钮，仅修改显示范围，不写入业务数据。
    private var quickListSwitcher: some View {
        HStack(spacing: 12) {
            // 绑定读取当前清单 ID；写入回调输入选择的 ID、返回无，保留归档显示偏好并由首页重建任务树。
            Menu {
                Picker("切换任务清单", selection: Binding(
                get: { listID },
                set: { id in
                    let name = store.lists.first { $0.id == id }?.name ?? "任务"
                    onSelect?(id, name, scope)
                }
            )) {
                Label("全部任务", systemImage: "checklist").tag(0)
                // 清单选项输入已保存清单、输出原生选项；复用共用图标键，系统菜单负责选中标记和长名称适配。
                ForEach(store.lists) { list in
                    Label(list.name, systemImage: TaskListAppearance.symbol(list.icon)).tag(list.id)
                }
            }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: list.map { TaskListAppearance.symbol($0.icon) } ?? "checklist")
                    Text(list?.name ?? "全部任务").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption)
                }.frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .tint(.accentColor)
            .accessibilityIdentifier("taskListSwitcher")
            Spacer(minLength: 0)
            // 点击回调参数无、返回无；勾选后包含归档任务，取消后仅显示未归档任务，保持当前清单。
            Button {
                onSelect?(listID, list?.name ?? title, scope == "all" ? "active" : "all")
            } label: {
                // 使用系统方框符号呈现勾选状态；整个标签保留 44 点点击高度，小尺寸视觉不缩小触控范围。
                HStack(spacing: 5) {
                    Image(systemName: scope == "all" ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(scope == "all" ? Color.accentColor : Color.secondary)
                    Text("已归档")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(scope == "all" ? "已勾选" : "未勾选")
            .accessibilityAddTraits(scope == "all" ? [.isSelected] : [])
            .accessibilityIdentifier("taskShowArchivedToggle")
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .padding(.vertical, 2)
        .background(.background)
    }
    /// 构建任务导航操作；参数：无；返回值：首页清单入口或清单管理工具栏，按钮只修改呈现状态。
    @ToolbarContentBuilder
    private var collectionToolbar: some ToolbarContent {
                if isRoot {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink { TaskDirectoryView { id, title, scope in onSelect?(id, title, scope) } } label: { Label("我的清单", systemImage: "folder") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("新建任务", systemImage: "plus") { creating = true }
                            .disabled(scope == "archived" || store.lists.isEmpty || store.taskWriteBusy || store.taskWriteBlocked)
                    }
                }
                if list != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("编辑清单") { editingList = true }
                        Button("删除清单", role: .destructive) { deletingList = true }
                        // 排序回调输入无、输出无；切换本地系统EditMode，不增加顶部按钮，排序写入仍受共享保护。
                        Button(editMode.isEditing ? "完成排序" : "排序") { editMode = editMode.isEditing ? .inactive : .active }
                            .disabled(loading || !search.isEmpty || store.taskWriteBusy || store.taskWriteBlocked)
                    } label: { Image(systemName: "ellipsis") }.disabled(store.taskWriteBusy || store.taskWriteBlocked)
                    if !isRoot { Button("新建任务", systemImage: "plus") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked || scope == "archived") }
                    }
                }
    }
    /// 切换任务归档；参数：task 为当前快照任务；返回值：无；归档仅 PATCH archived，取消归档同时关闭 autoArchive，成功合并后刷新，失败显示错误，未知结果不重发。
    private func archiveTask(_ task: AssistantTask) async {
        let generation = store.cloudSessionID
        do {
            // 写回调参数无、返回服务器确认的任务；恢复时同步关闭自动归档，避免已完成任务在同一事务或后续写入中再次归档。
            let saved: AssistantTask = try await store.writeTask {
                try await store.api.request("/tasks/\(task.id)", method: "PATCH", body: task.archived ? ["archived": false, "autoArchive": false] : ["archived": true])
            }
            store.upsertTask(saved)
            error = nil
            await store.refreshTaskWrite()
        } catch {
            guard generation == store.cloudSessionID, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
    /// 删除已确认任务及后代；参数：task 为经用户确认的任务；返回值：无；服务确认后清理本地树，失败保留快照，未知结果不重发。
    private func removeTask(_ task: AssistantTask) async {
        let generation = store.cloudSessionID
        do {
            // 删除回调参数无、返回无；复用详情接口的级联参数，服务器确认后再移除本地节点。
            try await store.writeTask {
                try await store.api.mutate("/tasks/\(task.id)", method: "DELETE", query: [URLQueryItem(name: "cascade", value: "true")])
            }
            var removed: Set<Int> = [task.id]
            var foundDescendant = true
            // 包含归档及折叠后代，循环保护保证异常父子关系不会导致无限遍历。
            while foundDescendant {
                foundDescendant = false
                for item in store.tasks {
                    if let parent = item.parentId, removed.contains(parent), removed.insert(item.id).inserted { foundDescendant = true }
                }
            }
            store.tasks.removeAll { removed.contains($0.id) }
            expanded.subtract(removed)
            deletedTask = nil
            error = nil
            await store.refreshTaskWrite()
        } catch {
            guard generation == store.cloudSessionID, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
    /// 刷新任务内容；参数：无；返回值：无；旧云身份与取消不显示错误。
    private func reload() async {
        let generation = store.cloudSessionID
        loading = true; defer { if generation == store.cloudSessionID { loading = false } }
        do { try await store.loadTasks(); guard generation == store.cloudSessionID else { return }; error = nil }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
    /// 保存同父级顺序；参数：source为单行源索引，destination为目标位置；返回值：无；跨层级拖动拒绝，成功后独立刷新。
    private func reorder(_ source: IndexSet, to destination: Int) async {
        let original = rows.map(\.task)
        guard let index = source.first, source.count == 1, original.indices.contains(index) else { return }
        var ordered = original; ordered.move(fromOffsets: source, toOffset: destination)
        let siblings = ordered.filter { $0.parentId == original[index].parentId }
        let originalSiblings = original.filter { $0.parentId == original[index].parentId }
        guard siblings.map(\.id) != originalSiblings.map(\.id) else { return }
        let ids = Values.taskOrderPreservingHidden(store.tasks, orderedVisibleIDs: siblings.map(\.id))
        guard ids.count <= 1000 else { error = "任务超过 1000 个，当前服务端不支持一次排序这么多任务。"; return }
        let generation = store.cloudSessionID
        // 排序写回调输入无、输出无；提交保留隐藏槽位的全ID顺序，服务确认后再独立刷新。
        do { try await store.writeTask { try await store.api.mutate("/tasks/reorder", method: "PUT", body: ["taskIds": ids]) }; await store.refreshTaskWrite() }
        catch { if generation == store.cloudSessionID && !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    /// 删除已确认清单；参数：无；返回值：无；服务端确认后本地移除并返回，未知结果不重发。
    private func removeList() async {
        let generation = store.cloudSessionID
        do { try await store.writeTask { try await store.api.mutate("/task-lists/\(listID)", method: "DELETE") }; store.lists.removeAll { $0.id == listID }; store.tasks.removeAll { $0.listId == listID }; if isRoot { onSelect?(0, "任务", "active") } else { dismiss() }; await store.refreshTaskWrite() }
        catch { guard generation == store.cloudSessionID, !(error is CancellationError) else { return }; self.error = error.localizedDescription }
    }
}

/// 树形任务行的装饰连线；每层宽度固定为 20 点，不参与点击或辅助功能读取。
private struct TaskTreeGuides: View {
    /// 从外至内各层是否还有后续兄弟分支，数组长度等于当前行显示深度。
    let continuations: [Bool]

    /// 构建层级虚线；参数：无；返回值：随任务行高度延伸的连接线，无业务副作用。
    var body: some View {
        // 几何回调输入当前行尺寸、返回连线视图；祖先竖线仅在仍有分支时延伸，当前层末节点用转角结束。
        GeometryReader { geometry in
            // 路径回调输入可变路径、返回无；按层绘制竖线，当前层再连接任务内容，虚线弱化装饰视觉。
            Path { path in
                for level in continuations.indices {
                    let x = CGFloat(level) * 20 + 6
                    let isCurrent = level == continuations.count - 1
                    let jointY = min(22, geometry.size.height / 2)
                    if isCurrent || continuations[level] {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: continuations[level] ? geometry.size.height : jointY))
                    }
                    if isCurrent {
                        path.move(to: CGPoint(x: x, y: jointY))
                        path.addLine(to: CGPoint(x: geometry.size.width - 4, y: jointY))
                    }
                }
            }
            .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

/// 按实际字符宽度省略标题，避免按词组截断造成尾部空白。
private struct TaskTruncatedTitle: View {
    let title: String
    let width: CGFloat
    var badge: String? = nil
    /// 归档标题使用删除线及中性标签色；默认保持活动任务样式。
    var archived = false
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption2) private var badgeFontSize: CGFloat = 11

    /// 构建单行标题；参数：无；返回值：测量字体一致的标题视图，归档显示删除线，辅助功能读取全文；无副作用。
    var body: some View {
        HStack(spacing: 6) {
            if let badge {
                Text(badge)
                    .font(.system(size: badgeFontSize, weight: .medium))
                    .foregroundStyle(!archived && badge == "主任务" ? Color.teal : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((!archived && badge == "主任务" ? Color.teal : Color.secondary).opacity(0.1), in: Capsule())
                    .fixedSize()
            }
            Text(fittedTitle)
                .strikethrough(archived, color: .secondary)
                .font(.system(size: fontSize, weight: .medium))
                .fixedSize(horizontal: true, vertical: false)
        }
            .frame(width: max(0, width), alignment: .leading)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((badge.map { $0 + "，" } ?? "") + title)
    }

    /// 求可容纳的最长字符前缀；参数：无；返回值：全文或尾部带省略号的文本，不拆分组合字符；无副作用。
    private var fittedTitle: String {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize, weight: .medium)]
        // 标题测量扣除标签实际字宽、内边距和间距；按保存类型显示标签，不能凭是否存在子任务推断类型。
        let badgeWidth = badge.map { ($0 as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: badgeFontSize, weight: .medium)]).width + 22 } ?? 0
        let available = max(0, width - badgeWidth)
        guard (title as NSString).size(withAttributes: attributes).width > available else { return title }
        let characters = Array(title)
        var lower = 0
        var upper = characters.count
        // 按实际字形宽度二分查找，预留省略号宽度，尽量填满标题区域且不越过进度条边界。
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            let candidate = String(characters.prefix(middle)) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= available { lower = middle }
            else { upper = middle - 1 }
        }
        return String(characters.prefix(lower)) + "…"
    }
}

/// 所有任务展示入口共用的类型标签，仅依据保存类型，父子归属不改变标签。
private struct TaskTypeBadge: View {
    let taskType: String
    /// 归档时将类型标签降为中性色，避免与活动任务争夺视觉焦点。
    var archived = false

    /// 构建类型标签；参数：无；返回值：main 显示主任务，subtask 显示任务的小胶囊，归档使用中性色；无副作用。
    var body: some View {
        Text(taskType == "main" ? "主任务" : "任务")
            .font(.caption2.weight(.medium))
            .foregroundStyle(!archived && taskType == "main" ? Color.teal : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((!archived && taskType == "main" ? Color.teal : Color.secondary).opacity(0.1), in: Capsule())
            .fixedSize()
    }
}

struct TaskRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let task: AssistantTask
    var showsContext = true
    /// 任务树使用紧凑间距，其他页面保留原有任务行布局。
    var compact = false
    private var progress: TaskProgress { Values.progress(task, all: store.tasks) }
    /// 构建任务行；参数：无；返回值：标题、融合数量和百分比的进度条及元信息，按 compact 选择间距、按 showsContext 显示路径，按类型和归档状态显示淡背景，归档标题使用删除线；无业务写入。
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 按类型标签和标题、等级状态、融合进度条、日期的顺序排列。
            VStack(alignment: .leading, spacing: compact ? 7 : 5) {
                // 紧凑列表标题单行尾部省略，辅助功能仍读取完整标题；其他入口保留原有换行，详情页不受影响。
                if compact {
                    // 用单行占位确定动态字号高度，再给标题明确的内容宽度，避免布局协商提前截断；右边界与进度条一致。
                    Text(" ").font(.body.weight(.medium)).hidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            // 几何回调输入标题行尺寸、返回同宽标题；不改变任务数据，辅助功能仍读取完整标题。
                            GeometryReader { geometry in
                                TaskTruncatedTitle(title: task.title, width: geometry.size.width, badge: task.taskType == "main" ? "主任务" : "任务", archived: task.archived)
                            }
                        }
                } else { taskTitle }
                statusMetadata
                // 普通任务与主任务都复用统一汇总结果，零总量安全显示为 0%。
                integratedProgress
                // 元信息紧跟进度条，按可用宽度换行；空日期不占位，保持任务树紧凑。
                metadata.font(.caption).foregroundStyle(.secondary)
                if showsContext { Text(taskPath(task, tasks: store.tasks, lists: store.lists)).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, compact ? 6 : 7)
            .foregroundStyle(task.archived ? .secondary : .primary)
            // 各类任务统一使用轻微底色与小圆角，不增加阴影或边框，保留连续任务树的紧凑布局。
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityValue(task.archived ? "已归档" : "")
    }
    /// 选择任务行背景；参数：无；返回值：归档优先使用系统淡灰，活动主任务使用淡青绿，普通任务使用浅系统填充；颜色适应系统外观，无副作用。
    private var rowBackground: Color {
        // 归档状态优先于保存类型，避免已归档主任务仍通过主题色表达活动状态。
        if task.archived { return Color(uiColor: .quaternarySystemFill) }
        if task.taskType == "main" { return Color.teal.opacity(0.06) }
        return Color(uiColor: .quaternarySystemFill).opacity(0.6)
    }
    /// 构建融合进度条；参数：无；返回值：条内左侧数量、右侧百分比，浅色填充按进度延伸，内容确定高度并支持动态字号，归档改用中性色；无副作用。
    private var integratedProgress: some View {
        HStack(spacing: 8) {
            Text(taskQuantity(progress, includesUnit: !compact))
            Spacer(minLength: 4)
            Text(taskPercent(progress))
        }
        .font(.caption2.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(task.archived ? .secondary : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            // 几何回调输入文字布局后的实际尺寸，返回按进度比例填充的背景；背景不参与高度协商，避免撑高列表。
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color(uiColor: .tertiarySystemFill)
                    (task.archived ? Color.secondary : Color.teal).opacity(task.archived ? 0.12 : 0.28)
                        .frame(width: geometry.size.width * progress.fraction)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("进度 " + taskQuantity(progress) + "，" + taskPercent(progress))
    }
    /// 构建任务标题；参数：无；返回值：紧凑列表单行省略的标题视图，辅助功能保留全文，归档显示删除线，无副作用。
    private var taskTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TaskTypeBadge(taskType: task.taskType, archived: task.archived)
            Text(task.title)
            .strikethrough(task.archived, color: .secondary)
            .font(.body.weight(.medium))
            .lineLimit(compact ? 1 : nil)
            .truncationMode(.tail)
            .accessibilityLabel(task.title)
        }
    }
    /// 构建标题下方的状态行；参数：无；返回值：紧急程度及完成状态，使用紧凑图文并排；无副作用。
    private var statusMetadata: some View {
        HStack(spacing: 12) {
            priorityLabel
            completionLabel
        }
        .font(.caption2.weight(.medium))
    }
    /// 构建进度条下方的日期信息；参数：无；返回值：已设置日期，按内容高度换行，空日期不占位；无副作用。
    private var metadata: some View {
        // 明确图文布局及内容高度，避免列表默认样式撑高任务行。
        dateRange.font(.caption2).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
    /// 构建紧急程度标签；参数：无；返回值：紧邻旗帜的中文等级，活动任务高为红、中为橙、低为蓝，归档统一中性色，图文同色；无副作用。
    private var priorityLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill")
            Text(task.priority == "high" ? "高" : task.priority == "low" ? "低" : "中")
        }
        .foregroundStyle(task.archived ? Color.secondary : task.priority == "high" ? Color.red : task.priority == "low" ? Color.blue : Color.orange)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("紧急程度：" + (task.priority == "high" ? "高" : task.priority == "low" ? "低" : "中"))
    }
    /// 构建完成状态标签；参数：无；返回值：与汇总进度一致的已完成、进行中或未开始短标签，零总量为未开始，归档优先显示归档状态；无副作用。
    private var completionLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: task.archived ? "archivebox" : progress.fraction >= 1 ? "checkmark.circle.fill" : progress.completed > 0 ? "circle.lefthalf.filled" : "circle")
            Text(task.archived ? "已归档" : progress.fraction >= 1 ? "已完成" : progress.completed > 0 ? "进行中" : "未开始")
        }
        .foregroundStyle(!task.archived && progress.fraction >= 1 ? Color.teal : Color.secondary)
    }
    /// 构建日期范围内容；参数：无；返回值：已设置的起止日期各占紧凑一行，以图标区分开始和结束，活动任务逾期结束日期标红，归档保持中性色；无副作用。
    @ViewBuilder private var dateRange: some View {
        if !task.startDate.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "calendar")
                Text(taskRowDate(task.startDate, time: task.startTime))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("开始：" + taskDate(task.startDate, time: task.startTime))
        }
        if !task.endDate.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                Text(taskRowDate(task.endDate, time: task.endTime))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(!task.archived && Values.taskIsOverdue(task, all: store.tasks) ? Color.red : Color.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("结束：" + taskDate(task.endDate, time: task.endTime))
        }
    }
}
struct TaskDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    let taskID: Int
    @State private var editing = false
    @State private var addingChild = false
    @State private var deleting = false
    @State private var busy = false
    @State private var error: String?
    private var item: AssistantTask? { store.tasks.first { $0.id == taskID } }
    private var children: [AssistantTask] { store.tasks.filter { $0.parentId == taskID } }
    /// 构建只读任务详情；参数：无；返回值：任务信息与进度，未归档叶任务通过加减按钮按步长修改完成数量，其他信息通过独立编辑表单修改；容器进度由下级汇总。
    var body: some View {
        Group {
            if let task = item {
                let summary = Values.progress(task, all: store.tasks)
                let container = task.taskType == "main" || !children.isEmpty
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(task.title)
                                .strikethrough(task.archived, color: .secondary)
                                .foregroundStyle(task.archived ? .secondary : .primary)
                                .font(.title2.weight(.semibold)).tracking(0.2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            TaskTypeBadge(taskType: task.taskType, archived: task.archived).padding(.top, 5)
                        }.padding(.vertical, 8)

                        // 进度与唯一可编辑的完成数量放在同一卡片，其他信息保持只读。
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Label("完成进度", systemImage: "chart.bar.fill")
                                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                                Spacer()
                                if task.archived { Text("已归档").font(.caption).foregroundStyle(.secondary) }
                            }
                            // 容器与归档任务没有加减控件，在摘要中显示进度；可操作任务的数字统一放入药丸，避免重复。
                            if container || task.archived {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(taskQuantity(summary, includesUnit: false)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                                    Spacer(minLength: 12)
                                    Text(taskPercent(summary)).font(.title3.weight(.medium)).foregroundStyle(task.archived ? Color.secondary : Color.teal).monospacedDigit()
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(taskQuantity(summary, includesUnit: false)).font(.title.weight(.semibold)).monospacedDigit()
                                    Text(taskPercent(summary)).font(.title3).foregroundStyle(task.archived ? Color.secondary : Color.teal)
                                }
                            }
                            }
                            if container || task.archived {
                                ProgressView(value: summary.fraction).tint(task.archived ? .secondary : .teal)
                            }
                            if !container && !task.archived {
                                HStack(spacing: 12) {
                                    // 操作回调参数无、返回无；统一使用服务端步长接口，提交期间禁用，防止连续点击重复写入。
                                    Button { Task { await progress("decrement") } } label: {
                                        Image(systemName: "minus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.teal)
                                    .accessibilityLabel("减少进度")
                                    .disabled(task.progressCompleted <= 0 || busy || store.taskWriteBusy || store.taskWriteBlocked)
                                    // 中间集中显示完成数量／总量与百分比，左右按步长加减，共用药丸背景。
                                    VStack(spacing: 3) {
                                        Text(taskQuantity(summary, includesUnit: false))
                                            .font(.headline).monospacedDigit()
                                        // 进度条与数量、百分比共用药丸中央区域，保持左右加减按钮的独立点击范围。
                                        ProgressView(value: summary.fraction).tint(.teal).accessibilityHidden(true)
                                        Text(taskPercent(summary)).font(.caption).foregroundStyle(.teal).monospacedDigit()
                                    }.frame(maxWidth: .infinity)
                                    Button { Task { await progress("increment") } } label: {
                                        Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.teal)
                                    .accessibilityLabel("增加进度")
                                    .disabled(task.progressCompleted >= task.progressTotal || busy || store.taskWriteBusy || store.taskWriteBlocked)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                            }
                        }
                        .padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))

                        // 双列信息块替代长串字段行；辅助字号改为单列，保持日期和长清单名称可读。
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 24) {
                            informationTile("清单", value: store.lists.first { $0.id == task.listId }?.name ?? "未设置", symbol: "folder")
                            informationTile("优先级", value: task.priority == "high" ? "高" : task.priority == "low" ? "低" : "中", symbol: "flag")
                            informationTile("开始", value: task.startDate.isEmpty ? "未设置" : taskDate(task.startDate, time: task.startTime), symbol: "calendar")
                            informationTile("截止", value: task.endDate.isEmpty ? "未设置" : taskDate(task.endDate, time: task.endTime), symbol: "calendar.badge.clock")
                            if !container {
                                informationTile("总量", value: task.progressTotal.formatted() + " " + task.progressUnit, symbol: "target")
                                informationTile("步长", value: task.progressStep.formatted() + " " + task.progressUnit, symbol: "plus.forwardslash.minus")
                            }
                        }
                        .padding(20)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))

                        if container && !children.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("下级任务").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                                // 子任务回调输入任务、返回导航行；继续复用只读详情，避免建立另一套编辑入口。
                                ForEach(children) { child in
                                    NavigationLink { TaskDetailView(taskID: child.id) } label: {
                                        TaskRow(task: child, showsContext: false, compact: true)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(20)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                        }
                        if !task.remark.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("备注", systemImage: "text.alignleft").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                                Text(task.remark).font(.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(20)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                        }
                        if let notice = store.taskNotice {
                            InlineError(message: notice)
                            Button("刷新任务") { Task { await store.refreshTaskWrite(confirmedWrite: false) } }
                        } else if let error { InlineError(message: error) }
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("任务").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                    .toolbar {
                        if !task.archived && task.taskType == "main" {
                            ToolbarItem(placement: .bottomBar) { Button("新建下级", systemImage: "plus") { addingChild = true }.disabled(busy || store.taskWriteBusy || store.taskWriteBlocked) }
                        }
                    }
                    .sheet(isPresented: $editing) { TaskEditor(task: task, parent: nil) }
                    .sheet(isPresented: $addingChild) { TaskEditor(task: nil, parent: task) }
                    .confirmationDialog("删除此任务及全部下级？", isPresented: $deleting, titleVisibility: .visible) { Button("删除任务及下级", role: .destructive) { Task { await remove() } } }
            } else { ContentUnavailableView("任务已不存在", systemImage: "checkmark.circle") }
        }
    }
    /// 构建只读信息块；参数：title 为简短字段名，value 为完整显示值，symbol 为系统图标名称；返回值：标签和数值组成的信息视图，无副作用。
    private func informationTile(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// 更改叶任务进度；参数：operation 为 increment/decrement；返回值：无；后端检查溢出和归档，成功刷新。
    private func progress(_ operation: String) async {
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        // 写回调输入无、输出服务器任务实体；仅一次 PATCH，成功实体先合并，读失败不重发。
        do { let saved: AssistantTask = try await store.writeTask { try await store.api.request("/tasks/\(taskID)/progress", method: "PATCH", body: ["operation": operation, "allowExceedTotal": true]) }; store.upsertTask(saved); error = nil; await store.refreshTaskWrite() }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
    /// 设置归档状态；参数：task 为原任务；返回值：无；归档仅发送 archived，取消归档同时关闭 autoArchive，支持显式 false。
    private func archive(_ task: AssistantTask) async {
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        // 写回调输入无、输出服务器任务实体；仅一次 PATCH，成功实体先合并，读失败不重发。
        do { let saved: AssistantTask = try await store.writeTask { try await store.api.request("/tasks/\(taskID)", method: "PATCH", body: task.archived ? ["archived": false, "autoArchive": false] : ["archived": true]) }; store.upsertTask(saved); error = nil; await store.refreshTaskWrite() }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
    /// 确认后级联删除；参数：无；返回值：无；删除成功关闭页面，刷新失败不诱导重复删除。
    private func remove() async {
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        do {
            // 删除回调输入无、输出无；结构化 cascade 查询保留在真实请求URL中。
            try await store.writeTask { try await store.api.mutate("/tasks/\(taskID)", method: "DELETE", query: [URLQueryItem(name: "cascade", value: "true")]) }
            // 从本地任务树计算后代，删除接口统一返回 data:null。
            var removed: Set<Int> = [taskID]
            var expanded = true
            while expanded {
                expanded = false
                for item in store.tasks {
                    if let parent = item.parentId, removed.contains(parent), removed.insert(item.id).inserted { expanded = true }
                }
            }
            store.tasks.removeAll { removed.contains($0.id) }
            dismiss()
            await store.refreshTaskWrite()
        } catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
}

struct TaskEditor: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: AssistantTask?
    let parent: AssistantTask?
    var preferredListID = 0
    @State private var uncertainCreation = false
    @State private var title = ""
    @State private var remark = ""
    @State private var listID = 0
    @State private var parentID = 0
    @State private var icon = "Folder"
    @State private var autoArchive = false
    @State private var priority = "medium"
    @State private var taskType = "subtask"
    @State private var total = "1"
    @State private var completed = "0"
    @State private var step = "1"
    @State private var unit = "次"
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var startTime = ""
    @State private var endTime = ""
    @State private var original: [String: Any] = [:]
    @State private var populated = false
    @State private var busy = false
    @State private var error: String?
    /// 选择进度字段布局；参数：无；返回值：常规字号两列，辅助功能大字号纵向排列，避免输入框拥挤；无副作用。
    private var progressFieldLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    }
    /// 生成提交字段白名单；参数：无；返回值：归属和当前类型字段，主任务不提交隐藏进度；未提交字段保留原值。
    private var fields: [String: Any] {
        var result: [String: Any] = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "remark": remark, "priority": priority, "taskType": taskType, "autoArchive": autoArchive,
         "startDate": hasStart ? Values.day(start) : "", "endDate": hasEnd ? Values.day(end) : "",
         "startTime": hasStart ? startTime : "", "endTime": hasEnd ? endTime : "", "listId": listID, "parentId": parentID == 0 ? NSNull() : parentID]
        if taskType == "main" { result["icon"] = icon }
        // 合并回调输入默认旧值和量化草稿值、输出新值；仅具体类型提交进度，主任务原配置不覆盖。
        else { result.merge(["progressTotal": total, "progressCompleted": completed, "progressStep": step, "progressUnit": unit]) { _, new in new } }
        return result
    }
    /// 主父候选；参数：无；返回值：同清单未归档主任务，排除自身和后代；旧具体父节点不作为新候选。
    private var parentCandidates: [AssistantTask] {
        var excluded: Set<Int> = task.map { [$0.id] } ?? []
        var changed = true
        while changed { changed = false; for item in store.tasks { if let parent = item.parentId, excluded.contains(parent), excluded.insert(item.id).inserted { changed = true } } }
        return store.tasks.filter { $0.listId == listID && $0.taskType == "main" && !$0.archived && !excluded.contains($0.id) }
    }
    /// 校验白名单草稿；参数：无；返回值：首个具体错误或 nil；进度限定自然数，日期时间采用本地日历。
    private var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入任务名称。" }
        if title.unicodeScalars.count > 256 { return "任务名称最多 256 个字符。" }
        if remark.unicodeScalars.count > 10000 { return "备注最多 10000 个字符。" }
        if let task, task.taskType == "main", taskType != "main", store.tasks.contains(where: { $0.parentId == task.id }) { return "有下级的主任务不能改为具体任务。" }
        if icon.utf8.count > 64 || icon.trimmingCharacters(in: .whitespaces).isEmpty { return "请选择有效图标。" }
        if parentID != 0 && !parentCandidates.contains(where: { $0.id == parentID }) && !(task?.parentId == parentID && task?.listId == listID) { return "请选择有效父主任务。" }
        if unit.unicodeScalars.count > 20 { return "单位最多 20 个字符。" }
        if !store.lists.contains(where: { $0.id == listID }) { return "请选择有效清单。" }
        if configuresProgress && (![total, completed, step].allSatisfy { $0.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil } || (Int(total) ?? 0) < 1 || (Int(step) ?? 0) < 1) { return "进度只能填写整数，目标总量和每次增加至少为 1。" }
        let target = Decimal(string: total) ?? 0, increment = Decimal(string: step) ?? 0, done = Decimal(string: completed) ?? -1
        if configuresProgress && (target > 1_000_000_000 || increment > target || done < 0 || done > target) { return "进度应在目标总量内，每次增加不能超过总量。" }
        for time in [hasStart ? startTime : "", hasEnd ? endTime : ""] {
            if !time.isEmpty && time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) == nil { return "时间格式应为 HH:mm。" }
        }
        if hasStart && hasEnd && (Values.day(start) + " " + (startTime.isEmpty ? "00:00" : startTime)) > (Values.day(end) + " " + (endTime.isEmpty ? "23:59" : endTime)) { return "截止时间不能早于开始时间。" }
        return nil
    }
    /// 判断可保存草稿；参数：无；返回值：校验和共享保护都通过为 true；结果不明的原创建表单永久禁止再次提交。
    private var valid: Bool { validationError == nil && !uncertainCreation && !store.taskWriteBlocked && !store.taskWriteBusy }
    /// 判断进度配置入口；参数：无；返回值：仅可执行叶节点或新建可执行任务为 true；汇总节点保留原字段。
    private var configuresProgress: Bool {
        guard taskType == "subtask" else { return false }
        guard let task else { return true }
        return !store.tasks.contains(where: { $0.parentId == task.id })
    }
    /// 构建任务界面；参数：无；返回值：原生视图；状态回调只更新草稿或启动单次明确操作。
    var body: some View {
        NavigationStack {
            Form {
                if uncertainCreation { InlineError(message: "创建结果未确认。请关闭此表单并刷新列表，确认后再创建。") }
                else if let error { InlineError(message: error) }
                Section("基本信息") {
                    TaskFloatingField(title: "名称", text: $title)
                    TaskFloatingField(title: "备注", text: $remark, multiline: true)
                    if task == nil || (task?.taskType == "subtask" && !configuresProgress) {
                        Picker("类型", selection: $taskType) { Text("任务").tag("subtask"); Text("主任务").tag("main") }
                    }
                    if taskType == "main" {
                        NavigationLink { TaskIconPicker(selection: $icon) } label: {
                            HStack { Text("图标"); Spacer(); Image(systemName: TaskIcons.symbol(icon)).foregroundStyle(.teal) }
                        }
                    }
                }
                Section("归属") {
                    Picker("清单", selection: $listID) { ForEach(store.lists) { Text($0.name).tag($0.id) } }
                    NavigationLink {
                        TaskParentTreePicker(candidates: parentCandidates, selection: $parentID)
                    } label: {
                        // 入口仅显示当前父任务名称，完整层级交由树选择页表达，避免长路径挤压表单。
                        LabeledContent("父任务", value: store.tasks.first(where: { $0.id == parentID })?.title ?? "无")
                    }
                }
                Section("时间") {
                    // 日期入口回调输入无、输出共享草稿子页；返回只保留编辑状态，整个编辑取消时不发送写入。
                    NavigationLink { TaskDateDraft(title: "开始", enabled: $hasStart, date: $start, time: $startTime) } label: { LabeledContent("开始", value: hasStart ? taskDate(Values.day(start), time: startTime) : "未设置") }
                    NavigationLink { TaskDateDraft(title: "截止", enabled: $hasEnd, date: $end, time: $endTime) } label: { LabeledContent("截止", value: hasEnd ? taskDate(Values.day(end), time: endTime) : "未设置") }
                }
                if configuresProgress { Section("进度") {
                    // 数量与单位按相关性排列，两列输入减少表单长度；浮动标签继续复用统一输入控件。
                    progressFieldLayout {
                        TaskFloatingField(title: "目标总量", text: $total).keyboardType(.numberPad)
                        TaskFloatingField(title: "单位", text: $unit)
                    }
                    progressFieldLayout {
                        TaskFloatingField(title: "已完成量", text: $completed).keyboardType(.numberPad)
                        TaskFloatingField(title: "每次增加", text: $step).keyboardType(.numberPad)
                    }
                } }
                Section("选项") {
                    Picker("优先级", selection: $priority) { Text("高").tag("high"); Text("中").tag("medium"); Text("低").tag("low") }
                    Toggle("完成后自动归档", isOn: $autoArchive)
                }
                if !title.isEmpty, let validationError { InlineError(message: validationError) }
            }.navigationTitle(task == nil ? "新建任务" : taskType == "main" ? "编辑主任务" : "编辑任务").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: valid) { Task { await save() } } }
                .interactiveDismissDisabled(busy)
                // 日期开关回调输入前后布尔值；返回无；关闭立即清空时分，避免重新开启恢复隐藏旧时间。
                .onChange(of: hasStart) { _, value in if !value { startTime = "" } }
                .onChange(of: hasEnd) { _, value in if !value { endTime = "" } }
                // 清单变更回调输入前后清单ID、输出无；真正跨清单草稿清原父，PATCH必须明确null或重新选有效主父。
                .onChange(of: listID) { old, new in if old != 0 && old != new { parentID = 0 } }
                // 生命周期回调输入无、输出无；新编辑实例只装载一次，图标或日期子页返回时保留草稿与最初PATCH快照。
                .task { populate() }
        }
    }
    /// 一次装载编辑初值；参数：无；返回值：无；本编辑实例仅首次初始化，子页返回不覆盖草稿或最初PATCH快照，新sheet新State重新装载。
    private func populate() {
        guard !populated else { return }
        populated = true
        listID = task?.listId ?? parent?.listId ?? (store.lists.contains(where: { $0.id == preferredListID }) ? preferredListID : store.lists.first?.id ?? 0)
        parentID = task?.parentId ?? parent?.id ?? 0
        if let task {
            autoArchive = task.autoArchive ?? false
            icon = task.icon ?? "Folder"
            title = task.title; remark = task.remark; priority = task.priority; taskType = task.taskType
            // 整数初值去掉浮点存储的 .0；历史小数原样展示并要求校正，避免静默截断数据。
            total = task.progressTotal.formatted(.number.grouping(.never).precision(.fractionLength(0...2))); completed = task.progressCompleted.formatted(.number.grouping(.never).precision(.fractionLength(0...2))); step = task.progressStep.formatted(.number.grouping(.never).precision(.fractionLength(0...2))); unit = task.progressUnit
            hasStart = !task.startDate.isEmpty; hasEnd = !task.endDate.isEmpty
            start = Values.date(task.startDate); end = Values.date(task.endDate); startTime = task.startTime; endTime = task.endTime
        }
        original = fields
    }
    /// 保存白名单字段；参数：无；返回值：无；创建附带清单/父节点，编辑只提交变化字段；失败保留输入，成功关闭。
    private func save() async {
        guard valid else { error = validationError; return }
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        do {
            // 共享写保护覆盖所有详情和表单，服务端成功实体先合并，再独立刷新。
            if let task {
                let patch = Values.patch(original: original, edited: fields)
                // 编辑回调输入无、输出服务器实体；仅提交变化字段，不覆盖未提交字段。
                if !patch.isEmpty { let saved: AssistantTask = try await store.writeTask { try await store.api.request("/tasks/\(task.id)", method: "PATCH", body: patch) }; store.upsertTask(saved) }
            } else {
                let body = fields
                // 创建回调输入无、输出服务器实体；POST结果不明后原草稿禁止再次提交。
                let saved: AssistantTask = try await store.writeTask { try await store.api.request("/tasks", method: "POST", body: body) }; store.upsertTask(saved)
            }
            dismiss(); await store.refreshTaskWrite()
        } catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); self.error = error.localizedDescription; if task == nil && store.taskWriteBlocked { uncertainCreation = true } }
    }
}

/// 父任务选择页；只修改编辑草稿，候选由表单过滤，排除自身、后代及归档任务。
private struct TaskParentTreePicker: View {
    let candidates: [AssistantTask]
    @Binding var selection: Int
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<Int> = []

    /// 生成可见树行；参数：无；返回值：候选与缩进深度，缺失父级作为根显示，循环安全且沿用候选排序；无副作用。
    private var rows: [(task: AssistantTask, depth: Int)] {
        let ids = Set(candidates.map(\.id))
        var result: [(task: AssistantTask, depth: Int)] = []
        var visited: Set<Int> = []
        /// 追加展开节点；参数：task 为候选，depth 为非负深度；返回值：无；更新局部行数组，重复节点停止递归。
        func append(_ task: AssistantTask, depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            result.append((task, depth))
            if expanded.contains(task.id) {
                for child in candidates where child.parentId == task.id { append(child, depth: depth + 1) }
            }
        }
        for task in candidates where task.parentId == nil || !ids.contains(task.parentId!) {
            append(task, depth: 0)
        }
        return result
    }

    /// 构建树选择列表；参数：无；返回值：独立展开按钮与选择按钮，选择后更新绑定并返回，取消返回不改草稿；无服务器写入。
    var body: some View {
        List {
            Button { selection = 0; dismiss() } label: {
                HStack { Text("无父任务").foregroundStyle(.primary); Spacer(); if selection == 0 { Image(systemName: "checkmark").foregroundStyle(.teal) } }
            }
            Section {
                // 行回调输入候选节点及深度，输出树行；展开只影响本页，选择只写入父任务草稿。
                ForEach(rows, id: \.task.id) { row in
                    let hasChildren = candidates.contains { $0.parentId == row.task.id }
                    HStack(spacing: 10) {
                        if hasChildren {
                            Button {
                                if !expanded.insert(row.task.id).inserted { expanded.remove(row.task.id) }
                            } label: {
                                Image(systemName: expanded.contains(row.task.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold)).frame(width: 28, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(expanded.contains(row.task.id) ? "收起下级" : "展开下级")
                        } else { Color.clear.frame(width: 28, height: 44).accessibilityHidden(true) }
                        Button { selection = row.task.id; dismiss() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: TaskIcons.symbol(row.task.icon)).foregroundStyle(.teal)
                                Text(row.task.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                if selection == row.task.id { Image(systemName: "checkmark").foregroundStyle(.teal) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                    }.padding(.leading, CGFloat(row.depth) * 18)
                }
            }
        }
        .navigationTitle("父任务").navigationBarTitleDisplayMode(.inline)
        // 生命周期回调输入无、输出无；首次展示展开当前选择的祖先，环检测避免旧数据导致无限循环。
        .task {
            var parent = candidates.first { $0.id == selection }?.parentId
            var visited: Set<Int> = []
            while let id = parent, visited.insert(id).inserted {
                expanded.insert(id)
                parent = candidates.first { $0.id == id }?.parentId
            }
        }
    }
}

/// 本地化任务日期；参数：day 为服务端 yyyy-MM-dd，time 为可选 HH:mm；返回值：本地日期及原时分；无副作用。
private func taskDate(_ day: String, time: String) -> String {
    Values.date(day).formatted(date: .abbreviated, time: .omitted) + (time.isEmpty ? "" : " " + time)
}

/// 格式化任务行日期；参数：day 为服务端 yyyy-MM-dd，time 为可选 HH:mm；返回值：数字年月日及已设置的时分，避免系统英文月份占用宽度；无副作用。
private func taskRowDate(_ day: String, time: String) -> String {
    day.replacingOccurrences(of: "-", with: "/") + (time.isEmpty ? "" : " " + time)
}

/// 格式化任务数量；参数：progress 为任务进度，includesUnit 控制是否附加非空单位，默认附加；返回值：最多两位小数的完成数量 / 总数量文本；无副作用。
private func taskQuantity(_ progress: TaskProgress, includesUnit: Bool = true) -> String {
    progress.completed.formatted(.number.precision(.fractionLength(0...2))) + " / " + progress.total.formatted(.number.precision(.fractionLength(0...2))) + (!includesUnit || progress.unit.isEmpty ? "" : " " + progress.unit)
}
/// 格式化完成比例；参数：progress为汇总；返回值：最多一位小数百分比，如54.5%；无副作用。
private func taskPercent(_ progress: TaskProgress) -> String { (progress.fraction * 100).formatted(.number.precision(.fractionLength(0...1))) + "%" }
/// 构建对象归属路径；参数：task为当前节点，tasks为缓存树，lists为清单；返回值：清单与父级名称，不重复当前标题，环检测防死循环。
private func taskPath(_ task: AssistantTask, tasks: [AssistantTask], lists: [TaskList]) -> String {
    var parts: [String] = []
    var parent = task.parentId
    var visited: Set<Int> = [task.id]
    while let id = parent, visited.insert(id).inserted, let item = tasks.first(where: { $0.id == id }) { parts.insert(item.title, at: 0); parent = item.parentId }
    if let list = lists.first(where: { $0.id == task.listId }) { parts.insert(list.name, at: 0) }
    return parts.joined(separator: " › ")
}

/// 图标选择只操作编辑绑定草稿，离开编辑或取消不会持久化。
private struct TaskIconPicker: View {
    @Binding var selection: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    /// 构建六列图标目录；参数：无；返回值：44pt以上按钮与搜索，读屏含名称和选中状态；点击只更新草稿。
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 4), count: 6), spacing: 12) {
                // 图标回调输入目录记录、输出选择按钮；更新绑定后保留选择页，完成返回编辑。
                ForEach(TaskIcons.options.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.key.localizedCaseInsensitiveContains(search) }) { option in
                    Button { selection = option.key } label: {
                        Image(systemName: option.symbol).font(.system(size: 20)).frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(selection == option.key ? Color.teal : Color.primary)
                            .background(selection == option.key ? Color.teal.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            // 选中角标是非文本装饰，不随辅助字号放大；固定尺寸并角落内缩，避免遮盖主图标，读屏由isSelected表达。
                            .overlay(alignment: .topTrailing) { if selection == option.key { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).frame(width: 14, height: 14).foregroundStyle(.teal).padding(3).accessibilityHidden(true) } }
                    }.buttonStyle(.plain).accessibilityLabel(option.label).accessibilityAddTraits(selection == option.key ? .isSelected : [])
                }
            }.padding(16)
        }.navigationTitle("选择图标").navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "搜索图标")
            .toolbar { Button("完成") { dismiss() } }.toolbar(.hidden, for: .tabBar)
    }
}

/// 日期子页共享编辑草稿；返回保留输入，持久化仅由整个任务表单保存触发。
private struct TaskDateDraft: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var date: Date
    @Binding var time: String
    /// 构建日期草稿页；参数：无；返回值：原有系统开关、日期和时分组件；清除同步移除隐藏时分，无网络或保存副作用。
    var body: some View {
        Form {
            Toggle("设置日期", isOn: $enabled)
            if enabled { DatePicker("日期", selection: $date, displayedComponents: .date); TimeInput(title: "时间", value: $time) }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            // 开关回调输入旧新布尔值、输出无；关闭立即清空时分，重新开启不恢复旧时间。
            .onChange(of: enabled) { _, value in if !value { time = "" } }
    }
}
