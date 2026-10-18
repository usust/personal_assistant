import SwiftUI

/// 饮食日记使用服务端本人空间，照片识别与确认保存分离。
struct NutritionView: View {
    @Environment(AppStore.self) private var store
    @State private var date = Date()
    @State private var overview: NutritionOverview?
    @State private var loadedDate = ""
    @State private var stateSession: UUID?
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var error: String?
    @State private var adding = false
    @State private var settingGoal = false
    @State private var deleting: MealRecord?

    /// 读取当前日期；参数：无；返回值：设备当地自然日 ISO 字符串；无副作用。
    private var day: String { Values.day(date) }
    /// 只显示当前身份及日期的数据；参数：无；返回值：本人当天快照或 nil；无副作用。
    private var current: NutritionOverview? { stateSession == store.cloudSessionID && loadedDate == day ? overview : nil }
    /// 构建饮食热量页；参数：无；返回值：统一 grouped 底色、页边距和标题层级的饮食列表，突出真实摄入并保留缺失目标；日期加载、拍照、目标设置与删除沿用原有流程，只在用户提交后写入。
    var body: some View {
        List {
            Section {
                DatePicker("日期", selection: $date, in: ...Date(), displayedComponents: .date).disabled(busy)
                if let current {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已记录摄入").font(.subheadline).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            AmountText(value: current.calories.formatted(.number.precision(.fractionLength(0))), emphasis: .standard)
                            Text("千卡").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8).accessibilityElement(children: .combine)
                    // 点击回调无参数、返回值无；只打开既有手动目标表单，不推断或自动保存热量目标。
                    Button { settingGoal = true } label: {
                        LabeledContent("每日热量目标", value: current.daily_goal.map { "\($0.formatted(.number.precision(.fractionLength(0)))) 千卡" } ?? "设置")
                            .frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(.primary)
                    Text(NutritionMath.comparison(recorded: current.calories, goal: current.daily_goal))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } footer: {
                Text("照片热量仅为估算，油料与份量会影响结果；仅比较已记录餐食，不代表完整全天摄入。")
            }
            Section {
                Button { adding = true } label: { Label("拍照分析用餐", systemImage: "camera") }
                    .buttonStyle(.glassProminent).controlSize(.large).disabled(current == nil || busy)
            }
            if let error {
                Section {
                    if current != nil { Text("更新失败，以下为上次读取的数据").font(.caption).foregroundStyle(.orange) }
                    InlineError(message: error)
                    Button("重试") { Task { await load() } }.disabled(busy)
                }
            }
            if busy { Section { ProgressView("正在更新…") } }
            if let current {
                Section {
                    if current.meals.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
                    ForEach(current.meals) { meal in
                        DisclosureGroup {
                            ForEach(Array(meal.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).font(.body)
                                    Text("\(item.grams.formatted(.number.precision(.fractionLength(0...1)))) 克 · \(item.calories.formatted(.number.precision(.fractionLength(0)))) 千卡")
                                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
                            }
                            if !meal.note.isEmpty { Text(meal.note).font(.caption).foregroundStyle(.secondary) }
                            Button("删除记录", role: .destructive) { deleting = meal }.disabled(busy)
                        } label: {
                            MetricRow(title: NutritionMath.mealNames[meal.meal_type] ?? "用餐", value: "约 \(meal.calories.formatted(.number.precision(.fractionLength(0))))", symbol: "fork.knife", unit: "千卡")
                        }
                    }
                } header: { AppSectionHeading(title: "用餐记录").textCase(nil) }
            }
        }
        .listStyle(.insetGrouped).listSectionSpacing(AppVisualStyle.sectionSpacing)
        .contentMargins(.horizontal, AppVisualStyle.pageInset, for: .scrollContent)
        .scrollContentBackground(.hidden).background(AppVisualStyle.canvas)
        .navigationTitle("饮食热量").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(day)|\(store.cloudSessionID)") { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
            if let current {
                MealCaptureView(date: day, recorded: current.calories, goal: current.daily_goal)
                    .id(store.cloudSessionID)
            }
        }
        .sheet(isPresented: $settingGoal, onDismiss: { Task { await load() } }) {
            NutritionGoalEditor(current: current?.daily_goal).id(store.cloudSessionID)
        }
        .confirmationDialog("删除这条用餐记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let deleting {
                Button("删除", role: .destructive) { Task { await remove(deleting) } }
            }
        }
        .onDisappear { requestID = UUID(); busy = false }
    }
    /// 加载本人所选日期的餐食与目标；参数：无；返回值：无；同一天刷新失败保留旧值，日期/身份切换不显示旧值，过期响应丢弃。
    @MainActor private func load() async {
        let session = store.cloudSessionID, selectedDay = day, request = UUID()
        requestID = request; busy = true
        if stateSession != session || loadedDate != selectedDay { overview = nil; error = nil }
        stateSession = session; loadedDate = selectedDay
        defer { if requestID == request { busy = false } }
        do {
            let result: NutritionOverview = try await store.api.request("/health-management/nutrition", query: [URLQueryItem(name: "date", value: selectedDay)])
            guard session == store.cloudSessionID, selectedDay == day, requestID == request, !Task.isCancelled else { return }
            overview = result; error = nil
        } catch {
            guard session == store.cloudSessionID, selectedDay == day, requestID == request, !Task.isCancelled else { return }
            self.error = nutritionFailure(error)
        }
    }
    /// 删除已确认记录；参数：meal 为当前本人日期内的记录；返回值：无；失败保留记录，不自动重试删除，响应跨身份不提交。
    @MainActor private func remove(_ meal: MealRecord) async {
        guard !busy else { return }
        let session = store.cloudSessionID
        busy = true; deleting = nil
        do {
            try await store.api.mutate("/health-management/meals/\(meal.id)", method: "DELETE")
            guard session == store.cloudSessionID else { return }
            busy = false; await load()
        } catch {
            guard session == store.cloudSessionID else { return }
            self.error = nutritionFailure(error); busy = false
        }
    }
}

