import SwiftUI
import PhotosUI

/// 本页使用独立配置摘要记录用户同意的模型版本，密钥不进入客户端。
private struct ScreenshotAIConfig: Decodable, Identifiable {
    let id: Int
    let name: String
    let provider_name: String
    let model_name: String
    let base_url: String
    let updated_at: String
}

struct ScreenshotBookkeepingView: View {
    var settingsOnly = false
    @Environment(AppStore.self) private var store
    @State private var book = ScreenshotBook()
    @State private var configs: [ScreenshotAIConfig] = []
    @State private var selectedConfig = 0
    @State private var error: String?
    @State private var loggingIn = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importingPhoto = false
    @State private var importMessage: String?

    /// 构建图片操作或独立设置页；参数：无；返回值：由 settingsOnly 分离的表单，设置包含模型及外发同意，操作页仅选图和记录。
    var body: some View {
        Form {
            if let error { Section { InlineError(message: error) } }
            Section {
                if !settingsOnly {
                    PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .compatible) {
                        Label("从相册选择图片", systemImage: "photo.on.rectangle")
                    }.disabled(importingPhoto || !book.settings.enabled || store.api.token == nil)
                    if importingPhoto { ProgressView("正在分析图片…") }
                    if let importMessage { Text(importMessage).foregroundStyle(.secondary) }
                }
                if !settingsOnly { NavigationLink("AI 设置") { ScreenshotBookkeepingView(settingsOnly: true) } }
                if settingsOnly {
                    if store.api.token == nil {
                        // 登录按钮无参数和返回值；使用既有认证流程，不在此保存任何截图凭证。
                        Button("登录以使用 AI") { loggingIn = true }
                    }
                    Picker("视觉 AI", selection: $selectedConfig) {
                        Text("请选择").tag(0)
                        ForEach(configs) { Text($0.name + " · " + $0.model_name).tag($0.id) }
                    }.disabled(book.settings.enabled)
                    if book.settings.enabled {
                        LabeledContent("图片记账", value: "已启用")
                        Text(book.settings.destination).font(.footnote).foregroundStyle(.secondary)
                        Button("停用图片记账", role: .destructive, action: disable)
                    } else if let config = configs.first(where: { $0.id == selectedConfig }) {
                        Text("所选图片将经 \(store.api.baseURL) 发送至 \(config.provider_name)（\(config.base_url)），使用 \(config.model_name)。图片可能含姓名、卡号和交易资料。失败或待确认图片暂存本机，完成或忽略后清理。")
                        .font(.footnote).foregroundStyle(.secondary)
                        Button("同意外发并启用", action: enable).disabled(store.api.token == nil)
                    }
                }
            }
            if !settingsOnly {
                Section("处理记录") {
                    if book.jobs.isEmpty { Text("暂无图片记录").foregroundStyle(.secondary) }
                    ForEach(book.jobs) { job in
                        NavigationLink {
                            ScreenshotJobView(jobID: job.id).id((store.finance?.activeKey ?? "") + job.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(job.extraction?.merchant.isEmpty == false ? job.extraction!.merchant : "支付图片"); Spacer(); Text(job.stateTitle).foregroundStyle(.secondary) }
                                if let value = job.extraction, !value.amount.isEmpty { Text("¥" + value.amount).font(.headline) }
                                if !job.message.isEmpty { Text(job.message).font(.caption).foregroundStyle(.secondary) }
                                Text(job.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { removeJob(job.id) }
                            .disabled(job.state == "processing" || store.screenshotRunning.contains(job.id))
                        }
                    }
                }
            }
        }.navigationTitle(settingsOnly ? "图片记账设置" : "图片记账")
            .task { await load() }
            // 选图回调输入旧新选择、返回无；取消选择不外发，单次任务防止重复导入。
            .onChange(of: selectedPhoto) { _, photo in
                guard let photo, !importingPhoto else { return }
                importingPhoto = true
                Task { await importPhoto(photo) }
            }
            // 观察回调输入旧新版本、返回无；只刷新持久状态，不重复外发图片。
            .onChange(of: store.finance?.revision) { _, _ in refresh() }
            .sheet(isPresented: $loggingIn, onDismiss: { Task { await load() } }) { LoginView() }
    }
    /// 导入用户选中的单张相册图片；参数：photo 为系统选择器授权的图片；返回值：无；先下载及校验再持久化并识别，取消/跨账号/同意变化不外发，网络失败保留任务。
    private func importPhoto(_ photo: PhotosPickerItem) async {
        let generation = store.sessionID
        let spaceKey = store.finance?.activeKey
        error = nil; importMessage = nil
        defer { importingPhoto = false; selectedPhoto = nil; refresh() }
        do {
            guard let finance = store.finance, !store.isPreview else { throw APIError(status: 0, message: "本机账本不可用") }
            let settings = try finance.screenshotBook().settings
            guard settings.enabled, !settings.consentID.isEmpty, store.api.token != nil else { throw APIError(status: 0, message: "请先选择视觉 AI 并同意图片外发") }
            guard let raw = try await photo.loadTransferable(type: Data.self) else { throw APIError(status: 0, message: "无法读取所选图片，请重试") }
            try Task.checkCancellation()
            guard generation == store.sessionID, finance.activeKey == spaceKey,
                  try finance.screenshotBook().settings == settings else { throw APIError(status: 0, message: "账号或图片设置已变化，请重新选择图片") }
            let image = try PaymentImageProcessor.normalizedImage(raw)
            let job = try finance.enqueueScreenshot(image)
            importMessage = try await store.recognizeScreenshot(job.id)
        } catch {
            if generation == store.sessionID, store.finance?.activeKey == spaceKey { self.error = error.localizedDescription }
        }
    }
    /// 加载本机配置与可用模型；参数：无；返回值：无；配置列表失败显示错误，不伪造模型或默认同意。
    private func load() async {
        refresh(); selectedConfig = book.settings.configID
        let generation = store.sessionID
        do {
            try await store.loadFinance()
            if store.api.token != nil {
                let values: [ScreenshotAIConfig] = try await store.api.request("/setting/ai/provider_config")
                guard generation == store.sessionID else { return }; configs = values
            }
        } catch { self.error = error.localizedDescription }
    }
    /// 刷新截图任务；参数：无；返回值：无；损坏数据展示错误并保留磁盘文件。
    private func refresh() {
        do { if let finance = store.finance { book = try finance.screenshotBook() } }
        catch { self.error = error.localizedDescription }
    }
    /// 用户主动同意当前视觉配置并启用；参数：无；返回值：无；同意标识更新使旧在途请求失效，磁盘失败显示错误。
    private func enable() {
        guard let config = configs.first(where: { $0.id == selectedConfig }), let finance = store.finance else { return }
        do {
            var next = try finance.screenshotBook()
            next.settings = ScreenshotSettings(enabled: true, configID: config.id, configVersion: config.updated_at, destination: config.provider_name + " · " + config.model_name + " · " + config.base_url, consentID: UUID().uuidString)
            try finance.saveScreenshotBook(next); error = nil; refresh()
        } catch { self.error = error.localizedDescription }
    }
    /// 停用并撤回外发同意；参数：无；返回值：无；后续重试及在途结果均不能自动入账，已有任务保留供检查或忽略。
    private func disable() {
        do {
            guard let finance = store.finance else { return }; var next = try finance.screenshotBook()
            next.settings.enabled = false; next.settings.consentID = ""; try finance.saveScreenshotBook(next); refresh()
        } catch { self.error = error.localizedDescription }
    }
    /// 删除选定分析记录；参数：id 为当前列表任务 ID；返回值：无；仅删除记录及图片，失败显示错误，不影响已入账交易。
    private func removeJob(_ id: String) {
        do {
            guard let finance = store.finance, !store.screenshotRunning.contains(id) else { return }
            try finance.deleteScreenshot(id); importMessage = nil; error = nil; refresh()
        } catch { self.error = error.localizedDescription }
    }

}

