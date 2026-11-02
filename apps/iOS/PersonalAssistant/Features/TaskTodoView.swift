import SwiftUI
import UIKit

/// 项目详情中的待办区；直接复用项目子任务，不建立独立待办首页或存储。
struct TaskProjectTodos: View {
    @Environment(AppStore.self) private var store
    let parentID: Int
    /// 外层详情操作锁；为 true 时禁止与详情编辑、归档等写操作并发。
    let disabled: Bool
    /// 添加回调；参数：无；返回值：无；由项目详情打开继承父任务及清单的统一表单。
    let onAdd: () -> Void
    @State private var now = Date.now
    @State private var editedTask: AssistantTask?
    @State private var openedTaskID: Int?
    @State private var pendingID: Int?
    @State private var error: String?

    /// 获取当前项目；参数：无；返回值：最新快照中的项目，删除后为空；无副作用。
    private var parent: AssistantTask? { store.tasks.first { $0.id == parentID } }
    /// 获取项目直接下级；参数：无；返回值：保持原顺序的待办及嵌套项目，归档节点保留查看入口；无副作用。
    private var children: [AssistantTask] { TaskTodoRules.projectChildren(of: parentID, in: store.tasks) }
    /// 获取可执行叶标识；参数：无；返回值：仅当前项目下可勾选的活动直接子任务 ID；无副作用。
    private var actionableIDs: Set<Int> { Set(TaskTodoRules.projectTodos(of: parentID, in: store.tasks).map(\.id)) }
    /// 读取共享写保护；参数：无；返回值：外层操作、共享写锁或本区写入期间为 true；无副作用。
    private var writeDisabled: Bool { disabled || store.taskWriteBusy || store.taskWriteBlocked || pendingID != nil }
    /// 判断添加权限；参数：无；返回值：当前父级为活动主任务且共享写保护通过时为 true；无副作用。
    private var canAdd: Bool { !writeDisabled && parent.map { TaskBrowsing.canCreateChild(of: $0, all: store.tasks) } == true }

