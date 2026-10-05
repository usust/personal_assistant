import SwiftUI
import Observation
import Network

@MainActor @Observable
final class AppStore {
    static let shared = AppStore()
    var showScreenshotBookkeeping = false
    var screenshotRunning: Set<String> = []
    let api: APIClient
    var finance: FinanceLocalStore?
    var localStorageError: String?
    private var syncTask: Task<Void, Never>?
    private var identityVerified = false
    private var networkMonitor: NWPathMonitor?
    var isPreview = false
    var profile: Profile?
    var restoring = true
    var sessionError: String?
    var syncWarning: String?
    private var taskRevision = 0
    private var taskReadSequence = 0
    var taskWriteBusy = false
    var taskWriteBlocked = false
    var taskNotice: String?
    var tasks: [AssistantTask] = []
    var lists: [TaskList] = []
    var overview: FinanceOverview?
    var accounts: [FinancialAccount] = []
    var categories: [TransactionCategory] = []
    var configs: [AIConfig] = []
    var messages: [ChatMessage] = []
    var actions: [ChatAction] = []
    var chatConfigID = 0
    var chatSending = false
    var sessionID = UUID()
    var cloudSessionID = UUID()
    var isAuthenticating = false
    /// 判断云任务与助手入口权限；参数：无；返回值：已持有身份和凭证且不处于登录过渡时 true；隔离预览无需真实凭证。
    var canUseCloud: Bool { !isAuthenticating && profile != nil && (api.token != nil || isPreview) }

