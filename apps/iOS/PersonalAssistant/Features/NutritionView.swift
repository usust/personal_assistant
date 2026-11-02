import SwiftUI

/// 饮食日记复用服务端本人空间，餐食缩略图仅保存在当前设备。
struct NutritionView: View {
    var observed: HealthProfile? = nil
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
    @State private var manualProfile = HealthProfile()

    /// 读取当前日期；参数：无；返回值：设备当地自然日 ISO 字符串；无副作用。
    private var day: String { Values.day(date) }
    /// 只显示当前身份及日期的数据；参数：无；返回值：本人当天快照或 nil；无副作用。
    private var current: NutritionOverview? { stateSession == store.cloudSessionID && loadedDate == day ? overview : nil }
    /// 获取本机资料作用域；参数：无；返回值：稳定设备空间，不随云登录改变。
    private var owner: String? { store.localDataScope }
    /// 获取本次身体资料估算；参数：无；返回值：以健康值补全手动资料的建议，不自动覆盖已保存目标。
    private var recommendation: CalorieRecommendation? {
        (observed.map { manualProfile.mergingHealth($0) } ?? manualProfile).recommendation
    }
    /// 构建饮食记录页；参数：无；返回值：日期、玻璃拍照入口、真实照片餐卡及动态结论，写入仍由用户确认触发。
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                dateAndGoal
                captureButton
                if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        if current != nil { Text("更新失败，保留上次读取的数据").font(.caption).foregroundStyle(.secondary) }
                        InlineError(message: error)
                        Button("重试") { Task { await load() } }.disabled(busy)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if busy { ProgressView("正在更新…") }
                if let current {
                    mealCards(current)
                    NutritionEnergyCompanion(state: NutritionEnergyState(recorded: current.calories, goal: current.daily_goal, hasMeals: !current.meals.isEmpty), title: Calendar.current.isDateInToday(date) ? "今日能量" : "当日能量")
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(AppVisualStyle.canvas)
        .navigationTitle("饮食记录").navigationBarTitleDisplayMode(.inline)
        // 读取回调无参数、返回无；由日期和账号代次触发，保持旧响应隔离。
        .task(id: "\(day)|\(store.cloudSessionID)") { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
            if let current {
                MealCaptureView(date: day, recorded: current.calories, goal: current.daily_goal).id(store.cloudSessionID)
            }
        }
        .sheet(isPresented: $settingGoal, onDismiss: { Task { await load() } }) {
            HealthProfileEditor(observed: observed, currentGoal: current?.daily_goal).id(store.cloudSessionID)
        }
        .confirmationDialog("删除这条用餐记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let deleting { Button("删除", role: .destructive) { Task { await remove(deleting) } } }
        }
        .onDisappear { requestID = UUID(); busy = false }
    }
    /// 构建日期与参考入口；参数：无；返回值：当前已采用目标和可生成建议的入口，不将未采用估算当作目标。
    private var dateAndGoal: some View {
        VStack(spacing: 16) {
            DatePicker("日期", selection: $date, in: ...Date(), displayedComponents: .date).disabled(busy)
            Divider()
            Button { settingGoal = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "figure.stand").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("每日能量参考").font(.subheadline)
                        if let goal = current?.daily_goal {
                            Text("\(goal.formatted(.number.precision(.fractionLength(0)))) 千卡")
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                        } else if let recommendation {
                            Text("建议约 \(((recommendation.calories / 10).rounded() * 10).formatted(.number.precision(.fractionLength(0)))) 千卡")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("根据身体资料计算").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(current?.daily_goal == nil ? "设置" : "调整").font(.subheadline)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(busy || current == nil)
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 24))
    }
    /// 构建拍照主操作；参数：无；返回值：明确相机图标与原生玻璃按钮，降低透明度时使用实底按钮。
    private var captureButton: some View {
        Group {
            if reduceTransparency {
                Button { adding = true } label: { captureLabel }.buttonStyle(.borderedProminent)
            } else {
                Button { adding = true } label: { captureLabel }.buttonStyle(.glass)
            }
        }
        .tint(.teal).controlSize(.large).disabled(current == nil || busy)
        .accessibilityIdentifier("nutrition.capture")
    }
    /// 构建拍照按钮内容；参数：无；返回值：高对比相机徽章、操作文字及加号，装饰图标对朗读隐藏。
    private var captureLabel: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 29, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 54, height: 54).background(.teal.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text("拍照记一餐").font(.headline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "plus").font(.title3.weight(.medium)).foregroundStyle(.primary).accessibilityHidden(true)
        }.padding(.vertical, 4).frame(maxWidth: .infinity)
    }
    /// 构建餐食卡片列表；参数：current 为已确认的当前日期快照；返回值：可展开照片卡片，缺图和空列表保留真实状态。
    private func mealCards(_ current: NutritionOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("用餐记录").font(.headline)
                Spacer()
                Text("\(current.meals.count) 餐").font(.subheadline).foregroundStyle(.secondary)
            }.padding(.horizontal, 4)
            if current.meals.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "fork.knife.circle").font(.system(size: 40, weight: .light)).foregroundStyle(.teal)
                    Text("记录一餐，留下今天的味道").font(.subheadline).foregroundStyle(.secondary)
                    Button("添加用餐") { adding = true }.buttonStyle(.bordered).disabled(busy)
                }.frame(maxWidth: .infinity).padding(28)
                    .background(.background, in: RoundedRectangle(cornerRadius: 24))
            }
            // 卡片构造回调输入餐食记录，输出展示卡片；删除回调只请求确认，不直接删除。
            ForEach(current.meals) { meal in
                MealPhotoCard(meal: meal, owner: owner, busy: busy) { deleting = meal }
            }
        }
    }
    /// 加载本人所选日期的餐食与目标；参数：无；返回值：无；同一天刷新失败保留旧值，日期/身份切换不显示旧值，过期响应丢弃。
    @MainActor private func load() async {
        let session = store.cloudSessionID, selectedDay = day, request = UUID()
        requestID = request; busy = true
        if stateSession != session || loadedDate != selectedDay { overview = nil; error = nil }
        if let owner { manualProfile = HealthProfileStore.load(owner: owner) ?? HealthProfile() }
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
    /// 删除已确认记录及本机缩略图；参数：meal 为当前本人日期内的记录；返回值：无；云端成功后清理照片，本地失败单独提示，不把已删除记录伪装成未删除。
    @MainActor private func remove(_ meal: MealRecord) async {
        guard !busy else { return }
        let session = store.cloudSessionID, scope = owner
        busy = true; deleting = nil
        do {
            try await store.api.mutate("/health-management/meals/\(meal.id)", method: "DELETE")
            guard session == store.cloudSessionID else { return }
            var photoFailure: String?
            if let scope {
                do { try MealThumbnailStore.remove(owner: scope, mealID: meal.id) }
                catch { photoFailure = "餐食已删除，本机照片清理失败。可在健康首页清理本机数据。" }
            }
            busy = false; await load()
            if let photoFailure { error = photoFailure }
        } catch {
            guard session == store.cloudSessionID else { return }
            self.error = nutritionFailure(error); busy = false
        }
    }
}