    /// 构建项目待办区；参数：无；返回值：项目内添加、直接子任务完成操作及嵌套项目导航；旧身份和失效归属会关闭选中内容，所有写入均由统一保护执行。
    var body: some View {
        let actionable = actionableIDs
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待办事项").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if parent.map({ TaskBrowsing.canCreateChild(of: $0, all: store.tasks) }) == true {
                    // 添加回调无参数、返回值无；再次校验父级与共享锁后，由详情页呈现统一表单。
                    Button("添加待办", systemImage: "plus") { if canAdd { onAdd() } }
                        .font(.subheadline).frame(minHeight: 44).disabled(!canAdd)
                        .accessibilityIdentifier("taskProjectTodoAdd")
                }
            }
            if children.isEmpty {
                Text("暂无待办").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            // 行构造回调输入项目直接子任务、返回待办行或项目导航；不跨层汇总后代，避免同一待办在多个项目重复出现。
            ForEach(children) { child in
                if TaskBrowsing.isContainer(child, all: store.tasks) {
                    NavigationLink { TaskDetailView(taskID: child.id) } label: {
                        HStack(spacing: 8) {
                            TaskRow(task: child, showsContext: false, compact: true)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("taskProjectOpen.\(child.id)")
                } else {
                    TaskTodoRow(task: child, context: "", now: now, busy: pendingID == child.id,
                                disabled: writeDisabled || !actionable.contains(child.id),
                                // 勾选回调无参数、返回值无；使用当前快照再验证归属并提交一次完成量更新。
                                onToggle: { Task { await toggleCompletion(child) } },
                                // 详情回调无参数、返回值无；只更新导航 ID，不更改任务或完成状态。
                                onOpen: { openedTaskID = child.id })
                        .contextMenu {
                            Button("编辑", systemImage: "pencil") { editedTask = child }
                                .disabled(writeDisabled || !actionable.contains(child.id))
                        }
                }
            }
            if let error { InlineError(message: error) }
        }
        .accessibilityIdentifier("taskProjectTodos.\(parentID)")
        // 编辑回调输入所选任务、返回统一编辑表单；提交沿用原任务 ID、父级与清单。
        .sheet(item: $editedTask) { TaskEditor(task: $0, parent: nil) }
        .navigationDestination(isPresented: Binding(
            get: { openedTaskID != nil },
            // 导航关闭回调输入呈现状态、返回值无；返回后保持项目内待办顺序。
            set: { if !$0 { openedTaskID = nil } }
        )) {
            if let openedTaskID { TaskDetailView(taskID: openedTaskID) }
        }
        .task(id: store.cloudSessionID) {
            // 时钟回调无参数、返回值无；只更新相对日期和逾期文案，离页或身份变化时自动取消。
            while !Task.isCancelled {
                now = .now
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: store.cloudSessionID) { _, _ in
            // 身份回调输入前后标识、返回值无；清除旧身份编辑、导航和请求反馈。
            editedTask = nil; openedTaskID = nil; pendingID = nil; error = nil
        }
        .onChange(of: store.tasks) { _, _ in
            // 快照回调输入前后数组、返回值无；任务移走或父级归档后关闭旧草稿，不因完成离开待办状态而关闭详情。
            if let editedTask, !TaskTodoRules.projectTodos(of: parentID, in: store.tasks).contains(where: { $0.id == editedTask.id }) {
                self.editedTask = nil
            }
            if let openedTaskID, !children.contains(where: { $0.id == openedTaskID }) { self.openedTaskID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in now = .now }
    }

    /// 勾选或撤销项目待办；参数：task 为行显示时的具体叶任务快照；返回值：无；拒绝失效或跨项目快照，旧小数先编辑校正，仅 PATCH progressCompleted，错误保留数据且未知结果不重发。
    private func toggleCompletion(_ task: AssistantTask) async {
        guard !writeDisabled,
              let current = TaskTodoRules.projectTodos(of: parentID, in: store.tasks).first(where: { $0.id == task.id }),
              current == task else { return }
        guard TaskTodoRules.canToggleCompletion(current) else { editedTask = current; return }
        let generation = store.cloudSessionID
        pendingID = current.id
        defer { if generation == store.cloudSessionID { pendingID = nil } }
        do {
            // 写回调无参数、返回服务器确认实体；只提交完成量，撤销显式提交 0，不覆盖其他字段，汇总由原任务树负责。
            let saved: AssistantTask = try await store.writeTask {
                try await store.api.request("/tasks/\(current.id)", method: "PATCH", body: TaskTodoRules.completionPatch(for: current))
            }
            store.upsertTask(saved); error = nil
            await store.refreshTaskWrite()
        } catch {
            guard generation == store.cloudSessionID, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
}

/// 待办执行行；勾选与详情是两个独立按钮，标题和数量不依赖颜色表达状态。
struct TaskTodoRow: View {
    let task: AssistantTask
    let context: String
    let now: Date
    let busy: Bool
    let disabled: Bool
    /// 完成回调；参数：无；返回值：无；调用方负责最新归属校验、写入保护及服务器确认。
    let onToggle: () -> Void
    /// 详情回调；参数：无；返回值：无；调用方打开当前任务详情，不修改完成状态。
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 读取完成状态；参数：无；返回值：按叶节点数量判断的完成状态；无副作用。
    private var completed: Bool { TaskTodoRules.isCompleted(task) }
    /// 构建待办行；参数：无；返回值：独立 44 点完成按钮与完整详情入口，辅助字号标题不截断，量化任务才显示进度；写入由调用者负责。
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button(action: onToggle) {
                Group {
                    if busy { ProgressView() }
                    else { Image(systemName: !TaskTodoRules.canToggleCompletion(task) ? "exclamationmark.circle" : completed ? "checkmark.circle.fill" : "circle").font(.title2.weight(.light)) }
                }.frame(width: 44, height: 44)
                    .foregroundStyle(completed ? Color.green : Color.secondary)
                    .contentShape(Rectangle())
            }.buttonStyle(.borderless).disabled(disabled)
                .accessibilityLabel((!TaskTodoRules.canToggleCompletion(task) ? "编辑为整数进度：" : completed ? "重新打开，进度归零：" : "标记完成：") + task.title)
                .accessibilityIdentifier("todoComplete.\(task.id)")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(task.title).font(.body.weight(.medium))
                            .foregroundStyle(completed || task.archived ? .secondary : .primary)
                            .strikethrough(completed || task.archived).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if task.archived {
                            Image(systemName: "archivebox").font(.caption).foregroundStyle(.secondary).accessibilityLabel("已归档")
                        } else if task.priority == "high" {
                            Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("重要")
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { dueLabel; contextLabel }
                        VStack(alignment: .leading, spacing: 4) { dueLabel; contextLabel }
                    }.font(.caption).foregroundStyle(.secondary)
                    if task.progressTotal > 1 {
                        HStack(spacing: 10) {
                            ProgressView(value: min(task.progressCompleted, task.progressTotal), total: task.progressTotal).tint(completed ? .green : .accentColor)
                                .accessibilityHidden(true)
                            Text(task.progressCompleted.formatted() + " / " + task.progressTotal.formatted() + (task.progressUnit.isEmpty ? "" : " " + task.progressUnit))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }.padding(.vertical, 10).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("查看任务详情")
                .accessibilityIdentifier("todoOpen.\(task.id)")
        }.listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 16))
    }

    /// 构建截止或开始标记；参数：无；返回值：相对日期与已有时分，逾期同时有文字和符号，未安排不占位；无副作用。
    @ViewBuilder
    private var dueLabel: some View {
        if !task.endDate.isEmpty {
            let overdue = !completed && !task.archived && Values.taskIsOverdue(task, all: [task], now: now)
            Label(dateLabel(task.endDate) + (task.endTime.isEmpty ? "" : " " + task.endTime) + (overdue ? " · 逾期" : ""), systemImage: overdue ? "clock.badge.exclamationmark" : "calendar")
                .foregroundStyle(overdue ? Color.red : Color.secondary)
        } else if !task.startDate.isEmpty {
            Label(dateLabel(task.startDate) + "开始", systemImage: "calendar")
        }
    }

    /// 构建清单上下文；参数：无；返回值：完整清单名，不重复任务标题；无副作用。
    @ViewBuilder
    private var contextLabel: some View {
        if !context.isEmpty { Label(context, systemImage: "folder").lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1) }
    }

    /// 转换相对日期；参数：day 为合法 API 日期；返回值：今天、明天或原日期；保留跨年日期，不用错误时区解析，无副作用。
    private func dateLabel(_ day: String) -> String {
        if day == Values.day(now) { return "今天" }
        if day == Values.day(Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now) ?? now) { return "明天" }
        return day
    }
}
