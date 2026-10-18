import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedTab = "finance"
    @Environment(\.scenePhase) private var scenePhase
    /// 解析旧版预览的管理页入口；参数：无；返回值：仅调试预览中的账号、健康或设置目的地，生产环境始终为 nil；不改变真实用户导航。
    private var initialPersonalDestination: PersonalDestination? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard store.isPreview, let index = arguments.firstIndex(of: "--tab"), arguments.count > index + 1 else { return nil }
        return PersonalDestination(rawValue: arguments[index + 1])
        #else
        return nil
        #endif
    }

    /// 构建主界面；参数：无；返回值：最多五个原生工作标签及聚合管理入口，预览参数只展示隔离样本，不改变会话及同步流程。
    var body: some View {
        Group {
            if store.isPreview && ProcessInfo.processInfo.arguments.contains("--wallet-ui") { AccountCardWalletPreview() }
            else if let error = store.localStorageError { ContentUnavailableView("无法打开本机账本", systemImage: "externaldrive.badge.exclamationmark", description: Text(error)) }
            else {
                TabView(selection: $selectedTab) {
                    if store.canUseCloud {
                        Tab("今日", systemImage: "sun.max", value: "today") { TabRootNavigation { TodayView() } }
                        Tab("任务", systemImage: "checklist", value: "tasks") { TabRootNavigation { TasksView() } }
                    }
                    Tab("财务", systemImage: "chart.pie", value: "finance") { TabRootNavigation { FinanceView() } }
                    if store.canUseCloud {
                        Tab("助手", systemImage: "sparkles", value: "chat") { TabRootNavigation { ChatView() } }
                    }
                    Tab("我的", systemImage: "person.crop.circle", value: "user") {
                        TabRootNavigation { PersonalHubView(initialDestination: initialPersonalDestination) }
                    }
                }
                // 由 iOS 27 系统 TabView 管理液态玻璃导航，滚动时收起以增加内容空间。
                .tabViewStyle(.sidebarAdaptable)
                .tabBarMinimizeBehavior(.onScrollDown)
                .id(store.sessionID)
            }
        }.tint(.teal)
            .onOpenURL { url in
                // 链接回调输入用户点击的 URL、返回无；仅接受截图记录入口，不接受外部交易字段或执行记账。
                guard url.scheme == "personalassistant", url.host == "screenshot-records" else { return }
                selectedTab = "finance"
                store.showScreenshotBookkeeping = true
            }
            .sheet(isPresented: Binding(get: { store.showScreenshotBookkeeping }, set: { store.showScreenshotBookkeeping = $0 })) {
                NavigationStack { ScreenshotBookkeepingView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { store.showScreenshotBookkeeping = false } } } }
            }
            .alert("数据需要刷新", isPresented: Binding(get: { store.syncWarning != nil }, set: { if !$0 { store.syncWarning = nil } })) {
                Button("知道了") { store.syncWarning = nil }
            } message: { Text(store.syncWarning ?? "") }
            .onChange(of: store.sessionID) { _, _ in selectedTab = "finance" }
            .task(id: scenePhase) {
                // 前台任务闭包无输入和返回；进入前台立即同步，随后每 30 秒检查，离开前台自动取消等待。
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await store.syncFinance()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .task {
                #if DEBUG
                if store.isPreview, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--tab"), ProcessInfo.processInfo.arguments.count > index + 1 {
                    let requested = ProcessInfo.processInfo.arguments[index + 1]
                    selectedTab = PersonalDestination(rawValue: requested) == nil ? requested : "user"
                }
                #endif
                await store.restore()
            }
    }
}