/// 餐食内容以缩略图、餐次和估算为主，展开后显示食物与备注。
private struct MealPhotoCard: View {
    let meal: MealRecord
    let owner: String?
    let busy: Bool
    /// 删除回调；参数：无；返回值：无；交由父页执行确认。
    let onDelete: () -> Void
    @State private var thumbnail: UIImage?

    /// 构建餐食卡片；参数：无；返回值：有图展示照片，无图展示餐具；照片加载按账号及记录键隔离。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
                    .frame(height: 168).frame(maxWidth: .infinity).clipped()
                    .accessibilityLabel("\(NutritionMath.mealNames[meal.meal_type] ?? "用餐")照片")
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(meal.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                            Text("\(item.grams.formatted(.number.precision(.fractionLength(0...1)))) 克 · \(item.calories.formatted(.number.precision(.fractionLength(0)))) 千卡")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                    if !meal.note.isEmpty { Text(meal.note).font(.caption).foregroundStyle(.secondary) }
                    Button("删除记录", role: .destructive, action: onDelete).disabled(busy)
                }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        if thumbnail == nil { Image(systemName: "fork.knife").foregroundStyle(.teal).accessibilityHidden(true) }
                        Text(NutritionMath.mealNames[meal.meal_type] ?? "用餐").font(.headline)
                        Spacer(minLength: 0)
                        Text("约 \(meal.calories.formatted(.number.precision(.fractionLength(0)))) 千卡")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    Text(meal.items.map(\.name).joined(separator: "、"))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }.foregroundStyle(.primary).padding(.vertical, 3)
            }.padding(18).tint(.secondary)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        // 图片查询回调无参数、无返回值；仅账号与餐食键改变时读取受限小图，避免 body 重绘重复磁盘 IO。
        .task(id: "\(owner ?? "")|\(meal.id)") {
            thumbnail = owner.flatMap { MealThumbnailStore.image(owner: $0, mealID: meal.id) }
        }
    }
}

/// 转换饮食接口错误；参数：error 为网络或服务端错误；返回值：可操作说明，不包含图片或密钥；无副作用。
func nutritionFailure(_ error: Error) -> String {
    if let api = error as? APIError, api.status == 404 { return "当前服务器未提供饮食功能，请更新并重启后端。" }
    return error.localizedDescription
}