struct ScreenshotSetupView: View {
    /// 提供已签名快捷指令及系统绑定入口；参数：无；返回值：设置列表；添加确认和背面绑定由系统管理，不能静默修改。
    var body: some View {
        List {
            Section("1 · 创建快捷指令") {
                // 随应用分发已签名的完整工作流，截屏输出已绑定到图片参数，避免用户再次选图。
                if let shortcut = Bundle.main.url(forResource: "图片记账", withExtension: "shortcut") {
                    ShareLink(item: shortcut) {
                        Label("添加图片记账快捷指令", systemImage: "square.and.arrow.up")
                    }
                    Text("用“快捷指令”打开并添加。截屏和自动记账已配置。")
                }
                Link("打开快捷指令", destination: URL(string: "shortcuts://")!)
            }
            Section("2 · 绑定轻点背面") {
                Text("设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下 → 选择“图片记账”。")
            }
            Section("3 · 首次使用") {
                Text("选择支持图片输入的 AI 并启用图片记账。")
                Text("停留在支付页轻点两下，后台识别并自动入账。灵动岛显示状态，待确认记录可点开处理。")
                Text("目前仅自动处理人民币支出。需要联网识别；锁屏与系统中断时请解锁后重试。")
            }
        }.navigationTitle("截图记账")
    }
}

struct ScreenshotJobView: View {
    let jobID: String
    @Environment(AppStore.self) private var store
    @State private var job: ScreenshotJob?
    @State private var amount = ""
    @State private var merchant = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var accountID = 0
    @State private var categoryID = 0
    @State private var busy = false
    @State private var error: String?
    @State private var spaceKey = ""

