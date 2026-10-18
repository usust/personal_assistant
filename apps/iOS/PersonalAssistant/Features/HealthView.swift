import SwiftUI

struct HealthView: View {
    @Environment(AppStore.self) private var store
    @State private var overview = HealthOverview(days: [], reports: [])
    @State private var busy = false
    @State private var hasLoaded = false
    @State private var readError: String?
    // 保留本会话 POST 已确认的报告，避免随后返回的旧快照覆盖它们。
    @State private var generatedReports: [HealthReport] = []
    @State private var displayedSession: [UUID] = []
    @State private var message: String?
    @State private var uploadConsent = false
    @State private var confirmingUpload = false
    @State private var progress = ""
    @State private var configError: String?
    @State private var analysisConsent = false
    @State private var configID = 0
    @State private var confirmingDelete = false
    /// 构建健康界面；参数：无；返回值：共享 grouped 底色、页边距和 headline 分组的健康列表；只展示真实最近记录，读取、上传、AI 外发与删除继续由原有明确授权流程触发。
    var body: some View {
        List {
            Section {
                NavigationLink {
                    NutritionView().id(store.cloudSessionID)
                } label: {
                    AppDestinationLabel(title: "饮食热量", symbol: "fork.knife", color: .teal)
                }
            } header: { AppSectionHeading(title: "饮食管理").textCase(nil) }
            if let readError {
                Section {
                    Text(readError).foregroundStyle(.orange)
                    // 重试回调；参数：无；返回值：无；仅重新读取服务器，不上传或创建报告。
                    Button("重新读取") { Task { await load() } }.disabled(busy)
                }
            }
            Section {
                if let day = latestDay {
                    LabeledContent("记录日期", value: day.date)
                    metrics(for: day)
                    Text(day.timezone).font(.caption).foregroundStyle(.secondary)
                } else if hasLoaded {
                    Text("暂无健康记录").foregroundStyle(.secondary)
                } else {
                    Text(readError != nil ? "健康记录读取失败" : (busy ? "正在读取服务器记录…" : "尚未读取健康记录"))
                        .foregroundStyle(.secondary)
                }
            } header: { AppSectionHeading(title: "最近记录").textCase(nil) }
            Section {
                LabeledContent("当前账号", value: store.profile?.account ?? "")
                LabeledContent("服务器") {
                    Text(store.api.baseURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(action: requestSync) { Label("同步到服务器", systemImage: "arrow.triangle.2.circlepath.cloud") }
                    .buttonStyle(.glassProminent).controlSize(.large).disabled(busy)
                // 上传行为与覆盖后果常驻可见，折叠项仅收纳详细读取范围，不代替原有授权确认。
                Text("点击后读取 iPhone 健康数据并上传；下拉刷新只读取服务器，不会上传手机数据。").font(.caption).foregroundStyle(.secondary)
                Text("未读取到的数据可能尚未记录或未获授权，不能视为零。权限可在系统健康设置中撤销。再次同步会替换相应日期；请固定使用一台 iPhone。").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("同步范围与隐私") {
                    Text("读取最近 30 天（含今天，截至同步时刻）的步数、活动能量、步行距离、静息心率及体重。数据仅用于你的健康管理，不写入手机健康数据库。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.callout) }
                if busy { ProgressView(progress.isEmpty ? "正在加载…" : progress) }
                if let last = overview.days.compactMap({ $0.updated_at }).max() {
                    LabeledContent("服务器最近接收", value: last).font(.caption)
                }
            } header: { AppSectionHeading(title: "同步与隐私").textCase(nil) }
            Section {
                if let configError { Text(configError).font(.caption).foregroundStyle(.orange) }
                Picker("AI 配置", selection: $configID) {
                    Text("请选择").tag(0)
                    ForEach(store.configs) { config in Text(config.name).tag(config.id) }
                }
                Toggle("同意发送日汇总至所选 AI 服务", isOn: $analysisConsent)
                // 生成回调；参数：无；返回值：无；沿用显式 AI 同意门槛，由 analyze 防止忙时重复写入。
                Button("生成健康报告") { Task { await analyze() } }.buttonStyle(.glassProminent).controlSize(.large).disabled(busy || !analysisConsent || configID == 0 || !overview.days.contains(where: { $0.hasData }))
                Text("仅供生活方式参考，不用于诊断或替代医生。").font(.caption).foregroundStyle(.secondary)
            } header: { AppSectionHeading(title: "AI 健康分析").textCase(nil) }
            Section {
                if hasLoaded && overview.reports.isEmpty { Text("暂无报告").foregroundStyle(.secondary) }
                ForEach(overview.reports) { report in
                    NavigationLink(report.created_at) { ScrollView { Text(report.content).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }.navigationTitle("健康报告").navigationBarTitleDisplayMode(.inline) }
                }
            } header: { AppSectionHeading(title: "历史报告").textCase(nil) }
            Section {
                if hasLoaded && overview.days.isEmpty { Text("暂无每日记录").foregroundStyle(.secondary) }
                // 完整保留所有日期，包括无数据日；使用日期稳定标识展开项，不依赖可能缺失的记录 ID。
                ForEach(overview.days, id: \.date) { day in
                    DisclosureGroup(day.date) {
                        metrics(for: day)
                        Text(day.timezone).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { AppSectionHeading(title: "每日记录").textCase(nil) }
            Section {
                Button("删除服务器健康数据、饮食记录及报告", role: .destructive) { confirmingDelete = true }.disabled(busy)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(AppVisualStyle.sectionSpacing)
        .contentMargins(.horizontal, AppVisualStyle.pageInset, for: .scrollContent)
        .scrollContentBackground(.hidden).background(AppVisualStyle.canvas)
        .navigationTitle("健康管理").navigationBarTitleDisplayMode(.inline)
        // 会话读取回调；参数：无；返回值：无；导航或云会话变化时清除旧账号状态，再执行只读加载。
        .task(id: [store.sessionID, store.cloudSessionID]) {
            let session = [store.sessionID, store.cloudSessionID]
            if displayedSession != session {
                displayedSession = session
                overview = HealthOverview(days: [], reports: [])
                generatedReports = []; hasLoaded = false; readError = nil
                message = nil; configError = nil; configID = 0
                busy = false; progress = ""
                uploadConsent = false; analysisConsent = false
                confirmingUpload = false; confirmingDelete = false
            }
            await load()
        }
        .confirmationDialog("读取并同步健康数据", isPresented: $confirmingUpload, titleVisibility: .visible) {
            Button("同意并开始同步") { uploadConsent = true; Task { await sync() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将最近 30 天的健康日汇总上传到当前账号的服务器：\(store.api.baseURL)。不会写入手机健康数据库，也不会自动发送给 AI。")
        }
        .refreshable { await load() }
        .confirmationDialog("删除全部已同步健康数据、饮食记录、热量目标和报告？手机数据不受影响。", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await clear() } }
        }
    }
    /// 选择最近有指标的日期；参数：无；返回值：按服务端 ISO 日期排序的最新有效日，无有效指标时为 nil；不改写记录顺序或发起请求。
    private var latestDay: HealthDay? {
        overview.days.filter { $0.hasData }.max { $0.date < $1.date }
    }

    /// 构建完整日指标；参数：day 为服务器返回的某日快照，允许指标缺失；返回值：五项真实指标行，缺失统一显示占位，不转换为零；无副作用。
    @ViewBuilder
    private func metrics(for day: HealthDay) -> some View {
        MetricRow(title: "步数", value: display(day.steps), symbol: "figure.walk", unit: "步")
        MetricRow(title: "活动", value: display(day.active_energy), symbol: "flame", unit: "千卡")
        MetricRow(title: "距离", value: display(day.distance), symbol: "point.topleft.down.to.point.bottomright.curvepath", unit: "米")
        MetricRow(title: "静息心率", value: display(day.resting_heart_rate), symbol: "heart", unit: "次/分")
        MetricRow(title: "体重", value: display(day.weight), symbol: "scalemass", unit: "kg")
    }

    /// 格式化可缺失指标；参数：value 为日统计；返回值：一位小数或缺失占位，无副作用。
    private func display(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    /// 打开首次上传说明或执行已同意的同步；参数：无；返回值：无；仅用户确认后才读取和上传。
    private func requestSync() {
        guard !busy else { return }
        if uploadConsent { Task { await sync() } } else { confirmingUpload = true }
    }
    /// 为健康接口失败提供可操作提示；参数：error 为网络或服务端错误；返回值：提示文本，无副作用。
    private func failure(_ error: Error) -> String {
        if let apiError = error as? APIError, apiError.status == 404 {
            return "当前服务器尚未提供健康管理接口，请更新并重启后端，或核对服务器地址。"
        }
        return error.localizedDescription
    }
    /// 判断响应能否落地；参数：generation 为发起时导航会话，cloudGeneration 为发起时云会话；返回值：会话均未变化且任务未取消时为 true，无副作用。
    private func isCurrent(_ generation: UUID, _ cloudGeneration: UUID) -> Bool {
        generation == store.sessionID && cloudGeneration == store.cloudSessionID && !Task.isCancelled
    }

    /// 合并服务器快照与本会话已生成报告；参数：result 为 GET 快照；返回值：无；按整数 ID 去重，并优先保留 POST 已确认内容。
    private func applyOverview(_ result: HealthOverview) {
        let generatedIDs = Set(generatedReports.map(\.id))
        overview = HealthOverview(days: result.days, reports: generatedReports + result.reports.filter { !generatedIDs.contains($0.id) })
        hasLoaded = true
        readError = nil
    }

    /// 只读刷新健康快照；参数：generation、cloudGeneration 为请求所属会话，failurePrefix 为读取失败提示前缀；返回值：无；失败保留数据，成功只清读取错误，不覆盖操作消息。
    private func readOverview(_ generation: UUID, _ cloudGeneration: UUID, failurePrefix: String = "读取健康记录失败：") async {
        guard isCurrent(generation, cloudGeneration) else { return }
        do {
            let result: HealthOverview = try await store.api.request("/health-management")
            guard isCurrent(generation, cloudGeneration) else { return }
            applyOverview(result)
        } catch {
            guard isCurrent(generation, cloudGeneration), !(error is CancellationError) else { return }
            readError = failurePrefix + failure(error)
        }
    }

    /// 独立加载健康信息及 AI 配置；参数：无；返回值：无；配置失败保留记录，读取重试不执行写入，过期或取消响应丢弃。
    private func load() async {
        guard !busy, !Task.isCancelled else { return }
        let generation = store.sessionID
        let cloudGeneration = store.cloudSessionID
        busy = true
        // 清理回调；参数：无；返回值：无；仅释放本会话的忙状态，取消也需释放。
        defer {
            if generation == store.sessionID && cloudGeneration == store.cloudSessionID { busy = false; progress = "" }
        }
        progress = "正在读取服务器记录…"
        await readOverview(generation, cloudGeneration)
        guard isCurrent(generation, cloudGeneration) else { return }
        do {
            try await store.loadConfigs()
            guard isCurrent(generation, cloudGeneration) else { return }
            configError = nil
            if configID == 0 { configID = store.configs.first?.id ?? 0 }
        } catch {
            if isCurrent(generation, cloudGeneration), !(error is CancellationError) {
                configError = "AI 配置加载失败，不影响健康同步：" + error.localizedDescription
            }
        }
    }
    /// 读取并上传健康快照，核对服务器回执；参数：无；返回值：无；需明确上传同意，全部为空不上传，过期或取消响应丢弃。
    private func sync() async {
        guard !busy, uploadConsent, !Task.isCancelled else { return }
        let generation = store.sessionID
        let cloudGeneration = store.cloudSessionID
        busy = true
        defer {
            if generation == store.sessionID && cloudGeneration == store.cloudSessionID { busy = false; progress = "" }
        }
        message = nil
        progress = "等待健康授权并读取手机数据…"
        do {
            // 读取进度回调；参数：completed 为已完成日期数；返回值：无；只为未取消的当前会话更新进度。
            let days = try await HealthReader().read { completed in
                if isCurrent(generation, cloudGeneration) { progress = "读取手机健康数据 \(completed)/30 天…" }
            }
            guard isCurrent(generation, cloudGeneration) else { return }
            let validDays = days.filter { $0.hasData }.count
            progress = "正在上传到服务器…"
            let synced = try await store.api.uploadHealth(days)
            guard isCurrent(generation, cloudGeneration) else { return }
            message = "服务器已确认接收 \(synced) 天汇总，其中 \(validDays) 天有指标数据（包含今天）。"
            progress = "正在核对服务器记录…"
            await readOverview(generation, cloudGeneration, failurePrefix: "上传已成功，但读取服务器记录失败，请下拉刷新。")
        } catch {
            if isCurrent(generation, cloudGeneration), !(error is CancellationError) { message = failure(error) }
        }
    }
    /// 生成并立即保留报告，再只读刷新；参数：无；返回值：无；必须明确同意外发，结束后重置同意，POST 结果不明时仅提示先刷新核对，不自动重发。
    private func analyze() async {
        guard !busy, analysisConsent, configID != 0, !Task.isCancelled else { return }
        let generation = store.sessionID
        let cloudGeneration = store.cloudSessionID
        busy = true
        defer {
            if generation == store.sessionID && cloudGeneration == store.cloudSessionID {
                busy = false; progress = ""; analysisConsent = false
            }
        }
        progress = "正在生成健康报告…"
        let report: HealthReport
        do {
            report = try await store.api.request("/health-management/reports", method: "POST", body: ["config_id": configID, "consent": true])
            guard isCurrent(generation, cloudGeneration) else { return }
        } catch {
            guard isCurrent(generation, cloudGeneration), !(error is CancellationError) else { return }
            message = "报告生成结果未确认，请先刷新核对，再决定是否重新生成。" + failure(error)
            readError = "请重新读取服务器记录，核对报告是否已生成。"
            return
        }
        // 先保留 POST 已确认报告，使后续 GET 失败或返回旧快照时仍可打开报告。
        generatedReports.removeAll { $0.id == report.id }
        generatedReports.insert(report, at: 0)
        overview = HealthOverview(days: overview.days, reports: [report] + overview.reports.filter { $0.id != report.id })
        message = "健康报告已生成。"
        progress = "正在刷新服务器记录…"
        await readOverview(generation, cloudGeneration, failurePrefix: "报告已生成，刷新失败：")
    }
    /// 清除本人云端健康信息；参数：无；返回值：无；调用前需 UI 确认，成功同步清空快照、已生成报告及读取错误，不改变 HealthKit 数据。
    private func clear() async {
        guard !busy, !Task.isCancelled else { return }
        let generation = store.sessionID
        let cloudGeneration = store.cloudSessionID
        busy = true
        defer {
            if generation == store.sessionID && cloudGeneration == store.cloudSessionID { busy = false; progress = "" }
        }
        do {
            try await store.api.mutate("/health-management", method: "DELETE")
            guard isCurrent(generation, cloudGeneration) else { return }
            generatedReports = []
            applyOverview(HealthOverview(days: [], reports: []))
            uploadConsent = false
            message = "服务器健康数据已删除。"
        } catch {
            if isCurrent(generation, cloudGeneration), !(error is CancellationError) { message = error.localizedDescription }
        }
    }
}
