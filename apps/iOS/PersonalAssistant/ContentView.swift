import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedTab = "finance"
    @Environment(\.scenePhase) private var scenePhase
    /// 构建主界面；参数：无；返回值：正常应用导航，预览参数只展示隔离钱包样本。
    var body: some View {
        Group {
            if store.isPreview && ProcessInfo.processInfo.arguments.contains("--wallet-ui") { AccountCardWalletPreview() }
            else if let error = store.localStorageError { ContentUnavailableView("无法打开本机账本", systemImage: "externaldrive.badge.exclamationmark", description: Text(error)) }
            else {
                TabView(selection: $selectedTab) {
                    if store.profile != nil {
                        Tab("今日", systemImage: "sun.max", value: "today") { NavigationStack { TodayView() } }
                        Tab("任务", systemImage: "checklist", value: "tasks") { NavigationStack { TasksView() } }
                    }
                    Tab("财务", systemImage: "chart.pie", value: "finance") { NavigationStack { FinanceView() } }
                    if store.profile != nil {
                        Tab("健康", systemImage: "heart", value: "health") { NavigationStack { HealthView() } }
                        Tab("助手", systemImage: "sparkles", value: "chat") { NavigationStack { ChatView() } }
                    }
                    Tab("用户", systemImage: "person.crop.circle", value: "user") { NavigationStack { UserAccountView() } }
                    Tab("设置", systemImage: "gearshape", value: "settings") { NavigationStack { SettingsView() } }
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
                if store.isPreview, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--tab"), ProcessInfo.processInfo.arguments.count > index + 1 { selectedTab = ProcessInfo.processInfo.arguments[index + 1] }
                #endif
                await store.restore()
            }
    }
}
