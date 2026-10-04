import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    private var sending: Bool { store.chatSending }
    @State private var error: String?
    @State private var confirmingClear = false
    @State private var uncertain = false
    /// 构建助手页面；参数：无；返回值：原生对话界面；登录过渡禁止发出携带上下文的请求。
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if !store.configs.isEmpty {
                Picker("AI 模型", selection: $store.chatConfigID) { ForEach(store.configs) { Text($0.name + " · " + $0.model_name).tag($0.id) } }
                    .pickerStyle(.menu).padding(.horizontal).disabled(sending)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if store.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 18) {
                                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.teal).padding(24).glassEffect()
                                Text("把想法，说出来。").font(.largeTitle.bold())
                                Text("我可以帮你梳理任务、查询收支，也能根据你的指令执行操作。").foregroundStyle(.secondary)
                                if store.configs.isEmpty { NavigationLink { AISettingsView() } label: { Label("模型服务", systemImage: "slider.horizontal.3") } }
                                else {
                                    ForEach(["帮我梳理今天的任务", "分析一下我本月的支出", "列出我的账户余额"], id: \.self) { text in Button(text) { draft = text }.buttonStyle(.glass) }
                                }
                            }.padding(.vertical, 32)
                        }
                        ForEach(store.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(message.role == "user" ? "你" : "助手", systemImage: message.role == "user" ? "person.crop.circle" : "sparkles").font(.caption).foregroundStyle(.secondary)
                                Text(markdown(message.content)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(18).background(message.role == "user" ? Color.teal.opacity(0.09) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22)).id(message.id)
                        }
                        if sending { Label("正在思考并处理…", systemImage: "ellipsis.bubble").foregroundStyle(.secondary) }
                        if !store.actions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("本轮操作结果").font(.headline)
                                ForEach(Array(store.actions.enumerated()), id: \.offset) { _, action in
                                    Label(action.name + (action.success ? " · 已完成" : " · 失败") + (action.error.map { "：" + $0 } ?? ""), systemImage: action.success ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(action.success ? .teal : .orange).font(.subheadline)
                                }
                            }.padding(18)
                        }
                        if let error { InlineError(message: error) }
                        if uncertain { Text("本次请求结果未能确认，操作可能已经执行。请先检查任务或流水，再决定是否继续；不会自动重发。").font(.footnote).foregroundStyle(.secondary) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20).frame(maxWidth: 800).frame(maxWidth: .infinity)
                }.onChange(of: store.messages.count) { _, _ in proxy.scrollTo("bottom") }
            }
        }.background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("说说你的计划…", text: $draft, axis: .vertical).lineLimit(1...6).padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                    Button { Task { await send() } } label: { Image(systemName: sending ? "hourglass" : "arrow.up").font(.headline).frame(width: 44, height: 44) }
                        .buttonStyle(.glassProminent).accessibilityLabel("发送消息").disabled(!store.canUseCloud || sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.chatConfigID == 0)
                }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: 840).frame(maxWidth: .infinity)
            }.navigationTitle("助手").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("新对话", systemImage: "square.and.pencil") { confirmingClear = true }.disabled(sending || store.messages.isEmpty) }
            .confirmationDialog("开始新对话？当前设备上的对话将清空。", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("开始新对话", role: .destructive) { store.messages = []; store.actions = []; error = nil; uncertain = false }
            }
            // 云身份变更回调输入旧新标识、输出无；清除原账号局部草稿与错误，不留下可继续发送的旧内容。
            .onChange(of: store.cloudSessionID) { _, _ in draft = ""; error = nil; uncertain = false; confirmingClear = false }
            .task(id: store.cloudSessionID) {
                guard store.canUseCloud else { return }
                let generation = store.cloudSessionID
                do { try await store.loadConfigs(); guard generation == store.cloudSessionID else { return }; error = nil }
                catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
            }
    }
    /// 解析安全的原生 Markdown 文本；参数：text 为模型返回文本；返回值：AttributedString，解析失败展示原文；不执行 HTML 或脚本。
    private func markdown(_ text: String) -> AttributedString { (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text) }
    /// 提交一轮对话；参数：无；返回值：无；禁重复发送，显示真实动作结果；超时不重试，跨会话响应丢弃。
    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.canUseCloud && !sending && !text.isEmpty && store.chatConfigID > 0 else { return }
        let generation = store.cloudSessionID
        store.chatSending = true; error = nil; uncertain = false; store.actions = []; draft = ""
        store.messages.append(ChatMessage(role: "user", content: text))
        defer { if generation == store.cloudSessionID { store.chatSending = false } }
        do {
            // 历史转换回调输入当前云账号消息、输出角色和正文白名单；仅最近30条，不序列化UI标识或动作。
            // 历史仅传角色与正文，限制上下文长度；不序列化 UI 标识或操作描述。
            let result: ChatResult = try await store.api.request("/ai/chat", method: "POST", body: ["config_id": store.chatConfigID, "messages": store.messages.suffix(30).map { ["role": $0.role, "content": $0.content] }])
            guard generation == store.cloudSessionID else { return }
            if !result.reply.isEmpty { store.messages.append(ChatMessage(role: "assistant", content: result.reply)) }
            store.actions = result.actions; error = result.error
            if !result.actions.isEmpty {
                await store.refreshAfterMutation(.tasks)
                guard generation == store.cloudSessionID, store.canUseCloud else { return }
                await store.refreshAfterMutation(.finance)
            }
        } catch {
            guard generation == store.cloudSessionID else { return }
            self.error = error.localizedDescription; uncertain = true
        }
    }
}
