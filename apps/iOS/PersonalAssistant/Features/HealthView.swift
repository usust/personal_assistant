import SwiftUI

struct HealthView: View {
    @Environment(AppStore.self) private var store
    @State private var overview = HealthOverview(days: [], reports: [])
    @State private var busy = false
    @State private var message: String?
    @State private var uploadConsent = false
    @State private var confirmingUpload = false
    @State private var progress = ""
    @State private var configError: String?
    @State private var analysisConsent = false
    @State private var configID = 0
    @State private var confirmingDelete = false
    var body: some View {
        List {
            Section("同步到服务器") {
                LabeledContent("当前账号", value: store.profile?.account ?? "")
                Text(store.api.baseURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("读取最近 30 天（含今天，截至同步时刻）的步数、活动能量、步行距离、静息心率及体重。数据仅用于你的健康管理，不写入手机健康数据库。")
                Button(action: requestSync) { Label("同步到服务器", systemImage: "arrow.triangle.2.circlepath.cloud") }
                    .buttonStyle(.borderedProminent).disabled(busy)
                Text("点击后读取 iPhone 健康数据并上传；下拉刷新只读取服务器，不会上传手机数据。").font(.caption).foregroundStyle(.secondary)
                Text("未读取到的数据可能尚未记录或未获授权，不能视为零。权限可在系统健康设置中撤销。再次同步会替换相应日期；请固定使用一台 iPhone。") .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.callout) }
                if busy { ProgressView(progress.isEmpty ? "正在加载…" : progress) }
                if let last = overview.days.compactMap({ $0.updated_at }).max() {
                    LabeledContent("服务器最近接收", value: last).font(.caption)
                }
            }
            Section("AI 健康分析") {
                if let configError { Text(configError).font(.caption).foregroundStyle(.orange) }
                Picker("AI 配置", selection: $configID) {
                    Text("请选择").tag(0)
                    ForEach(store.configs) { config in Text(config.name).tag(config.id) }
                }
                Toggle("同意发送日汇总至所选 AI 服务", isOn: $analysisConsent)
                Button("生成健康报告") { Task { await analyze() } }.disabled(busy || !analysisConsent || configID == 0 || !overview.days.contains(where: { $0.hasData }))
                Text("仅供生活方式参考，不用于诊断或替代医生。") .font(.caption).foregroundStyle(.secondary)
            }
            Section("历史报告") {
                if overview.reports.isEmpty { Text("暂无报告") }
                ForEach(overview.reports) { report in
                    NavigationLink(report.created_at) { ScrollView { Text(report.content).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }.navigationTitle("健康报告") }
                }
            }
            Section("每日记录") {
                if overview.days.isEmpty { Text("服务器暂无记录。请点击上方“同步到服务器”，完成健康读取授权。") }
                ForEach(overview.days) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.date).font(.headline)
                        Text("步数 \(display(day.steps)) · 活动 \(display(day.active_energy)) 千卡")
                        Text("距离 \(display(day.distance)) 米 · 静息心率 \(display(day.resting_heart_rate))")
                        Text("体重 \(display(day.weight)) kg · \(day.timezone)").font(.caption)
                    }
                }
            }
            Section {
                Button("删除服务器健康数据及报告", role: .destructive) { confirmingDelete = true }.disabled(busy)
            }
        }
        .navigationTitle("健康管理")
        .task { await load() }
        .confirmationDialog("读取并同步健康数据", isPresented: $confirmingUpload, titleVisibility: .visible) {
            Button("同意并开始同步") { uploadConsent = true; Task { await sync() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将最近 30 天的健康日汇总上传到当前账号的服务器：\(store.api.baseURL)。不会写入手机健康数据库，也不会自动发送给 AI。")
        }
        .refreshable { await load() }
        .confirmationDialog("删除全部已同步健康数据和报告？手机数据不受影响。", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await clear() } }
        }
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
    /// 独立加载健康信息及 AI 配置；参数：无；返回值：无；配置失败不再隐藏已同步记录，跨会话响应丢弃。
    private func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false; progress = "" }
        progress = "正在读取服务器记录…"
        let generation = store.sessionID
        do {
            let result: HealthOverview = try await store.api.request("/health-management")
            guard generation == store.sessionID else { return }
            overview = result
        } catch { if generation == store.sessionID { message = failure(error) } }
        guard generation == store.sessionID else { return }
        do {
            try await store.loadConfigs()
            guard generation == store.sessionID else { return }
            configError = nil
            if configID == 0 { configID = store.configs.first?.id ?? 0 }
        } catch { if generation == store.sessionID { configError = "AI 配置加载失败，不影响健康同步：" + error.localizedDescription } }
    }
    /// 读取并上传健康快照，核对服务器回执；参数：无；返回值：无；全部为空不上传，真正失败保留原因，跨会话结果不提交。
    private func sync() async {
        guard !busy, uploadConsent else { return }
        busy = true; defer { busy = false; progress = "" }
        let generation = store.sessionID
        message = nil
        progress = "等待健康授权并读取手机数据…"
        do {
            // 读取进度回调：completed 为已完成日期数；返回值无，只为当前会话更新进度。
            let days = try await HealthReader().read { completed in
                if generation == store.sessionID { progress = "读取手机健康数据 \(completed)/30 天…" }
            }
            guard generation == store.sessionID else { return }
            let validDays = days.filter { $0.hasData }.count
            progress = "正在上传到服务器…"
            let synced = try await store.api.uploadHealth(days)
            guard generation == store.sessionID else { return }
            message = "服务器已确认接收 \(synced) 天汇总，其中 \(validDays) 天有指标数据（包含今天）。"
            progress = "正在核对服务器记录…"
            do {
                let result: HealthOverview = try await store.api.request("/health-management")
                guard generation == store.sessionID else { return }
                overview = result
            } catch {
                if generation == store.sessionID { message = "上传已成功，但读取服务器记录失败，请下拉刷新。" + failure(error) }
            }
        } catch { if generation == store.sessionID { message = failure(error) } }
    }
    /// 生成并保存报告；参数：无；返回值：无；必须明确同意外发，本次结束后重置同意状态。
    private func analyze() async {
        guard !busy, analysisConsent, configID != 0 else { return }
        busy = true; defer { busy = false; analysisConsent = false }
        let generation = store.sessionID
        do {
            let _: HealthReport = try await store.api.request("/health-management/reports", method: "POST", body: ["config_id": configID, "consent": true])
            let result: HealthOverview = try await store.api.request("/health-management")
            guard generation == store.sessionID else { return }; overview = result; message = "健康报告已生成。"
        } catch { if generation == store.sessionID { message = error.localizedDescription } }
    }
    /// 清除本人云端健康信息；参数：无；返回值：无；调用前需 UI 确认，不改变 HealthKit 数据。
    private func clear() async {
        busy = true; defer { busy = false }
        let generation = store.sessionID
        do { try await store.api.mutate("/health-management", method: "DELETE"); guard generation == store.sessionID else { return }; overview = HealthOverview(days: [], reports: []); uploadConsent = false; message = "服务器健康数据已删除。" }
        catch { if generation == store.sessionID { message = error.localizedDescription } }
    }
}
