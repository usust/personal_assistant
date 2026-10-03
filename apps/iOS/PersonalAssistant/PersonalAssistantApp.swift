import SwiftUI

@main
struct PersonalAssistantApp: App {
    @UIApplicationDelegateAdaptor(ScreenshotBackgroundAppDelegate.self) private var backgroundDelegate
    @State private var store = AppStore.shared
    @AppStorage("appearance") private var appearance = "system"
    /// 构建主应用窗口；参数：无；返回值：注入共享会话的场景；调试预览可创建虚构实时状态，不分析图片或写入交易。
    var body: some Scene {
        WindowGroup {
            ContentView().environment(store).environment(\.locale, Locale(identifier: "zh_Hans_CN")).preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .task {
                    // 场景预览回调无输入和返回；仅显式预览参数允许创建虚构状态，正常启动不产生实时活动。
                    #if DEBUG
                    let arguments = ProcessInfo.processInfo.arguments
                    if store.isPreview, let index = arguments.firstIndex(of: "--screenshot-activity-preview"), arguments.count > index + 1,
                       let phase = ScreenshotActivityAttributes.Phase(rawValue: arguments[index + 1]) {
                        do { try await ScreenshotActivityReporter.preview(phase) }
                        catch { store.sessionError = "实时活动预览失败：" + error.localizedDescription }
                    }
                    #endif
                }
        }
    }
}