    /// 展示持久任务及可核对字段；参数：无；返回值：待确认表单或完成回执，忽略会清理图片，处理中禁止并发操作。
    var body: some View {
        Form {
            if let error { InlineError(message: error) }
            if let job {
                Section {
                    LabeledContent("状态", value: job.stateTitle)
                    if !job.message.isEmpty { Text(job.message).foregroundStyle(.secondary) }
                }
                if let extraction = job.extraction {
                    Section("识别资料") {
                        LabeledContent("付款方式", value: extraction.paymentMethod.isEmpty ? "未识别" : extraction.paymentMethod)
                        if !extraction.orderId.isEmpty { LabeledContent("订单号", value: extraction.orderId).textSelection(.enabled) }
                        if !extraction.category.isEmpty { LabeledContent("分类建议", value: extraction.category) }
                        if let note = extraction.note, !note.isEmpty { LabeledContent("备注", value: note) }
                    }
                    if job.state == "review", extraction.supported {
                        Section("补全流水") {
                            TextField("实付金额", text: $amount).keyboardType(.decimalPad)
                            TextField("商户", text: $merchant)
                            TextField("备注", text: $note, axis: .vertical).lineLimit(2...6)
                            DatePicker("交易时间", selection: $date)
                            Picker("扣款账户", selection: $accountID) {
                                Text("请选择").tag(0)
                                ForEach(store.accounts.filter { $0.selectable != false && $0.currency == "CNY" }) { Text($0.name).tag($0.id) }
                            }
                            TransactionCategorySelector(title: "分类", type: "expense", selection: $categoryID)
                            Button("保存流水", action: confirm).disabled(accountID == 0)
                        }
                    }
                }
                if ["queued", "failed", "processing"].contains(job.state) {
                    Button("重试识别") { Task { await retry() } }.disabled(store.screenshotRunning.contains(jobID))
                }
                if !["posted", "ignored"].contains(job.state) {
                    Section {
                        if let base64 = job.image, let data = Data(base64Encoded: base64), let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("原始支付图片") }
                        Button("忽略并清理图片", role: .destructive, action: ignore).disabled(store.screenshotRunning.contains(jobID))
                    }
                }
            }
        }.navigationTitle("图片记录").disabled(busy)
            .task { spaceKey = store.finance?.activeKey ?? ""; reload() }
            .onChange(of: store.finance?.revision) { _, _ in if !busy { reload(preserveInput: true) } }
    }
    /// 生成核对草稿；参数：无；返回值：使用用户输入的任务副本或 nil，不持久化。
    private var editedJob: ScreenshotJob? {
        guard var copy = job, var extraction = copy.extraction else { return nil }
        extraction.amount = amount; extraction.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        extraction.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        extraction.date = Values.day(date); extraction.time = Values.time(date)
        copy.extraction = extraction; copy.accountID = accountID; copy.categoryID = categoryID; return copy
    }
    /// 读取最新持久状态；参数：preserveInput 表示保留正在编辑的核对输入；返回值：无；跨空间不读取同名任务。
    private func reload(preserveInput: Bool = false) {
        do {
            guard let finance = store.finance, finance.activeKey == spaceKey else { job = nil; return }
            job = try finance.screenshotBook().jobs.first { $0.id == jobID }
            if !preserveInput, let job {
                amount = job.extraction?.amount ?? ""; merchant = job.extraction?.merchant ?? ""
                note = job.extraction?.note ?? ""
                date = job.extraction.flatMap { ScreenshotExtraction.parsedDate($0.date, $0.time) } ?? job.createdAt
                accountID = finance.mappedID(job.accountID, table: "accounts"); categoryID = finance.mappedID(job.categoryID, table: "categories")
                if categoryID == 0, job.state == "review" { categoryID = try finance.prepareScreenshot(job).categoryID }
            }
        } catch { self.error = error.localizedDescription }
    }
    /// 手动确认核对后的交易；参数：无；返回值：无；同步原子入账，磁盘失败保留表单，成功后清理截图。
    private func confirm() {
        do {
            guard let finance = store.finance, finance.activeKey == spaceKey, let copy = editedJob else { return }
            _ = try finance.postScreenshot(copy, manual: true); error = nil; reload()
        } catch { self.error = error.localizedDescription }
    }
    /// 重试同一持久任务；参数：无；返回值：无；保持原 UUID，失败不生成第二笔，完成后重载真实状态。
    private func retry() async {
        guard !busy, store.finance?.activeKey == spaceKey else { return }; busy = true; defer { busy = false; reload() }
        do { _ = try await store.recognizeScreenshot(jobID); error = nil } catch { self.error = error.localizedDescription }
    }
    /// 放弃未完成任务；参数：无；返回值：无；删除任务图片但保留去重摘要及处理记录，已入账任务不受影响。
    private func ignore() {
        do {
            guard let finance = store.finance, finance.activeKey == spaceKey, var latest = try finance.screenshotBook().jobs.first(where: { $0.id == jobID }), !["posted", "ignored"].contains(latest.state), !store.screenshotRunning.contains(jobID) else { return }
            latest.state = "ignored"; latest.message = "已忽略"; latest.image = nil; try finance.updateScreenshot(latest); reload()
        } catch { self.error = error.localizedDescription }
    }
}
