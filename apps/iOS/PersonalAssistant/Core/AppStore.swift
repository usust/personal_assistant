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

    /// 建立应用会话；参数：无；返回值：状态容器；读取服务器偏好、钥匙串和本机账本，恢复中断的截图任务，不发请求。
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PreviewProtocol.self]
            api = APIClient(baseURL: "https://preview.invalid/api", session: URLSession(configuration: configuration))
            isPreview = true
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
        // 认证失效回调无输入和返回；暂停云同步但保留当前本机账本及待上传操作。
        api.onUnauthorized = { [weak self] in
            guard let self else { return }
            self.api.token = nil; self.identityVerified = false
            TokenVault.delete(self.api.baseURL)
            self.finance?.syncError = "登录已过期"; self.sessionError = "登录已过期，请重新登录。"
        }
        #if os(iOS)
        if !isPreview { ScreenshotBackgroundBookkeeping.shared.restore(store: self) }
        #endif
    }
    /// 恢复身份但不阻塞本地财务；参数：无；返回值：无；断网保留已隔离的账号副本，只有认证校验通过才允许上传。
    func restore() async {
        restoring = true
        defer { restoring = false }
        guard api.token != nil || isPreview else { return }
        let generation = sessionID
        do {
            let user: Profile = try await api.request("/users/me")
            guard generation == sessionID else { return }
            if let finance, finance.activeKey != "guest", finance.cachedProfile?.id != user.id { try finance.useGuest() }
            profile = user; identityVerified = true
            await syncFinance()
        } catch { if generation == sessionID { sessionError = error.localizedDescription } }
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
    /// 登录并校验身份；参数：account/password 为用户输入，captcha 为挑战，answer 为答案；返回值：无；失败不保留半登录 token。
    func login(account: String, password: String, captcha: Captcha, answer: String) async throws {
        api.token = nil
        TokenVault.delete(api.baseURL)
        let response: LoginToken = try await api.request("/auth/login", method: "POST", body: ["account": account, "password": password, "captcha_id": captcha.captcha_id, "captcha_answer": answer])
        api.token = response.token
        do {
            let user: Profile = try await api.request("/users/me")
            try TokenVault.save(response.token, server: api.baseURL)
            try finance?.enable(server: api.baseURL, profile: user)
            profile = user; identityVerified = true
            scheduleSync()
            sessionError = nil
            sessionID = UUID()
        } catch { api.token = nil; identityVerified = false; TokenVault.delete(api.baseURL); throw error }
    }
    /// 退出登录；参数：无；返回值：无；原账号本机账本和队列保留，切到独立游客空间，清除凭证与非财务内存并使旧请求失效。
    func signOut() {
        do { try finance?.useGuest() } catch { localStorageError = error.localizedDescription; return }
        syncTask?.cancel(); syncTask = nil; identityVerified = false
        if !isPreview { CreditReminders.clear() }
        TokenVault.delete(api.baseURL)
        api.token = nil
        profile = nil
        syncWarning = nil
        tasks = []; lists = []; accounts = []; categories = []; configs = []; messages = []; actions = []
        overview = nil; chatConfigID = 0; chatSending = false; sessionID = UUID()
    }
    /// 刷新任务与清单；参数：无；返回值：无；整体成功后更新，失败保留旧数据；跨会话结果不提交。
    func loadTasks() async throws {
        let generation = sessionID
        async let taskResult: [AssistantTask] = api.request("/tasks")
        async let listResult: [TaskList] = api.request("/task-lists")
        let (newTasks, newLists) = try await (taskResult, listResult)
        guard generation == sessionID else { throw CancellationError() }
        tasks = newTasks.sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
        lists = newLists
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
        guard !isPreview, let finance, finance.enabled, api.token != nil, !finance.syncing else { return }
        let generation = sessionID
        do {
            if !identityVerified {
                let user: Profile = try await api.request("/users/me")
                guard generation == sessionID, user.id == finance.cachedProfile?.id, finance.space["server"] as? String == api.baseURL else { throw APIError(status: 0, message: "同步账号不匹配") }
                profile = user; identityVerified = true
            }
            try await finance.synchronize(api: api)
            guard generation == sessionID else { return }
            try await loadFinance()
        } catch { if generation == sessionID { finance.syncError = error.localizedDescription } }
    }

    /// 刷新 AI 配置；参数：无；返回值：无；首次使用服务端默认配置，失败抛错。
    func loadConfigs() async throws {
        let generation = sessionID
        let result: [AIConfig] = try await api.request("/setting/ai/provider_config")
        guard generation == sessionID else { throw CancellationError() }
        configs = result
        if !configs.contains(where: { $0.id == chatConfigID }) { chatConfigID = configs.first(where: { $0.is_selected })?.id ?? configs.first?.id ?? 0 }
    }
    enum Dataset { case tasks, finance, configs }
    /// 写入完成后刷新数据；参数：dataset 指定模块；返回值：无；失败明确告知保存已成功，防止用户误重复提交；不覆盖新会话。
    func refreshAfterMutation(_ dataset: Dataset) async {
        let generation = sessionID
        do {
            switch dataset {
            case .tasks: try await loadTasks()
            case .finance: try await loadFinance()
            case .configs: try await loadConfigs()
            }
        } catch {
            if generation == sessionID { syncWarning = "服务器已处理操作，但最新数据未能加载。请下拉刷新，避免重复提交。\n" + error.localizedDescription }
        }
    }

}
