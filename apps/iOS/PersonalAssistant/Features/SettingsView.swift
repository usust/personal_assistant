import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @State private var editingServer = false

    /// 构建一级设置页面；参数：无；返回值：按 AI、快捷指令、外观、连接及关于分块的设置表单，与用户账号操作分离。
    var body: some View {
        Form {
            Section("AI 设置") {
                if store.profile != nil { NavigationLink { AISettingsView() } label: { Label("模型服务", systemImage: "sparkles") } }
            }
            Section("快捷指令") {
                NavigationLink { ScreenshotSetupView() } label: { Label("截图记账", systemImage: "hand.tap") }
            }
            Section("外观") {
                Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
            }
            Section("连接") {
                // 点击回调无输入和返回；打开独立编辑表单，取消时不修改当前连接。
                Button { editingServer = true } label: {
                    HStack {
                        Text("服务器").foregroundStyle(.primary)
                        Spacer()
                        Text(store.api.baseURL).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Section("关于") {
                LabeledContent("Personal Assistant", value: "1.0")
            }
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editingServer) { ServerAddressEditor() }
    }
}

private struct ServerAddressEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var testing = false
    @State private var connectionResult: String?
    @State private var connectionTask: Task<Void, Never>?

    /// 构建服务器编辑表单；参数：无；返回值：地址输入、连接测试结果及取消和保存操作，测试不保存地址。
    var body: some View {
        NavigationStack {
            Form {
                Section("服务器地址") {
                    TextField("https://example.com/api", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("服务器地址")
                        .disabled(testing)
                }
                Section {
                    // 点击回调无输入和返回；针对当前草稿启动独立的匿名健康请求。
                    Button {
                        connectionTask = Task { await testConnection() }
                    } label: {
                        HStack {
                            Label(testing ? "测试中" : "测试连接", systemImage: "network")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }.disabled(testing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let connectionResult {
                        Text(connectionResult).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if store.api.token != nil {
                    Section { Text("更换服务器将退出当前登录，本机账本保留。").font(.footnote).foregroundStyle(.secondary) }
                }
                if let error { InlineError(message: error) }
            }.navigationTitle("服务器").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // 保存回调无输入和返回；校验失败保留输入，成功后关闭表单。
                    SaveToolbar(busy: testing, valid: !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { save() }
                }
                // 地址改变回调参数为旧、新地址；返回值无，清理不再对应当前输入的测试结果。
                .onChange(of: address) { _, _ in connectionResult = nil; error = nil }
                // 页面退出回调无输入和返回；取消尚未完成的测试，避免后台继续请求。
                .onDisappear { connectionTask?.cancel() }
                .onAppear {
                    // 出现回调无输入和返回；回填当前连接地址，不触发网络请求。
                    address = store.api.baseURL
                }
        }
    }

    /// 检查当前输入的服务器；参数：无；返回值：无，显示简短成功或失败结果，不保存地址或改变登录状态。
    @MainActor
    private func testConnection() async {
        testing = true
        connectionResult = nil
        error = nil
        defer { testing = false }
        do {
            try await APIClient.testConnection(address)
            try Task.checkCancellation()
            connectionResult = "连接成功"
        } catch {
            guard !Task.isCancelled else { return }
            connectionResult = "连接失败：" + error.localizedDescription
        }
    }

    /// 保存服务器地址；参数：无；返回值：无；复用地址校验、旧会话清理与偏好持久化，失败显示错误且不关闭表单。
    private func save() {
        do {
            try store.setServer(address)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct UserAccountView: View {
    @Environment(AppStore.self) private var store
    @State private var signingOut = false
    @State private var loggingIn = false
    /// 构建一级用户页面；参数：无；返回值：账号身份、财务与健康同步、管理员用户管理及退出登录入口。
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    SymbolTile(symbol: "person.crop.circle.fill")
                    VStack(alignment: .leading, spacing: 4) { Text(store.profile?.nickname ?? "本机账本").font(.title2.bold()); Text(store.profile?.account ?? "未登录").foregroundStyle(.secondary) }
                }.padding(.vertical, 12)
            }
            Section {
                // 同步按钮回调无输入和返回；未登录打开认证，已登录直接开启并执行，不展示合并选择。
                Button {
                    if store.api.token == nil { loggingIn = true }
                    else { Task { await store.enableFinanceSync() } }
                } label: {
                    HStack {
                        Label("同步", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if store.finance?.syncing == true { ProgressView() }
                        else { Text(syncStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(store.finance?.syncing == true)
                if let message = store.finance?.syncError { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if store.profile?.isAdmin == true {
                Section {
                    NavigationLink { UsersView() } label: { Label("用户管理", systemImage: "person.2") }
                }
            }
            if store.profile != nil {
                Section("健康同步") {
                    NavigationLink { HealthView() } label: { Label("健康管理 · 同步到服务器", systemImage: "heart.text.clipboard") }
                    Text("将 iPhone 健康日汇总上传至当前登录账号。下拉刷新只读取服务器数据。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.profile != nil { Section { Button("退出登录", role: .destructive) { signingOut = true } } }
        }.navigationTitle("用户").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $loggingIn) { LoginView() }
            .confirmationDialog("退出登录并清除本机对话？", isPresented: $signingOut, titleVisibility: .visible) { Button("退出登录", role: .destructive) { store.signOut() } }
    }
    /// 返回简短同步状态；参数：无；返回值：未开启、队列数量或最近成功状态，不把错误显示成同步完成。
    private var syncStatus: String {
        guard let finance = store.finance, finance.enabled else { return "未开启" }
        if !finance.queue.isEmpty { return "待同步 \(finance.queue.count) 笔" }
        if finance.syncError != nil { return "未完成" }
        if finance.lastSync != nil { return "已同步" }
        return "待同步"
    }

}

struct AISettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var creating = false
    @State private var editing: AIConfig?
    @State private var deleting: AIConfig?
    @State private var screenshotConfigID = 0
    @State private var consenting: AIConfig?
    @State private var busy = false
    @State private var error: String?
    /// 构建模型服务与用途配置；参数：无；返回值：左侧分组标题、左滑删除服务及图片记账模型下拉选择。
    var body: some View {
        List {
            if let error { InlineError(message: error); Button("重试") { Task { await reload() } } }
            Section {
                if store.configs.isEmpty { Text("暂无模型服务").foregroundStyle(.secondary) }
                ForEach(store.configs) { config in
                    // 服务选择回调无返回；有管理权限时打开编辑表单。
                    Button { editing = config } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(config.name).font(.headline)
                            Text(config.provider_name + " · " + config.model_name).font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }.foregroundStyle(.tint).disabled(!canManage(config) || busy)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManage(config) {
                                // 左滑删除只选定目标，确认后才向后端发送删除请求。
                                Button(role: .destructive) { deleting = config } label: {
                                    Label("删除", systemImage: "trash")
                                }.tint(.red).disabled(busy)
                            }
                        }
                }
            } header: {
                Text("模型服务").textCase(nil).padding(.leading, -16)
            }
            Section {
                // 新增按钮无输入及返回；保留等宽长条玻璃操作入口。
                Button { creating = true } label: {
                    Label("添加模型服务", systemImage: "plus")
                        .font(.body).frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(RoundedRectangle(cornerRadius: 28))
                }.buttonStyle(.plain).foregroundStyle(.tint).disabled(busy)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 28))
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section {
                Picker("图片记账", selection: Binding(get: { screenshotConfigID }, set: { selectScreenshotModel($0) })) {
                    Text("请选择").tag(0)
                    ForEach(store.configs) { config in
                        Text(config.name).tag(config.id)
                    }
                }.pickerStyle(.menu).disabled(busy)
            } header: {
                Text("模型配置").textCase(nil).padding(.leading, -16)
            }
        }.listStyle(.insetGrouped).listSectionSpacing(16)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .background(ModelServiceNavigationContainer())
            .task { await reload() }.refreshable { await reload() }
            .sheet(isPresented: $creating) { AIConfigEditor(config: nil) }
            .sheet(item: $editing) { AIConfigEditor(config: $0) }
            .alert("删除模型服务？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let config = deleting { Task { await remove(config) } } }
            } message: { Text("删除后无法使用此服务。") }
            .alert("启用图片记账？", isPresented: Binding(get: { consenting != nil }, set: { if !$0 { consenting = nil } })) {
                Button("取消", role: .cancel) { consenting = nil }
                Button("同意外发并启用") { if let config = consenting { enableScreenshotModel(config) } }
            } message: {
                if let config = consenting { Text("图片将经当前服务器发送至 \(config.provider_name)（\(config.base_url)），使用 \(config.model_name)。图片可能包含个人及交易资料。") }
            }
    }
    /// 保存图片记账用途选择；参数：id 为可用服务 ID 或 0；返回值：无，切换时撤回旧授权并请求新授权，磁盘失败保留原选择。
    private func selectScreenshotModel(_ id: Int) {
        guard let finance = store.finance else { return }
        do {
            var book = try finance.screenshotBook()
            guard id != book.settings.configID || !book.settings.enabled else { return }
            let config = store.configs.first { $0.id == id }
            guard id == 0 || config != nil else { return }
            book.settings = ScreenshotSettings(enabled: false, configID: id, configVersion: config?.updated_at ?? "", destination: config.map { $0.provider_name + " · " + $0.model_name + " · " + $0.base_url } ?? "", consentID: "")
            try finance.saveScreenshotBook(book)
            screenshotConfigID = id; error = nil; consenting = config
        } catch { self.error = error.localizedDescription }
    }
    /// 确认图片外发授权；参数：config 为当前用途选择的服务；返回值：无，保存新的同意 ID，失败保留未启用状态。
    private func enableScreenshotModel(_ config: AIConfig) {
        guard let finance = store.finance else { return }
        do {
            var book = try finance.screenshotBook()
            guard book.settings.configID == config.id, store.configs.contains(where: { $0.id == config.id && $0.updated_at == config.updated_at }) else { return }
            book.settings.enabled = true; book.settings.consentID = UUID().uuidString
            try finance.saveScreenshotBook(book); error = nil; consenting = nil
        } catch { self.error = error.localizedDescription }
    }
    /// 判断管理权限；参数：config 为服务摘要；返回值：本人服务或管理员系统服务是否可管理，后端仍独立校验。
    private func canManage(_ config: AIConfig) -> Bool {
        config.owner_type == "user" && config.owner_id == store.profile?.id || config.owner_type == "system" && store.profile?.isAdmin == true
    }
    /// 删除确认的后端服务；参数：config 为待删除服务；返回值：无，失败保留列表显示错误，成功刷新配置及聊天选择。
    private func remove(_ config: AIConfig) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let generation = store.sessionID
        do {
            try await store.api.mutate("/setting/ai/provider_config/\(config.id)", method: "DELETE")
            guard generation == store.sessionID else { return }
            store.configs.removeAll { $0.id == config.id }; deleting = nil; error = nil
            await store.refreshAfterMutation(.configs)
        } catch { if generation == store.sessionID { self.error = error.localizedDescription } }
    }
    /// 获取可用配置元数据；参数：无；返回值：无；不读取密钥，失败可重试。
    private func reload() async {
        do {
            try await store.loadConfigs()
            if let finance = store.finance {
                let settings = try finance.screenshotBook().settings
                screenshotConfigID = store.configs.contains { $0.id == settings.configID } ? settings.configID : 0
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// 本页保留 SwiftUI 导航栏，临时隐藏系统 More 的外层导航栏，避免两行按钮。
private struct ModelServiceNavigationContainer: UIViewControllerRepresentable {
    /// 创建导航适配控制器；参数：context 为 SwiftUI 生命周期上下文；返回值：不显示内容的控制器。
    func makeUIViewController(context: Context) -> NavigationController {
        NavigationController()
    }

    /// 更新适配控制器；参数：controller 为已创建实例，context 为生命周期上下文；返回值：无。
    func updateUIViewController(_ controller: NavigationController, context: Context) {
        controller.hideMoreNavigationBar()
    }

    /// 离开页面时恢复外层导航；参数：controller 为即将移除实例，coordinator 为默认协调器；返回值：无。
    static func dismantleUIViewController(_ controller: NavigationController, coordinator: ()) {
        controller.restoreMoreNavigationBar()
    }

    final class NavigationController: UIViewController {
        private weak var moreNavigation: UINavigationController?
        private var wasHidden = false

        /// 页面出现前适配导航栏；参数：animated 表示系统是否使用动画；返回值：无。
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            hideMoreNavigationBar()
        }

        /// 挂载后适配导航栏；参数：parent 为父控制器或 nil；返回值：无，未挂载时不修改导航。
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil { hideMoreNavigationBar() }
        }

        /// 隐藏本页所属 More 外层导航栏；参数：无；返回值：无，其他标签及宽屏导航不受影响。
        func hideMoreNavigationBar() {
            guard let more = tabBarController?.moreNavigationController else { return }
            // 必须确认当前页面在 More 层级内，避免隐藏其他一级菜单的导航栏。
            var ancestor: UIViewController? = parent
            while let current = ancestor {
                if current === more {
                    if moreNavigation == nil { moreNavigation = more; wasHidden = more.isNavigationBarHidden }
                    more.setNavigationBarHidden(true, animated: false)
                    return
                }
                ancestor = current.parent
            }
        }

        /// 恢复进入前的外层导航状态；参数：无；返回值：无，适配器移除时执行。
        func restoreMoreNavigationBar() {
            moreNavigation?.setNavigationBarHidden(wasHidden, animated: false)
            moreNavigation = nil
        }
    }
}


/// 模型服务字段：空值使用完整占位标签，有值时在输入上方显示缩小标签；密钥保持安全输入。
private struct ModelServiceTextField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var secure = false

    /// 构建浮动标签输入；参数：无；返回值：绑定 text 的输入视图，title 为字段名称，keyboard 指定键盘，secure 决定是否遮盖内容。
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 根据真实值浮动标签，编辑回填立即显示字段名；清空后还原占位，标签不截断长名称。
            if !text.isEmpty {
                Text(title).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            Group {
                if secure {
                    SecureField(title, text: $text, prompt: Text(title).foregroundStyle(.secondary))
                } else {
                    TextField(title, text: $text, prompt: Text(title).foregroundStyle(.secondary))
                }
            }.font(.body).keyboardType(keyboard)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel(title)
        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .animation(.easeInOut(duration: 0.16), value: text.isEmpty)
    }
}

struct AIConfigEditor: View {
    let config: AIConfig?
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [Provider] = []
    @State private var name = ""
    @State private var provider = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var initialized = false
    @State private var modelRequestID = UUID()
    @State private var showingModelResult = false
    @State private var modelResultTitle = ""
    @State private var modelResultMessage = ""
    @State private var key = ""
    @State private var shared = false
    @State private var busy = false
    @State private var error: String?
    /// 构建配置编辑器；参数：无；返回值：采用浮动标签的新建或编辑表单，已有密钥不读取。
    var body: some View {
        NavigationStack {
            Form {
                Section("模型连接") {
                    ModelServiceTextField(title: "服务名称", text: $name)
                    Picker("提供商", selection: $provider) { Text("请选择").tag(""); ForEach(providers) { Text($0.name).tag($0.id) } }
                        // 提供商变化回调输入旧新 ID，返回无；编辑原提供商保留自定义地址。
                        .onChange(of: provider) { _, value in baseURL = value == config?.provider_name ? config?.base_url ?? "" : providers.first { $0.id == value }?.base_url ?? "" }
                    ModelServiceTextField(title: "API 地址", text: $baseURL, keyboard: .URL)
                    ModelServiceTextField(title: config == nil ? "API Key" : "API Key（留空保留）", text: $key, secure: true)
                    // 标签独立放在左侧，模型菜单与刷新采用紧凑间距并共同靠右。
                    HStack(spacing: 2) {
                        Text("模型名称").fixedSize(horizontal: true, vertical: false)
                        // 菜单标签自定义单行布局，分配剩余宽度给模型名；超长名称缩放后截尾，菜单仍显示完整选项。
                        Menu {
                            Picker("模型名称", selection: $model) {
                                Text("请选择模型").tag("")
                                if !model.isEmpty && !models.contains(model) { Text(model).tag(model) }
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.isEmpty ? "请选择模型" : model)
                                    .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .medium)).fixedSize()
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                        }.disabled(loadingModels || models.isEmpty)
                            .accessibilityLabel("模型名称").accessibilityValue(model)
                        // 刷新回调无输入及返回；进度原位替换图标，独立点击区域不触发模型菜单。
                        Button { Task { await loadModels(showResult: true) } } label: {
                            ZStack {
                                if loadingModels { ProgressView().controlSize(.small) }
                                else { Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium)) }
                            }.frame(width: 28, height: 28)
                                .background(Color.accentColor.opacity(0.06), in: Circle())
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                            .disabled(loadingModels || baseURL.isEmpty || (key.isEmpty && config == nil))
                            .accessibilityLabel(loadingModels ? "正在加载模型" : "刷新模型列表")
                    }
                    if let modelError { Text(modelError).font(.caption).foregroundStyle(.red) }
                }
                Section { Toggle("共享配置", isOn: $shared) }
                if let error { InlineError(message: error) }
            }.disabled(busy).navigationTitle(config == nil ? "添加模型服务" : "编辑模型服务").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: !name.isEmpty && !provider.isEmpty && !baseURL.isEmpty && !model.isEmpty && (config != nil || !key.isEmpty)) { Task { await save() } } }
                .interactiveDismissDisabled(busy)
                .alert(modelResultTitle, isPresented: $showingModelResult) {
                    Button("好", role: .cancel) { }
                } message: { Text(modelResultMessage) }
                .task {
                    // 表单加载无输入及返回；先加载目录再回填，防止默认地址覆盖已保存地址。
                    do {
                        providers = try await store.api.request("/setting/ai/providers")
                        if let config { name = config.name; provider = config.provider_name; model = config.model_name; baseURL = config.base_url; shared = config.visibility == "shared" }
                        initialized = true
                    } catch { self.error = error.localizedDescription }
                }
                .task(id: provider + "\n" + baseURL + "\n" + key + "\n" + String(initialized)) {
                    // 连接变化回调无输入及返回；防抖、取消过期请求，不用旧结果覆盖新连接。
                    guard initialized else { return }
                    modelRequestID = UUID(); models = []; modelError = nil; loadingModels = false
                    if baseURL != config?.base_url || provider != config?.provider_name { model = "" }
                    guard !baseURL.isEmpty, !key.isEmpty || config != nil else { return }
                    do { try await Task.sleep(for: .milliseconds(600)); try Task.checkCancellation(); await loadModels() } catch { }
                }
        }
    }
    /// 从当前服务拉取模型目录；参数：showResult 指定手动刷新后弹出结果，自动加载默认不弹出；返回值：无，取消或连接变化时忽略旧响应，密钥由后端读取。
    private func loadModels(showResult: Bool = false) async {
        let address = baseURL; let secret = key; let vendor = provider; let generation = store.sessionID
        let requestID = UUID(); modelRequestID = requestID
        loadingModels = true; modelError = nil
        defer { if modelRequestID == requestID { loadingModels = false } }
        do {
            var body: [String: Any] = ["base_url": address, "api_key": secret, "provider_name": vendor]
            if let config { body["config_id"] = config.id }
            let result: [String] = try await store.api.request("/setting/ai/models", method: "POST", body: body)
            guard !Task.isCancelled, modelRequestID == requestID, generation == store.sessionID, address == baseURL, secret == key, vendor == provider else { return }
            models = result
            if showResult {
                modelResultTitle = "刷新成功"; modelResultMessage = "已获取 \(result.count) 个模型"; showingModelResult = true
            }
        } catch {
            if !Task.isCancelled, modelRequestID == requestID, generation == store.sessionID, address == baseURL, secret == key, vendor == provider {
                modelError = error.localizedDescription
                if showResult { modelResultTitle = "刷新失败"; modelResultMessage = error.localizedDescription; showingModelResult = true }
            }
        }
    }
    /// 创建或局部编辑后端 AI 配置；参数：无；返回值：无；成功清除密钥并刷新列表，失败保留输入。
    private func save() async {
        guard let user = store.profile else { return }
        busy = true; defer { busy = false }
        do {
            let fields: [String: Any] = ["visibility": shared ? "shared" : "private", "name": name, "provider_name": provider, "base_url": baseURL, "model_name": model]
            if let config {
                // 仅同步变更字段；空密钥保留服务端原值。
                var patch = Values.patch(original: ["visibility": config.visibility, "name": config.name, "provider_name": config.provider_name, "base_url": config.base_url, "model_name": config.model_name], edited: fields)
                if !key.isEmpty { patch["api_key"] = key }
                if !patch.isEmpty { try await store.api.mutate("/setting/ai/provider_config/\(config.id)", method: "PATCH", body: patch) }
            } else {
                var body = fields; body["owner_type"] = "user"; body["owner_id"] = user.id; body["api_key"] = key
                try await store.api.mutate("/setting/ai/provider_config/create", body: body)
            }
            key = ""; dismiss(); await store.refreshAfterMutation(.configs)
        } catch { self.error = error.localizedDescription }
    }
}
struct UsersView: View {
    @Environment(AppStore.self) private var store
    @State private var users: [Profile] = []
    @State private var edited: Profile?
    @State private var deleting: Profile?
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        List {
            if let error { InlineError(message: error); Button("重试") { Task { await reload() } } }
            ForEach(users) { user in
                Button { edited = user } label: { VStack(alignment: .leading, spacing: 5) { Text(user.nickname).foregroundStyle(.primary); Text(user.account + " · " + user.role).font(.caption).foregroundStyle(.secondary) } }
                    .swipeActions { if user.id != store.profile?.id { Button("删除", role: .destructive) { deleting = user } } }
            }
        }.navigationTitle("用户管理").navigationBarTitleDisplayMode(.inline).toolbar { Button("创建用户", systemImage: "plus") { creating = true } }
            .task { await reload() }.refreshable { await reload() }
            .sheet(item: $edited, onDismiss: { Task { await reload() } }) { UserEditor(user: $0) }
            .sheet(isPresented: $creating, onDismiss: { Task { await reload() } }) { UserEditor(user: nil) }
            .alert("删除用户？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let user = deleting { Task { await remove(user) } } }
            } message: { Text("此操作无法撤销，请确认目标账号。") }
    }
    /// 加载用户公开资料；参数：无；返回值：无；页面仅管理员可达，授权仍由后端执行。
    private func reload() async { do { users = try await store.api.request("/users"); error = nil } catch { self.error = error.localizedDescription } }
    /// 删除已确认用户；参数：user 为目标用户；返回值：无；服务端授权失败显示错误。
    private func remove(_ user: Profile) async {
        do { try await store.api.mutate("/users/\(user.id)", method: "DELETE"); users.removeAll { $0.id == user.id }; deleting = nil }
        catch { self.error = error.localizedDescription }
    }
}
struct UserEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let user: Profile?
    var publicRegistration = false
    @State private var account = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var role = "user"
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("账号（3–64 位字母、数字或下划线）", text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("昵称", text: $nickname)
                SecureField(user == nil ? "密码（8–72 字节）" : "新密码（留空不修改）", text: $password).textContentType(.newPassword)
                if user != nil { Picker("角色", selection: $role) { Text("普通用户").tag("user"); Text("管理员").tag("admin"); Text("系统管理员").tag("sys_admin") } }
                if let error { InlineError(message: error) }
                if publicRegistration { Text("账号将创建在：\(store.api.baseURL)").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle(user == nil ? "创建账号" : "编辑用户").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: !account.isEmpty && !nickname.isEmpty && (user != nil && password.isEmpty || (8...72).contains(password.utf8.count))) { Task { await save() } } }
                .task { account = user?.account ?? ""; nickname = user?.nickname ?? ""; role = user?.role ?? "user" }
                .interactiveDismissDisabled(busy)
                .alert("账号已创建", isPresented: $saved) { Button("返回登录") { dismiss() } } message: { Text("请使用新账号、密码和验证码登录。") }
        }
    }
    /// 创建或局部更新用户；参数：无；返回值：无；编辑空密码不发送，角色/资料仅在改变时提交，服务端进行权限校验。
    private func save() async {
        busy = true; defer { busy = false }
        do {
            let edited: [String: Any] = ["account": account.trimmingCharacters(in: .whitespaces).lowercased(), "nickname": nickname.trimmingCharacters(in: .whitespaces), "role": role]
            if let user {
                var patch = Values.patch(original: ["account": user.account, "nickname": user.nickname, "role": user.role], edited: edited)
                if !password.isEmpty { patch["password"] = password }
                if !patch.isEmpty { let result: Profile = try await store.api.request("/users/\(user.id)", method: "PATCH", body: patch); if result.id == store.profile?.id { store.profile = result } }
            } else { try await store.api.mutate("/users/register", body: ["account": account.trimmingCharacters(in: .whitespaces).lowercased(), "nickname": nickname.trimmingCharacters(in: .whitespaces), "password": password]) }
            password = ""
            if publicRegistration { saved = true } else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}
