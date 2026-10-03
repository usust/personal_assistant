import AppIntents
import UniformTypeIdentifiers

/// 系统截屏后在应用进程后台处理；实时活动显示状态，不主动切换用户当前页面。
struct BookkeepScreenshotIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "识别截图并记账"
    static var description = IntentDescription("识别支付截图并记账。请先在个人助理中启用图片记账。")
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "支付截图", supportedContentTypes: [.image]) var screenshot: IntentFile

    /// 持久化截图并交给系统后台上传；参数：无，图片来自 screenshot；返回值：已开始处理，不代表已入账；提交失败抛错，处理结果由实时活动和记录显示，不等待 AI 或切前台。
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = AppStore.shared
        guard let finance = store.finance, !store.isPreview else { throw APIError(status: 0, message: "本机账本不可用") }
        let image = try PaymentImageProcessor.normalizedImage(screenshot.data)
        let job = try finance.enqueueScreenshot(image)
        try ScreenshotBackgroundBookkeeping.shared.submit(job, store: store)
        return .result(value: "已开始识别，入账结果见图片记账记录")
    }

}

extension AppStore {
    /// 识别一个已持久化任务；参数：id 为当前空间任务 ID；返回值：简短状态；外发前核对同意和身份，异步期间切换账号或关闭功能则不入账，失败保留图片供手动重试。
    func recognizeScreenshot(_ id: String) async throws -> String {
        guard let finance, !isPreview else { throw APIError(status: 0, message: "本机账本不可用") }
        guard !screenshotRunning.contains(id) else { return "正在识别，请稍候" }
        let generation = sessionID
        screenshotRunning.insert(id); defer { screenshotRunning.remove(id) }
        // 会话检查闭包无参数，返回是否仍属于本次登录会话，防止切换后接收旧响应。
        return try await finance.recognizeScreenshot(id, api: api, isCurrent: { self.sessionID == generation })
    }
}
