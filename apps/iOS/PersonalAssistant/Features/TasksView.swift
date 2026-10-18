import SwiftUI
import UIKit

/// 任务工作区在日常执行与层级规划之间切换；两种视图共用云端任务与清单。
struct TasksView: View {
    @AppStorage("taskWorkspace") private var workspace = "todos"
    @Environment(\.dynamicTypeSize) private var workspaceTypeSize
    @State private var selectedListID = 0
    @State private var selectedTitle = "任务"
    @State private var selectedScope = "active"
    /// 构建任务首页；参数：无；返回值：原生分段切换与当前任务工作区，不复制业务数据或更改原树展示偏好。
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if workspaceTypeSize.isAccessibilitySize { workspacePicker.pickerStyle(.menu).frame(minHeight: 44) }
                else { workspacePicker.pickerStyle(.segmented) }
            }.padding(.horizontal, AppVisualStyle.pageInset).padding(.vertical, 8)
            if workspace == "todos" {
                TaskTodoView(selectedListID: $selectedListID)
            } else {
                // 选择回调输入清单 ID、标题与任务范围，输出无；只更新树的筛选与展示状态。
                TaskCollectionView(listID: selectedListID, title: selectedTitle, scope: selectedScope, isRoot: true) { id, title, scope in
                    selectedListID = id
                    selectedTitle = title
                    selectedScope = scope
                }.id("\(selectedListID)-\(selectedScope)")
            }
        }.background(AppVisualStyle.canvas)
    }
    /// 构建工作区选择器；参数：无；返回值：共用本机偏好的系统 Picker，辅助字号改用菜单而不挤压文字；不改变业务数据。
    private var workspacePicker: some View {
        Picker("任务工作区", selection: $workspace) {
            Text("待办事项").tag("todos")
            Text("任务树").tag("tree")
        }.accessibilityIdentifier("taskWorkspacePicker")
    }
}

/// 收起的清单目录；仅由任务首页按钮推入，保留清单管理与归档入口。
struct TaskDirectoryView: View {
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
                            count: Values.tasks(in: "active", all: store.tasks, listID: list.id).count
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
                    // 归档是实际导航入口，不用不可交互的目录行冒充按钮。
                    NavigationLink { TaskCollectionView(listID: 0, title: "已归档", scope: "archived") } label: {
                        TaskDirectoryRow(name: "已归档", symbol: "archivebox", color: .accentColor)
                    }
                }
            }
        }.listStyle(.insetGrouped).listSectionSpacing(16).navigationTitle("我的清单").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar).searchable(text: $search, prompt: "搜索清单")
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
            SymbolTile(symbol: symbol, color: color, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.body.weight(.medium))
                if !remark.isEmpty { Text(remark).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let count { Text(count.formatted()).font(.subheadline).foregroundStyle(.secondary) }
        }.padding(.vertical, 2)
    }
}