/// 手动目标不根据活动能量或单张照片自动推断，不默认套用通用热量值。
private struct NutritionGoalEditor: View {
    let current: Double?
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?
    /// 校验手动目标；参数：无；返回值：有效千卡或 nil；无副作用。
    private var goal: Double? { Double(value).flatMap { NutritionMath.validGoal($0) ? $0 : nil } }
    /// 构建目标编辑页；参数：无；返回值：手动输入和必要限制，不提供个体化医疗建议。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("每日热量（千卡）") {
                        TextField("未设置", text: $value).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } footer: { Text("支持 1000–6000 千卡。请按个人情况或专业建议设置；此范围不是饮食推荐。") }
                if let error { InlineError(message: error) }
            }
            .navigationTitle("每日热量目标").navigationBarTitleDisplayMode(.inline)
            .toolbar { SaveToolbar(busy: busy, valid: goal != nil) { Task { await save() } } }
            .disabled(busy).interactiveDismissDisabled(busy)
            .task { if let current { value = MealItemDraft.number(current) } }
        }
    }
    /// 保存本人目标；参数：无；返回值：无；成功关闭，由父页重读记录，失败保留输入，身份切换后丢弃响应。
    @MainActor private func save() async {
        guard !busy, let goal else { return }
        let session = store.cloudSessionID
        busy = true; defer { busy = false }
        do {
            try await store.api.mutate("/health-management/nutrition/goal", method: "PUT", body: ["daily_goal": goal])
            guard session == store.cloudSessionID else { return }; dismiss()
        } catch { if session == store.cloudSessionID { self.error = nutritionFailure(error) } }
    }
}

/// 转换饮食接口错误；参数：error 为网络或服务端错误；返回值：可操作说明，不包含图片或密钥；无副作用。
func nutritionFailure(_ error: Error) -> String {
    if let api = error as? APIError, api.status == 404 { return "当前服务器未提供饮食功能，请更新并重启后端。" }
    return error.localizedDescription
}
