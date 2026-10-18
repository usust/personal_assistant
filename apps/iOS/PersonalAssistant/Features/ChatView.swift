import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var draft = ""
    private var sending: Bool { store.chatSending }
    @State private var error: String?
    @State private var confirmingClear = false
    @State private var uncertain = false
    /// 构建聊天界面；参数：无；返回值：grouped 底色上的实底建议、对话与系统导航和输入操作层；保留会话加载、清空与发送入口的原有副作用。
    var body: some View {
        @Bindable var store = store
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppVisualStyle.sectionSpacing) {
                    if store.messages.isEmpty { emptyState }
                    ForEach(store.messages) { message in
                        messageRow(message).id(message.id)
                    }
                    if sending { Label("正在思考并处理…", systemImage: "ellipsis.bubble").foregroundStyle(.secondary) }
                    if !store.actions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            AppSectionHeading(title: "本轮操作结果")
                            ForEach(Array(store.actions.enumerated()), id: \.offset) { _, action in
                                Label(action.name + (action.success ? " · 已完成" : " · 失败") + (action.error.map { "：" + $0 } ?? ""), systemImage: action.success ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(action.success ? .green : .orange).font(.subheadline)
                            }
                        }
                    }
                    if let error { InlineError(message: error) }
                    if uncertain { Text("本次请求结果未能确认，操作可能已经执行。请先检查任务或流水，再决定是否继续；不会自动重发。").font(.footnote).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(AppVisualStyle.pageInset)
                .frame(maxWidth: AppVisualStyle.maxContentWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // 消息数量回调输入旧值和新值、输出无；只滚动到末尾，不触发发送或重新加载。
            .onChange(of: store.messages.count) { _, _ in proxy.scrollTo("bottom") }
        }
        .background(AppVisualStyle.canvas)
        .safeAreaBar(edge: .bottom) {
            composer
                .padding(.horizontal, AppVisualStyle.pageInset)
                .padding(.vertical, 8)
                .frame(maxWidth: AppVisualStyle.maxContentWidth)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("助手").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if store.configs.isEmpty {
                    NavigationLink { AISettingsView() } label: {
                        Label("模型服务", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityLabel("模型服务")
                } else {
                    Menu {
                        Picker("AI 模型", selection: $store.chatConfigID) {
                            ForEach(store.configs) { Text($0.name + " · " + $0.model_name).tag($0.id) }
                        }
                    } label: {
                        Label("AI 模型", systemImage: "cpu")
                    }
                    .disabled(sending)
                    .accessibilityLabel("选择 AI 模型")
                    .accessibilityValue(store.configs.first(where: { $0.id == store.chatConfigID }).map { $0.name + "，" + $0.model_name } ?? "未选择")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新对话", systemImage: "square.and.pencil") { confirmingClear = true }
                    .disabled(sending || store.messages.isEmpty)
                    .accessibilityLabel("开始新对话")
            }
        }
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

    /// 构建空对话入口；参数：无；返回值：助手图标、既有标题、实底分组建议及缺少配置时的服务入口；建议只填写草稿，不发请求。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: AppVisualStyle.sectionSpacing) {
            VStack(alignment: .leading, spacing: 16) {
                SymbolTile(symbol: "sparkles", size: 52)
                Text("有什么要一起处理？").font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                suggestion("帮我梳理今天的任务", symbol: "checklist")
                Divider().padding(.leading, 52)
                suggestion("分析一下我本月的支出", symbol: "chart.bar")
                Divider().padding(.leading, 52)
                suggestion("列出我的账户余额", symbol: "creditcard")
            }.cardSurface()
            if store.configs.isEmpty {
                NavigationLink { AISettingsView() } label: {
                    Label("模型服务", systemImage: "slider.horizontal.3")
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(.vertical, AppVisualStyle.sectionSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 构建普通建议行；参数：text 为填入草稿的文字，symbol 为系统图标名；返回值：可换行且至少 52 点高的分组内容按钮；点击只更新草稿，无网络副作用。
    private func suggestion(_ text: String, symbol: String) -> some View {
        // 点击回调无参数、返回值无；只将现有建议复制到输入区，不自动发送。
        Button { draft = text } label: {
            HStack(spacing: AppVisualStyle.itemSpacing) {
                Image(systemName: symbol).font(.subheadline).foregroundStyle(.teal)
                    .frame(width: 24).accessibilityHidden(true)
                Text(text).font(.body).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 构建单条消息；参数：message 为保留原始角色与正文的消息；返回值：右对齐 secondary grouped 实底用户气泡或左对齐 canvas 助手阅读面；支持动态字号与文本选择，无业务副作用。
    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == "user" {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 8) {
                    Label("你", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                    Text(markdown(message.content))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .background(AppVisualStyle.surface, in: .rect(cornerRadius: AppVisualStyle.cardRadius))
                }
                .frame(maxWidth: 560, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("助手", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                Text(markdown(message.content))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 构建输入容器；参数：无；返回值：正常使用单层原生玻璃，减少透明度时使用不透明系统底色；输入与发送副作用由原有绑定和 send 方法负责。
    @ViewBuilder
    private var composer: some View {
        if reduceTransparency {
            inputControls.background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: AppVisualStyle.cardRadius))
        } else {
            inputControls.glassEffect(in: .rect(cornerRadius: AppVisualStyle.cardRadius))
        }
    }

    /// 构建输入与发送控件；参数：无；返回值：随动态字号增高的输入框及至少 44 点触控区的实底发送按钮，避免在玻璃容器内叠加玻璃；编辑只更新草稿，点击发送沿用原有异步流程。
    private var inputControls: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("说说你的计划…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.leading, 8)
                .padding(.vertical, 10)
                .accessibilityLabel("消息内容")
            Button { Task { await send() } } label: {
                Image(systemName: sending ? "hourglass" : "arrow.up")
                    .font(.headline)
                    .frame(minWidth: 24, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("发送消息")
            .disabled(!store.canUseCloud || sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.chatConfigID == 0)
        }
        .padding(8)
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