/// 清单内容共用树状与逐级浏览；层级状态局限本页，不新增 Tab 或嵌套 NavigationStack。
struct TaskCollectionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @AppStorage(TaskDisplayMode.storageKey) private var displayModeRaw = TaskDisplayMode.tree.rawValue
    @State private var browsePath: [TaskBrowsing.Location] = []
    private var list: TaskList? { store.lists.first { $0.id == listID } }
    /// 解析本机偏好；参数：无；返回值：未知偏好按默认树状显示；不改写保存值。
    private var displayMode: TaskDisplayMode { TaskDisplayMode(rawValue: displayModeRaw) ?? .tree }
    /// 读取仍有效的层级；参数：无；返回值：当前快照的连续路径，旧归属不继续使用；无副作用。
    private var validBrowsePath: [TaskBrowsing.Location] { TaskBrowsing.validPath(browsePath, in: scopedTasks, all: store.tasks) }
    /// 读取当前父任务；参数：无；返回值：有效路径末端的最新实体，根层为空；无副作用。
    private var currentParent: AssistantTask? { validBrowsePath.last.flatMap { location in store.tasks.first { $0.id == location.taskID } } }
    /// 判断新建入口权限；参数：无；返回值：共享写保护及父级限制均通过时 true；根层还要求有效清单，不写业务数据。
    private var canCreate: Bool {
        guard scope != "archived", !store.taskWriteBusy, !store.taskWriteBlocked, !store.lists.isEmpty else { return false }
        if let parent = currentParent { return TaskBrowsing.canCreateChild(of: parent, all: store.tasks) }
        return browsePath.isEmpty && (listID == 0 || list != nil)
    }
    /// 当前清单及显示范围的任务；参数：无；返回值：按完整祖先关系筛选的节点，归档父节点的下级不会在活跃范围升为顶层；无副作用。
    private var scopedTasks: [AssistantTask] { Values.tasks(in: scope, all: store.tasks, listID: listID) }
    /// 当前范围的浏览行；参数：无；返回值：树的节点/深度/分支标记、逐级直接下层或全范围平列搜索结果；缺父旧数据保留为范围根，无副作用。
    private var rows: [(task: AssistantTask, depth: Int, guides: [Bool])] {
        // 搜索始终覆盖清单/归档范围的全部层级；不使用当前父级过滤，匹配容器本身也保留结果。
        let scoped = scopedTasks
        if !search.isEmpty { return TaskBrowsing.search(search, in: scoped).map { ($0, 0, []) } }
        if displayMode == .levels { return TaskBrowsing.children(of: currentParent?.id, in: scoped).map { ($0, 0, []) } }
        var result: [(task: AssistantTask, depth: Int)] = []
        var visited: Set<Int> = []
        /// 深度遍历树；参数：task为当前节点，depth为缩进深度；返回值：无；循环节点跳过，最多缩进三层以保留可读宽度。
        func append(_ task: AssistantTask, depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            result.append((task, min(depth, 3)))
            if expanded.contains(task.id) { for child in scoped where child.parentId == task.id { append(child, depth: depth + 1) } }
        }
        for task in TaskBrowsing.roots(in: scoped) { append(task, depth: 0) }
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
    /// 构建任务浏览页；参数：无；返回值：稳定筛选栏及原生列表，搜索与刷新交由系统管理；写入口遵循共享保护。
    var body: some View {
        // 筛选栏与 List 互为兄弟，不再随导航栏搜索展开反复参与顶部 safe-area 高度协商。
        VStack(spacing: 0) {
            if isRoot { quickListSwitcher.padding(.horizontal, AppVisualStyle.pageInset).padding(.vertical, 8) }
            if displayMode == .levels, let parent = currentParent { browsingBar(parent) }
            taskList
        }
        .navigationTitle(currentParent?.title ?? list?.name ?? title).navigationBarTitleDisplayMode(.inline).toolbar(isRoot ? .visible : .hidden, for: .tabBar)
            .toolbar { collectionToolbar }
            // 导航绑定读取详情任务 ID；关闭回调输入呈现状态、返回无，返回列表时清理 ID 并保留筛选和展开状态。
            .navigationDestination(isPresented: Binding(
                get: { openedTaskID != nil },
                set: { if !$0 { openedTaskID = nil } }
            )) {
                if let openedTaskID { TaskDetailView(taskID: openedTaskID) }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索任务")
            // 创建回调无输入、返回统一表单；仅传入仍有效的父任务，失效路径由快照回调关闭，不回退为无父创建。
            .sheet(isPresented: $creating) {
                if browsePath.isEmpty || currentParent != nil { TaskEditor(task: nil, parent: currentParent, preferredListID: listID) }
            }
            .sheet(item: $editedTask) { task in TaskEditor(task: task, parent: nil) }
            // 确认绑定仅控制独立系统弹窗；呈现参数捕获待删除实体，避免关闭清空选择时丢失确认对象。
            .alert("删除任务？", isPresented: Binding(
                get: { deletedTask != nil }, set: { if !$0 { deletedTask = nil } }
            ), presenting: deletedTask) { task in
                // 确认回调输入已捕获任务、返回操作按钮；仅确认后发起删除，取消不修改数据。
                Button("取消", role: .cancel) { deletedTask = nil }
                Button("删除", role: .destructive) { Task { await removeTask(task) } }
            } message: { task in
                // 消息回调输入待删除任务、返回级联影响说明；不修改业务数据。
                Text("将删除“" + task.title + "”及其全部下级任务。")
            }
            .sheet(isPresented: $editingList) { if let list { ListEditor(list: list) } }
            .confirmationDialog("删除清单及其中全部任务？", isPresented: $deletingList, titleVisibility: .visible) { Button("删除清单", role: .destructive) { Task { await removeList() } } }
            // 首次展示或身份改变回调输入无、输出无；刷新后保留原有默认主任务展开行为，不随展示模式重置清单范围。
            .task(id: store.cloudSessionID) {
                let generation = store.cloudSessionID
                if isRoot { await reload() }
                guard !Task.isCancelled, generation == store.cloudSessionID else { return }
                initializeTree()
            }
            // 偏好/范围回调输入前后值、返回无；清理旧层级、详情和排序，保留树原有折叠集合与当前清单归档范围。
            .onChange(of: displayModeRaw) { _, _ in resetBrowsing() }
            .onChange(of: listID) { _, _ in resetBrowsing(); initializedTree = false; initializeTree() }
            .onChange(of: scope) { _, _ in resetBrowsing() }
            // 身份回调输入前后会话 ID、返回无；关闭所有旧身份选中内容，数据刷新由上述 task 负责。
            .onChange(of: store.cloudSessionID) { _, _ in
                resetBrowsing(); expanded = []; initializedTree = false; error = nil
                editingList = false; deletingList = false
            }
            // 快照回调输入前后任务数组、返回无；移动/归档/删除后修剪路径，禁止失效节点后代继续留在旧层。
            .onChange(of: store.tasks) { _, _ in reconcileBrowsing() }
            // 清单快照回调输入前后数组、返回无；当前清单消失时退出旧浏览及表单，不把原下级留在失效清单页面。
            .onChange(of: store.lists) { _, _ in
                if listID != 0 && list == nil { resetBrowsing(); if isRoot { onSelect?(0, "任务", scope) } else { dismiss() } }
            }
            // 搜索回调输入前后查询、返回无；搜索期间关闭系统排序，不提交任何重排。
            .onChange(of: search) { _, value in if !value.isEmpty { editMode = .inactive } }
    }

    /// 构建原生任务列表；参数：无；返回值：树、当前子层或全范围搜索结果；刷新与行操作共用既有业务方法。
    private var taskList: some View {
        let visibleParentIDs = Set(scopedTasks.compactMap(\.parentId))
        return List {
            if let notice = store.taskNotice { InlineError(message: notice); Button("刷新任务") { Task { await reload() } } }
            if let error { InlineError(message: error); Button("重新加载") { Task { await reload() } } }
            if loading && rows.isEmpty { ProgressView("加载任务…") }
            if rows.isEmpty && error == nil && !loading {
                ContentUnavailableView(search.isEmpty ? scope == "archived" ? "暂无归档任务" : "暂无任务" : "没有匹配的任务", systemImage: "checklist")
                // 空层新建回调无输入及返回；空主任务也可创建，下级继承父任务清单，写锁和归档祖先限制与工具栏一致。
                if search.isEmpty && scope != "archived" && !store.lists.isEmpty {
                    Button("新建任务") { if canCreate { creating = true } }.disabled(!canCreate)
                }
            }
            Section {
                // 行构造回调输入可见节点/深度、返回浏览行；路径只在搜索结果显示，不修改任务。
                ForEach(rows, id: \.task.id) { row in
                    let hasChildren = visibleParentIDs.contains(row.task.id)
                    Button { open(row.task, hasVisibleChildren: hasChildren) } label: {
                        HStack(spacing: 8) {
                            TaskRow(task: row.task, showsContext: !search.isEmpty, compact: true)
                            if search.isEmpty && displayMode == .levels && TaskBrowsing.isContainer(row.task, all: store.tasks) {
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("taskBrowseRow.\(row.task.id)")
                    .accessibilityHint(!search.isEmpty ? "查看详情" : displayMode == .levels && TaskBrowsing.isContainer(row.task, all: store.tasks) ? "进入下级" : hasChildren ? (expanded.contains(row.task.id) ? "收起下级" : "展开下级") : "查看详情")
                    // 原树的默认展开、缩进与连线保持；逐级/搜索结果均为一层，不暗示错误父子关系。
                    .padding(.leading, CGFloat(row.depth) * 20).padding(.vertical, 1)
                    .overlay(alignment: .leading) {
                        if row.depth > 0 {
                            TaskTreeGuides(continuations: row.guides).frame(width: CGFloat(row.depth) * 20)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)).listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // 滑动回调无输入及返回；编辑/删除先选择实体，归档走原共享写接口，不让确认前移除行动画抢先执行。
                        Button("删除", systemImage: "trash") { deletedTask = row.task }.tint(.red)
                            .disabled(store.taskWriteBusy || store.taskWriteBlocked)
                        Button(row.task.archived ? "取消归档" : "归档", systemImage: "archivebox") { Task { await archiveTask(row.task) } }
                            .tint(.orange).disabled(store.taskWriteBusy || store.taskWriteBlocked)
                        Button("编辑", systemImage: "pencil") { editedTask = row.task }.tint(.blue)
                            .disabled(store.taskWriteBusy || store.taskWriteBlocked)
                    }
                    .moveDisabled(!search.isEmpty || loading || store.taskWriteBusy || store.taskWriteBlocked)
                }
                // 拖动回调输入源索引/目标位置、返回无；只对同父节点排序，方法再次拒绝搜索中的陈旧回调。
                .onMove { source, destination in Task { await reorder(source, to: destination) } }
            }.listSectionSeparator(.hidden)
        }
        .environment(\.editMode, $editMode).listStyle(.plain).accessibilityIdentifier("taskBrowsingList")
        // 刷新回调无输入及返回；保留系统下拉刷新，不监听滚动偏移或使用延迟调整布局。
        .refreshable { await reload() }
    }

    /// 构建本地层级导航；参数：parent 为当前有效容器；返回值：明确上层返回、完整路径菜单与任务详情入口；仅修改浏览状态。
    private func browsingBar(_ parent: AssistantTask) -> some View {
        HStack(spacing: 12) {
            // 返回回调无输入/返回；只移除末层，关闭排序，不改变清单或归档范围。
            Button("返回上层", systemImage: "chevron.left") { browsePath = Array(validBrowsePath.dropLast()); editMode = .inactive }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("taskBrowseBack")
            Menu {
                Button(list?.name ?? title) { browsePath = []; editMode = .inactive }
                // 层级回调输入路径索引、返回祖先按钮；选择仅保留对应前缀，避免建立额外 NavigationStack。
                ForEach(Array(validBrowsePath.enumerated()), id: \.element.taskID) { index, location in
                    Button(store.tasks.first { $0.id == location.taskID }?.title ?? "任务") {
                        browsePath = Array(validBrowsePath.prefix(index + 1)); editMode = .inactive
                    }
                }
            } label: {
                Text(([list?.name ?? title] + validBrowsePath.compactMap { location in store.tasks.first { $0.id == location.taskID }?.title }).joined(separator: " › "))
                    .font(.subheadline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.leading)
            }.accessibilityLabel("任务层级路径").accessibilityIdentifier("taskBrowsePath")
            Spacer(minLength: 0)
            // 详情回调无输入/返回；当前容器即使为空也可查看原详情，不执行任何写入。
            Button("任务详情") { openedTaskID = parent.id }.font(.subheadline).frame(minHeight: 44)
                .accessibilityIdentifier("taskBrowseDetails")
        }.padding(.horizontal, AppVisualStyle.pageInset)
    }

    /// 打开任务行；参数：task 为行快照，hasVisibleChildren 表示当前范围有直接下级；返回值：无；搜索直达详情，逐级进入容器，树沿用展开行为，不写数据。
    private func open(_ task: AssistantTask, hasVisibleChildren: Bool) {
        guard !editMode.isEditing else { return }
        if !search.isEmpty { openedTaskID = task.id }
        else if displayMode == .levels && TaskBrowsing.isContainer(task, all: store.tasks) {
            browsePath = validBrowsePath + [TaskBrowsing.Location(task)]
        } else if displayMode == .tree && hasVisibleChildren {
            if !expanded.insert(task.id).inserted { expanded.remove(task.id) }
        } else { openedTaskID = task.id }
    }

    /// 初始化旧树展开状态；参数：无；返回值：无；仅本页首次执行，保持主任务默认展开且不覆盖用户后续折叠。
    private func initializeTree() {
        guard !initializedTree else { return }
        expanded = Set(store.tasks.filter { (listID == 0 || $0.listId == listID) && $0.taskType == "main" }.map(\.id))
        initializedTree = true
    }

    /// 清除选中导航；参数：无；返回值：无；切换展示/身份/范围时关闭旧详情、表单、确认和排序，不修改筛选或任务数据。
    private func resetBrowsing() {
        browsePath = []; openedTaskID = nil; creating = false; editedTask = nil; deletedTask = nil; editMode = .inactive
        editingList = false; deletingList = false
    }

    /// 校验浏览状态；参数：无；返回值：无；实体移动/删除/归档后退到有效上层，关闭旧层表单，详情消失时清空选择，不改写业务数据。
    private func reconcileBrowsing() {
        let valid = validBrowsePath
        if valid != browsePath {
            resetBrowsing(); browsePath = valid
        }
        if let id = openedTaskID, !scopedTasks.contains(where: { $0.id == id }) { openedTaskID = nil }
        if let editedTask, !store.tasks.contains(where: { $0.id == editedTask.id }) { self.editedTask = nil }
        expanded.formIntersection(Set(store.tasks.map(\.id)))
    }
    /// 构建任务筛选操作层；参数：无；返回值：单层原生玻璃筛选栏，辅助字号改为上下排列；减少透明度时使用实底，不修改任务数据。
    private var quickListSwitcher: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) { listMenu; archiveToggle }
            } else {
                HStack(spacing: 12) { listMenu; Spacer(minLength: 0); archiveToggle }
            }
        }
        .font(.subheadline).padding(.horizontal, 16).padding(.vertical, 4)
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)) }
        }
        .glassEffect(reduceTransparency ? .identity : .regular, in: .rect(cornerRadius: 26))
    }

    /// 构建清单选择菜单；参数：无；返回值：显示当前范围的原生 Picker 菜单，选择仅更新筛选，不写入业务数据。
    private var listMenu: some View {
        Menu {
            Picker("切换任务清单", selection: Binding(
                get: { listID },
                // 选择回调输入清单 ID、返回无；保留归档显示偏好，由首页重建对应任务树。
                set: { id in onSelect?(id, store.lists.first { $0.id == id }?.name ?? "任务", scope) }
            )) {
                Label("全部任务", systemImage: "checklist").tag(0)
                ForEach(store.lists) { list in
                    Label(list.name, systemImage: TaskListAppearance.symbol(list.icon)).tag(list.id)
                }
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: list.map { TaskListAppearance.symbol($0.icon) } ?? "checklist")
                Text(list?.name ?? "全部任务").lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .accessibilityLabel("切换任务清单").accessibilityValue(list?.name ?? "全部任务")
            .accessibilityIdentifier("taskListSwitcher")
    }

    /// 构建归档范围切换；参数：无；返回值：44 点以上触控范围及明确选中状态，仅切换可见任务范围。
    private var archiveToggle: some View {
        // 点击回调无输入、返回无；包含归档与仅未归档之间切换，保持当前清单。
        Button {
            onSelect?(listID, list?.name ?? title, scope == "all" ? "active" : "all")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: scope == "all" ? "checkmark.square.fill" : "square")
                    .foregroundStyle(scope == "all" ? Color.accentColor : Color.secondary)
                Text("已归档").foregroundStyle(.secondary)
            }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("显示已归档任务")
            .accessibilityValue(scope == "all" ? "已勾选" : "未勾选")
            .accessibilityAddTraits(scope == "all" ? [.isSelected] : [])
            .accessibilityIdentifier("taskShowArchivedToggle")
    }
    /// 构建任务导航操作；参数：无；返回值：清单目录、新建及共用菜单，全部任务也可切换展示；偏好只写本机，业务写入口遵循共享保护。
    @ToolbarContentBuilder
    private var collectionToolbar: some ToolbarContent {
        if isRoot {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { TaskDirectoryView { id, title, scope in onSelect?(id, title, scope) } } label: { Label("我的清单", systemImage: "folder") }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // 新建回调无输入/返回；仅在当前上下文有效时呈现表单，空主任务与普通根层使用同一创建流程。
            Button("新建任务", systemImage: "plus") { if canCreate { creating = true } }.disabled(!canCreate)
            Menu {
                Picker("任务展示", selection: $displayModeRaw) {
                    ForEach(TaskDisplayMode.allCases, id: \.rawValue) { mode in Text(mode.title).tag(mode.rawValue) }
                }.pickerStyle(.inline).accessibilityIdentifier("taskDisplayModePicker")
                // 排序回调无输入/返回；仅切换原生 EditMode，搜索中和共享写锁期间禁止使用。
                Button(editMode.isEditing ? "完成排序" : "排序") { editMode = editMode.isEditing ? .inactive : .active }
                    .disabled(loading || !search.isEmpty || store.taskWriteBusy || store.taskWriteBlocked)
                if let parent = currentParent {
                    // 当前容器操作回调无输入/返回；复用原编辑、归档、删除流程，允许浏览层继续管理自身。
                    Button("编辑任务") { editedTask = parent }.disabled(store.taskWriteBusy || store.taskWriteBlocked)
                    Button(parent.archived ? "取消归档" : "归档", systemImage: "archivebox") { Task { await archiveTask(parent) } }
                        .disabled(store.taskWriteBusy || store.taskWriteBlocked)
                    Button("删除任务", role: .destructive) { deletedTask = parent }.disabled(store.taskWriteBusy || store.taskWriteBlocked)
                }
                if list != nil {
                    Button("编辑清单") { editingList = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked)
                    Button("删除清单", role: .destructive) { deletingList = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked)
                }
            } label: { Label("任务选项", systemImage: "ellipsis") }.accessibilityIdentifier("taskCollectionOptions")
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
    /// 保存同父级顺序；参数：source为单行源索引，destination为目标插入位置且在可见行范围内；返回值：无；搜索/写锁拒绝，跨层归属不变，成功后独立刷新。
    private func reorder(_ source: IndexSet, to destination: Int) async {
        guard search.isEmpty, !loading, !store.taskWriteBusy, !store.taskWriteBlocked else { return }
        let original = rows.map(\.task)
        guard let index = source.first, source.count == 1, original.indices.contains(index), (0...original.count).contains(destination) else { return }
        var ordered = original; ordered.move(fromOffsets: source, toOffset: destination)
        // 全部任务模式的根节点可能来自不同清单；仅重排同清单同父级，其他清单及隐藏节点保留原槽位。
        let siblings = ordered.filter { $0.parentId == original[index].parentId && $0.listId == original[index].listId }
        let originalSiblings = original.filter { $0.parentId == original[index].parentId && $0.listId == original[index].listId }
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
                // 起止日期时间共用一行并紧跟进度条；空日期不占位，所有任务行入口保持一致。
                if !task.startDate.isEmpty || !task.endDate.isEmpty {
                    metadata.font(.caption).foregroundStyle(.secondary)
                }
                if showsContext { Text(taskPath(task, tasks: store.tasks, lists: store.lists)).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, compact ? 8 : 10)
            .padding(.horizontal, compact ? 10 : 0)
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
    /// 构建进度条下方的日期信息；参数：无；返回值：已设置起止日期时间的单行内容，窄行最多缩小至一半，辅助功能保留完整值，空日期不占位；无副作用。
    private var metadata: some View {
        // 日期保持同一行，优先使用完整年月日和时分；受树层级或字号挤压时缩放文字，避免日期与时间拆行。
        dateRange.font(.caption2).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.5)
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
    /// 构建日期范围内容；参数：无；返回值：起止日期时间并排在同一行，以图标区分开始和结束，活动任务逾期结束日期标红，归档保持中性色；无副作用。
    private var dateRange: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
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
}
/// 任务详情共用的进度摘要；主任务、普通任务及归档任务共用字号与排列，操作按钮由外层控制。
private struct TaskDetailProgressSummary: View {
    let summary: TaskProgress
    let archived: Bool

    /// 构建数量、进度条与百分比；参数：无；返回值：至少 44 点高的居中摘要，归档使用中性色；无副作用。
    var body: some View {
        VStack(spacing: 3) {
            Text(taskQuantity(summary, includesUnit: false))
                .font(.headline).monospacedDigit()
            ProgressView(value: summary.fraction)
                .tint(archived ? .secondary : .teal).accessibilityHidden(true)
            Text(taskPercent(summary))
                .font(.caption).foregroundStyle(archived ? Color.secondary : Color.teal).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 44)
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
    /// 构建任务详情；参数：无；返回值：任务信息与统一进度摘要，活动叶任务可按步长调整进度，未归档祖先下的活动主任务可新建下级；容器进度由下级汇总，创建继续遵循共享写保护。
    var body: some View {
        Group {
            if let task = item {
                let summary = Values.progress(task, all: store.tasks)
                let container = task.taskType == "main" || !children.isEmpty
                ScrollView {
                    VStack(alignment: .leading, spacing: AppVisualStyle.sectionSpacing) {
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
                            // 所有类型复用同一胶囊和摘要；容器进度由下级汇总，归档只读，仅活动叶任务显示加减按钮。
                            HStack(spacing: 12) {
                                if !container && !task.archived {
                                    // 操作回调参数无、返回无；统一使用服务端步长接口，提交期间禁用，防止连续点击重复写入。
                                    Button { Task { await progress("decrement") } } label: {
                                        Image(systemName: "minus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.teal)
                                    .accessibilityLabel("减少进度")
                                    .disabled(task.progressCompleted <= 0 || busy || store.taskWriteBusy || store.taskWriteBlocked)
                                }
                                TaskDetailProgressSummary(summary: summary, archived: task.archived)
                                if !container && !task.archived {
                                    // 操作回调参数无、返回无；按服务端步长增加进度，共用原有写保护。
                                    Button { Task { await progress("increment") } } label: {
                                        Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.teal)
                                    .accessibilityLabel("增加进度")
                                    .disabled(task.progressCompleted >= task.progressTotal || busy || store.taskWriteBusy || store.taskWriteBlocked)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                        }
                        .padding(20)
                        .cardSurface()

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
                        .cardSurface()

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
                                .cardSurface()
                        }
                        if !task.remark.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("备注", systemImage: "text.alignleft").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                                Text(task.remark).font(.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(20)
                                .cardSurface()
                        }
                        if let notice = store.taskNotice {
                            InlineError(message: notice)
                            Button("刷新任务") { Task { await store.refreshTaskWrite(confirmedWrite: false) } }
                        } else if let error { InlineError(message: error) }
                    }.padding(.horizontal, AppVisualStyle.pageInset).padding(.vertical, 16)
                        .frame(maxWidth: AppVisualStyle.maxContentWidth).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("任务").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                    .toolbar {
                        if TaskBrowsing.canCreateChild(of: task, all: store.tasks) {
                            // 与任务首页共用导航栏位置及入口名称；归档祖先下的未归档主任务也禁止新建。
                            ToolbarItem(placement: .topBarTrailing) {
                                // 点击回调参数无、返回无；再次校验当前父级与共享写锁，打开统一表单并继承清单，不绕过既有保存校验。
                                Button("新建任务", systemImage: "plus") {
                                    if !store.taskWriteBusy && !store.taskWriteBlocked && TaskBrowsing.canCreateChild(of: task, all: store.tasks) { addingChild = true }
                                }.disabled(busy || store.taskWriteBusy || store.taskWriteBlocked)
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                // 菜单回调无输入、返回操作项；详情页直接管理当前任务，不要求返回任务树滑动查找。
                                Button("编辑", systemImage: "pencil") { editing = true }
                                Button(task.archived ? "取消归档" : "归档", systemImage: "archivebox") { Task { await archive(task) } }
                                Button("删除", systemImage: "trash", role: .destructive) { deleting = true }
                            } label: { Label("任务操作", systemImage: "ellipsis") }
                                .disabled(busy || store.taskWriteBusy || store.taskWriteBlocked)
                        }
                    }
                    .sheet(isPresented: $editing) { TaskEditor(task: task, parent: nil) }
                    // 表单回调参数无、返回新建视图；默认继承父任务及清单，支持任务／主任务两种类型，取消不写入。
                    .sheet(isPresented: $addingChild) { TaskEditor(task: nil, parent: task) }
                    .alert("删除任务？", isPresented: $deleting) {
                        Button("取消", role: .cancel) { }
                        Button("删除", role: .destructive) { Task { await remove() } }
                    } message: {
                        Text("将删除“" + task.title + "”及其全部下级任务。")
                    }
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
    var initialDeadline: Date? = nil
    var initialPriority = "medium"
    @State private var showsProgress = false
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
    /// 计算目标总量按钮范围；参数：无；返回值：至少覆盖已完成量及每次增加、且不超过业务上限的整数区间；不改写其他字段，手动输入仍由保存校验处理。
    private var totalStepperRange: ClosedRange<Int> {
        min(1_000_000_000, max(1, max(Int(completed) ?? 0, Int(step) ?? 1)))...1_000_000_000
    }
    /// 计算进度按钮上限；参数：无；返回值：当前有效目标总量，异常草稿按 1 至业务上限收敛以避免构造无效范围；无副作用。
    private var progressStepperMaximum: Int { min(1_000_000_000, max(1, Int(total) ?? 1)) }
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
    /// 主父候选；参数：无；返回值：同清单活跃主任务，排除归档祖先的后代、自身和后代；旧具体父节点不作为新候选，不改写已有归属。
    private var parentCandidates: [AssistantTask] {
        var excluded: Set<Int> = task.map { [$0.id] } ?? []
        var changed = true
        while changed { changed = false; for item in store.tasks { if let parent = item.parentId, excluded.contains(parent), excluded.insert(item.id).inserted { changed = true } } }
        return Values.tasks(in: "active", all: store.tasks, listID: listID).filter { $0.taskType == "main" && !excluded.contains($0.id) }
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
                    // 开始与截止各保留一个入口；底部系统滚轮一次选择日期和时间，整个表单保存前不持久化。
                    OptionalDateTimeInput(title: "开始", enabled: $hasStart, date: $start, time: $startTime)
                    OptionalDateTimeInput(title: "截止", enabled: $hasEnd, date: $end, time: $endTime)
                }
                if configuresProgress { Section {
                    DisclosureGroup("量化进度", isExpanded: $showsProgress) {
                        // 简单待办默认一次完成，量化任务展开后仍使用原有整数及单位配置，不覆盖隐藏草稿。
                        progressFieldLayout {
                            TaskFloatingField(title: "目标总量", text: $total, stepperRange: totalStepperRange).keyboardType(.numberPad)
                            TaskFloatingField(title: "单位", text: $unit, minimumInputHeight: 44)
                        }.listRowInsets(TaskFloatingField.rowInsets)
                        progressFieldLayout {
                            TaskFloatingField(title: "已完成量", text: $completed, stepperRange: 0...progressStepperMaximum).keyboardType(.numberPad)
                            TaskFloatingField(title: "每次增加", text: $step, stepperRange: 1...progressStepperMaximum).keyboardType(.numberPad)
                        }.listRowInsets(TaskFloatingField.rowInsets)
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
                // 日期启用状态回调输入前后布尔值；返回无；清除日期同时清空时分，避免恢复隐藏旧时间。
                .onChange(of: hasStart) { _, value in if !value { startTime = "" } }
                .onChange(of: hasEnd) { _, value in if !value { endTime = "" } }
                // 清单变更回调输入前后清单ID、输出无；真正跨清单草稿清原父，PATCH必须明确null或重新选有效主父。
                .onChange(of: listID) { old, new in if old != 0 && old != new { parentID = 0 } }
                // 生命周期回调输入无、输出无；新编辑实例只装载一次，图标子页返回时保留草稿与最初PATCH快照。
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
            showsProgress = task.progressTotal != 1 || task.progressStep != 1 || task.progressCompleted > 0
        } else {
            // 智能范围仅为新草稿提供初始安排；不影响编辑、已有父任务或保存时的白名单约束。
            priority = ["high", "medium", "low"].contains(initialPriority) ? initialPriority : "medium"
            if let initialDeadline { hasEnd = true; end = initialDeadline }
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
