import ActivityKit
import Foundation

/// 在应用进程控制实时活动；显示失败不影响记账，不主动打开页面。
@MainActor enum ScreenshotActivityReporter {
    /// 开始本次识别状态；参数：id 为持久化任务 ID；返回值：独立活动，系统未授权或资源不足为 nil；仅 LiveActivityIntent 后台调用或前台调用允许创建。
    static func start(id: String) -> Activity<ScreenshotActivityAttributes>? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        // 每次运行有独立标识，避免连续轻点时旧任务覆盖新任务状态；系统自行限制活动数量。
        return try? Activity.request(
            attributes: ScreenshotActivityAttributes(id: id),
            content: ActivityContent(state: .init(phase: .processing), staleDate: Date().addingTimeInterval(180)),
            pushType: nil
        )
    }

    /// 显示终态并结束活动；参数：activity 为本次活动或 nil，phase 为已完成状态；返回值：无；灵动岛保留结果十秒，锁屏最多保留一分钟；等待取消时仍结束活动。
    static func finish(_ activity: Activity<ScreenshotActivityAttributes>?, phase: ScreenshotActivityAttributes.Phase) async {
        guard let activity else { return }
        let content = ActivityContent(state: ScreenshotActivityAttributes.ContentState(phase: phase), staleDate: nil)
        await activity.update(content)
        // end 会立即移除灵动岛，after 只控制锁屏保留时间；先给结果十秒展示窗口，再在当前后台回调内结束。
        try? await Task.sleep(for: .seconds(10))
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(60)))
    }

    #if DEBUG
    /// 创建隔离的视觉验收状态；参数：phase 为虚构展示阶段；返回值：无；只在预览启动参数下调用，不识别图片或写入账本，系统创建失败抛错。
    static func preview(_ phase: ScreenshotActivityAttributes.Phase) async throws {
        // 结束旧预览避免遮挡当前验收状态；不结束实际识别活动。
        for activity in Activity<ScreenshotActivityAttributes>.activities where activity.attributes.id == "preview" {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        _ = try Activity.request(
            attributes: ScreenshotActivityAttributes(id: "preview"),
            content: ActivityContent(state: .init(phase: phase), staleDate: Date().addingTimeInterval(120)),
            pushType: nil
        )
    }
    #endif
}