    /// 建立应用会话；参数：无；返回值：状态容器；读取服务器偏好、钥匙串和本机账本，恢复中断的截图任务，不发请求。
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview") || ProcessInfo.processInfo.arguments.contains("--task-ui-scenario") {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = ProcessInfo.processInfo.arguments.contains("--task-ui-scenario") ? [TaskScenarioProtocol.self] : [PreviewProtocol.self]
            api = APIClient(baseURL: "https://preview.invalid/api", session: URLSession(configuration: configuration))
            isPreview = true
            installUnauthorizedHandler()
            return
        }
        #endif
        api = APIClient(baseURL: UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:16101/api")
        api.token = TokenVault.read(api.baseURL)
        do {
            let ledger = try FinanceLocalStore()
            finance = ledger; api.localFinance = ledger
            #if os(iOS)
            try ledger.recoverScreenshots(excluding: ScreenshotBackgroundBookkeeping.pendingJobIDs())
            #else
            try ledger.recoverScreenshots()
            #endif
            if ledger.space["server"] as? String == api.baseURL { profile = ledger.cachedProfile }
            else if ledger.activeKey != "guest" { try ledger.useGuest() }
            // 用户允许重复图片记账；恢复当前已登录空间被旧版去重挡住的合格记录，不触及已完成任务。
            if api.token != nil, ledger.cachedProfile != nil { _ = try ledger.resumeRecognizedScreenshots() }
            // 写入回调无输入和返回；合并短时间内保存操作，避免每次按键触发上传。
            ledger.onMutation = { [weak self] in self?.scheduleSync() }
            let monitor = NWPathMonitor()
            // 网络回调输入可达性路径、返回无；切回主线程后合并恢复网络触发的同步。
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor [weak self] in self?.scheduleSync() }
            }
            monitor.start(queue: DispatchQueue(label: "finance.reachability")); networkMonitor = monitor
        } catch { localStorageError = error.localizedDescription; api.localFinanceError = error.localizedDescription }
        installUnauthorizedHandler()
        #if os(iOS)
        if !isPreview { ScreenshotBackgroundBookkeeping.shared.restore(store: self) }
        #endif
    }
    /// 安装认证失效回调；参数：无；返回值：无；真实和预览会话共用内存清理逻辑，保留财务离线空间，预览不触及钥匙串。
    private func installUnauthorizedHandler() {
        // 回调输入无、输出无；普通会话失效作废云请求和导航，认证中的401保留当前登录代数与表单，由login抛真实错误并释放锁。
        api.onUnauthorized = { [weak self] in
            guard let self else { return }
            let authenticating = self.isAuthenticating
            self.clearCloudTaskAndAIState(invalidateSession: !authenticating)
            if !authenticating { self.sessionID = UUID() }
            self.api.token = nil; self.identityVerified = false
            if !self.isPreview { TokenVault.delete(self.api.baseURL) }
            self.finance?.syncError = "登录已过期"; self.sessionError = "登录已过期，请重新登录。"
        }
    }
    /// 清理云任务与助手状态；参数：invalidateSession 默认true，false仅用于当前登录身份校验401，保留已于登录开始隔离的代数与认证锁；返回值：无；清业务缓存，导航、财务账本和缓存身份不变。
    private func clearCloudTaskAndAIState(invalidateSession: Bool = true) {
        if invalidateSession { cloudSessionID = UUID(); isAuthenticating = false }
        tasks = []; lists = []; resetTaskWrites()
        messages = []; actions = []; configs = []; chatConfigID = 0; chatSending = false; syncWarning = nil
    }
    /// 恢复身份但不阻塞本地财务；参数：无；返回值：无；断网保留已隔离的账号副本，只有认证校验通过才允许上传。
    func restore() async {
        let generation = cloudSessionID
        restoring = true
        defer { if generation == cloudSessionID { restoring = false } }
        guard !isAuthenticating, api.token != nil || isPreview else { return }
        do {
            let user: Profile = try await api.request("/users/me")
            guard generation == cloudSessionID else { return }
            if let finance, finance.activeKey != "guest", finance.cachedProfile?.id != user.id { try finance.useGuest() }
            profile = user; identityVerified = true
            await syncFinance()
        } catch { if generation == cloudSessionID { sessionError = error.localizedDescription } }
    }
    /// 切换服务器；参数：raw 为地址；返回值：无；校验后清理旧会话并保存地址，不迁移凭证。
    func setServer(_ raw: String) throws {
        let server = try APIClient.normalize(raw)
        guard server != api.baseURL else { return }
        signOut()
        guard finance?.activeKey == "guest" || finance == nil else { throw APIError(status: 0, message: "无法切换本机账本") }
        api.baseURL = server
        UserDefaults.standard.set(server, forKey: "serverURL")
    }
    /// 登录并校验身份；参数：account/password 为用户输入，captcha 为挑战，answer 为答案；返回值：无；开始清云任务和AI历史但保留登录表单，失败清半登录凭证并恢复登录状态；预览不访问钥匙串。
    func login(account: String, password: String, captcha: Captcha, answer: String) async throws {
        guard !isAuthenticating else { throw APIError(status: 409, message: "正在登录，请稍候。") }
        // 登录开始即清云历史并作废旧请求；导航 sessionID 不变，失败保留登录表单与草稿。
        clearCloudTaskAndAIState()
        identityVerified = false; syncTask?.cancel(); syncTask = nil
        isAuthenticating = true
        let generation = cloudSessionID
        defer { if generation == cloudSessionID { isAuthenticating = false } }
        api.token = nil
        if !isPreview { TokenVault.delete(api.baseURL) }
        do {
            let response: LoginToken = try await api.request("/auth/login", method: "POST", body: ["account": account, "password": password, "captcha_id": captcha.captcha_id, "captcha_answer": answer])
            guard generation == cloudSessionID else { throw CancellationError() }
            api.token = response.token
            let user: Profile = try await api.request("/users/me")
            guard generation == cloudSessionID else { throw CancellationError() }
            if !isPreview { try TokenVault.save(response.token, server: api.baseURL) }
            try finance?.enable(server: api.baseURL, profile: user)
            profile = user; identityVerified = true
            sessionError = nil
            sessionID = UUID()
            isAuthenticating = false
            scheduleSync()
        } catch {
            guard generation == cloudSessionID else { throw CancellationError() }
            api.token = nil; identityVerified = false
            if !isPreview { TokenVault.delete(api.baseURL) }
            throw error
        }
    }
    /// 退出登录；参数：无；返回值：无；原账号本机账本和队列保留，切到独立游客空间，清除凭证与非财务内存并使旧请求失效。
    func signOut() {
        do { try finance?.useGuest() } catch { localStorageError = error.localizedDescription; return }
        syncTask?.cancel(); syncTask = nil; identityVerified = false
        if !isPreview { CreditReminders.clear() }
        if !isPreview { TokenVault.delete(api.baseURL) }
        api.token = nil
        profile = nil
        clearCloudTaskAndAIState()
        accounts = []; categories = []
        overview = nil; sessionID = UUID()
    }
    /// 刷新任务与清单；参数：无；返回值：无；整体成功后更新，失败保留旧数据；会话、写入代数或读取序号变化及写入期间的响应均抛 CancellationError，不提交或解除保护。
    func loadTasks() async throws {
        // 写请求尚未结束时，读取快照不能确认最终结果；提前取消，不推进读取序号或发起网络请求。
        guard canUseCloud else { throw CancellationError() }
        guard !taskWriteBusy else { throw CancellationError() }
        let generation = cloudSessionID
        let revision = taskRevision
        taskReadSequence += 1
        let sequence = taskReadSequence
        async let taskResult: [AssistantTask] = api.request("/tasks")
        async let listResult: [TaskList] = api.request("/task-lists")
        let newTasks: [AssistantTask], newLists: [TaskList]
        do { (newTasks, newLists) = try await (taskResult, listResult) }
        catch {
            guard generation == cloudSessionID, revision == taskRevision, sequence == taskReadSequence, !taskWriteBusy else { throw CancellationError() }
            throw error
        }
        guard generation == cloudSessionID, revision == taskRevision, sequence == taskReadSequence, !taskWriteBusy else { throw CancellationError() }
        // 排序回调输入两个服务端节点，返回稳定先后关系；只在完整同会话快照成功后解除写保护。
        tasks = newTasks.sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
        lists = newLists
        taskWriteBlocked = false; taskNotice = nil
    }
    /// 重置任务写保护；参数：无；返回值：无；仅会话切换调用，使旧会话不影响新账号。
    private func resetTaskWrites() { taskRevision += 1; taskReadSequence += 1; taskWriteBusy = false; taskWriteBlocked = false; taskNotice = nil }
    /// 执行任务模块单次写入；类型 T 为响应值；参数：operation 为不自动重试的写请求；返回值：服务器确认结果；跨会话丢弃，结果不明锁定所有任务写入口，明确业务拒绝允许修正。
    func writeTask<T>(_ operation: () async throws -> T) async throws -> T {
        guard canUseCloud else { throw CancellationError() }
        guard !taskWriteBusy, !taskWriteBlocked else { throw APIError(status: 409, message: "请先刷新任务，确认上次操作结果。") }
        let generation = cloudSessionID
        taskRevision += 1
        taskWriteBusy = true
        defer { if generation == cloudSessionID { taskWriteBusy = false } }
        do {
            let result = try await operation()
            guard generation == cloudSessionID else { throw CancellationError() }
            taskWriteBlocked = true
            return result
        } catch {
            guard generation == cloudSessionID else { throw CancellationError() }
            // 拒绝分类回调输入HTTP业务错误、输出是否明确拒绝；5xx、解码和传输错误保守视为结果未知。
            let rejected = (error as? APIError).map { [400, 401, 403, 404, 409, 422].contains($0.status) } ?? false
            if !rejected {
                taskWriteBlocked = true
                taskNotice = "操作结果未确认，请刷新后检查任务，避免重复提交。"
            }
            throw error
        }
    }
    /// 合并已确认任务；参数：task 为服务器成功响应；返回值：无；原子迁移旧快照后代的确认清单归属并更新根，读失败保持一致；仅在同云会话写成功后调用。
    func upsertTask(_ task: AssistantTask) {
        tasks = Values.tasksAfterConfirmedWrite(task, snapshot: tasks)
    }
    /// 刷新任务模块；参数：confirmedWrite 表示本次调用紧跟服务器确认的成功写入，手动重试必须为 false；返回值：无；过期读不改提示，普通重试保留未确认状态。
    func refreshTaskWrite(confirmedWrite: Bool = true) async {
        let generation = cloudSessionID
        let revision = taskRevision
        do { try await loadTasks() }
        catch {
            guard !(error is CancellationError), generation == cloudSessionID, revision == taskRevision else { return }
            if confirmedWrite {
                taskWriteBlocked = true
                taskNotice = "已保存，最新数据加载失败。请刷新后继续。"
            } else if taskNotice == nil {
                taskNotice = "最新数据加载失败，请重试。"
            }
        }
    }
    /// 从本机读取财务摘要及表单选项并续排通知；参数：无；返回值：无；预览仍用模拟 API，本机失败抛错且不覆盖旧数据。
    func loadFinance() async throws {
        let generation = sessionID
        async let summary: FinanceOverview = api.request("/finance/overview")
        async let accountResult: [FinancialAccount] = api.request("/finance/accounts")
        async let categoryResult: [TransactionCategory] = api.request("/finance/categories")
        let (newOverview, newAccounts, newCategories) = try await (summary, accountResult, categoryResult)
        guard generation == sessionID else { throw CancellationError() }
        overview = newOverview; accounts = newAccounts; categories = newCategories
        if !isPreview {
            do { try await CreditReminders.sync(newAccounts) }
            catch { if generation == sessionID { syncWarning = "账户已加载，但本机还款提醒设置失败。" } }
        }
    }
    /// 开启并执行同步；参数：无；返回值：无；要求已经登录，首次绑定游客数据，失败只更新简短状态。
    func enableFinanceSync() async {
        guard let profile, api.token != nil, let finance else { return }
        do { try finance.enable(server: api.baseURL, profile: profile); await syncFinance() }
        catch { finance.syncError = error.localizedDescription }
    }
    /// 合并保存后的自动上传；参数：无；返回值：无；取消尚未执行的延迟任务，已开始同步的操作保留持久队列。
    func scheduleSync() {
        guard finance?.enabled == true, api.token != nil else { return }
        syncTask?.cancel()
        // 任务闭包无输入和返回；等待两秒后同步，取消则直接退出，不丢弃本地数据。
        syncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.syncFinance()
        }
    }
    /// 同步当前账号并刷新本地汇总；参数：无；返回值：无；先验证令牌身份，网络失败保留数据、下次自动重试。
    func syncFinance() async {
        guard !isPreview, !isAuthenticating, let finance, finance.enabled, api.token != nil, !finance.syncing else { return }
        let generation = sessionID
        let cloudGeneration = cloudSessionID
        do {
            if !identityVerified {
                let user: Profile = try await api.request("/users/me")
                guard generation == sessionID, cloudGeneration == cloudSessionID, !isAuthenticating, user.id == finance.cachedProfile?.id, finance.space["server"] as? String == api.baseURL else { throw APIError(status: 0, message: "同步账号不匹配") }
                profile = user; identityVerified = true
            }
            try await finance.synchronize(api: api)
            guard generation == sessionID, cloudGeneration == cloudSessionID, !isAuthenticating else { return }
            try await loadFinance()
        } catch { if generation == sessionID, cloudGeneration == cloudSessionID { finance.syncError = error.localizedDescription } }
    }

    /// 刷新 AI 配置；参数：无；返回值：无；要求云身份可用，跨云会话响应取消；首次使用服务端默认配置，读取失败抛错。
    func loadConfigs() async throws {
        guard canUseCloud else { throw CancellationError() }
        let generation = cloudSessionID
        let result: [AIConfig] = try await api.request("/setting/ai/provider_config")
        guard generation == cloudSessionID else { throw CancellationError() }
        configs = result
        if !configs.contains(where: { $0.id == chatConfigID }) { chatConfigID = configs.first(where: { $0.is_selected })?.id ?? configs.first?.id ?? 0 }
    }
    enum Dataset { case tasks, finance, configs }
    /// 写入完成后刷新数据；参数：dataset 指定模块；返回值：无；失败明确告知保存已成功，防止用户误重复提交；不覆盖新会话。
    func refreshAfterMutation(_ dataset: Dataset) async {
        let generation = sessionID
        let cloudGeneration = cloudSessionID
        do {
            switch dataset {
            case .tasks: try await loadTasks()
            case .finance: try await loadFinance()
            case .configs: try await loadConfigs()
            }
        } catch {
            if !(error is CancellationError), generation == sessionID, cloudGeneration == cloudSessionID { syncWarning = "服务器已处理操作，但最新数据未能加载。请下拉刷新，避免重复提交。\n" + error.localizedDescription }
        }
    }

}
