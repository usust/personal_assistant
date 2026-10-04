import ActivityKit
import CryptoKit
import Foundation
import UIKit

/// 后台上传的最小身份快照；不保存令牌，恢复进程后仍须核对账号、服务器和同意版本。
nonisolated private struct ScreenshotUploadContext: Codable {
    var id: String
    var spaceKey: String
    var server: String
    var tokenHash: String
    var settings: ScreenshotSettings
}

/// 系统上传结果先落盘，再修改账本，避免进程重启丢失已返回的分析结果。
nonisolated private struct ScreenshotUploadResult: Codable {
    var status: Int
    var data: Data
    var error: String?
}

/// 受设备保护的任务文件；只有图片请求正文及不含凭据的上下文，终态提交后清除。
nonisolated private enum ScreenshotUploadFiles {
    /// 定位任务文件；参数：id 为 UUID 任务编号，suffix 为受控扩展名；返回值：本机文件 URL；目录创建失败抛错，不接受外部路径。
    static func url(_ id: String, suffix: String) throws -> URL {
        guard UUID(uuidString: id) != nil, ["context", "payload", "result"].contains(suffix) else { throw APIError(status: 0, message: "截图任务编号无效") }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ScreenshotUploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(id + "." + suffix)
    }

    /// 原子保存受保护文件；参数：data 为任务字节，id 为任务编号，suffix 为受控扩展名；返回值：无；失败抛错，不把凭据写入文件。
    static func write(_ data: Data, id: String, suffix: String) throws {
        try data.write(to: url(id, suffix: suffix), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 读取所有可恢复上下文；参数：无；返回值：有效任务列表；损坏的上下文不用于外发或入账。
    static func contexts() -> [ScreenshotUploadContext] {
        guard let directory = try? url(UUID().uuidString, suffix: "context").deletingLastPathComponent(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        // 文件解析回调输入目录文件、返回可信结构或 nil；只读取本应用创建的上下文。
        return files.filter { $0.pathExtension == "context" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(ScreenshotUploadContext.self, from: data)
        }
    }

    /// 清除已提交任务的临时文件；参数：id 为任务编号；返回值：无；删除失败保留文件，终态账本确保重放不会重复入账。
    static func remove(_ id: String) {
        for suffix in ["context", "payload", "result"] {
            if let file = try? url(id, suffix: suffix) { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// 系统后台 URLSession 委托；响应有大小上限，回调先落盘再交给主线程处理，不直接访问账本。
nonisolated private final class ScreenshotUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var oversized: Set<Int> = []

    /// 收集响应片段；参数：session/dataTask 为系统请求，data 为新片段；返回值：无；超过 1 MB 取消请求并保留明确错误。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var buffer = buffers[dataTask.taskIdentifier] ?? Data()
        let tooLarge = buffer.count + data.count > 1024 * 1024
        if tooLarge { oversized.insert(dataTask.taskIdentifier) }
        else { buffer.append(data); buffers[dataTask.taskIdentifier] = buffer }
        lock.unlock()
        if tooLarge { dataTask.cancel() }
    }

    /// 持久化上传终态；参数：session/task 为请求，error 为网络错误或 nil；返回值：无；不丢弃模型结果，落盘失败将原任务标记失败。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        lock.lock()
        let data = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        let tooLarge = oversized.remove(task.taskIdentifier) != nil
        lock.unlock()
        let result = ScreenshotUploadResult(status: (task.response as? HTTPURLResponse)?.statusCode ?? 0, data: data,
                                            error: tooLarge ? "识别响应过大，请重试" : error?.localizedDescription)
        do {
            try ScreenshotUploadFiles.write(JSONEncoder().encode(result), id: id, suffix: "result")
            // 主线程回调无输入和返回；读取已落盘结果，串行修改唯一账本实例。
            Task { @MainActor in await ScreenshotBackgroundBookkeeping.shared.consumeResults() }
        } catch {
            let message = error.localizedDescription
            // 主线程失败回调无输入和返回；将落盘失败关联到持久化截图，供用户重试。
            Task { @MainActor in await ScreenshotBackgroundBookkeeping.shared.fail(id, message: message) }
        }
    }

    /// 拒绝凭据重定向；参数：session/task 为请求，response 为跳转响应，request 为新地址，completionHandler 为系统回调；返回值：无，回调 nil 禁止跳转。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// 完成系统事件批次；参数：session 为后台会话；返回值：无；所有已保存结果处理完后才归还系统完成回调。
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // 主线程回调无输入和返回；先完成账本提交，避免系统提前挂起应用。
        Task { @MainActor in await ScreenshotBackgroundBookkeeping.shared.finishEvents() }
    }
}

/// 截图交付后由系统网络进程上传；快捷指令无需等待，应用挂起后仍可收到结果。
@MainActor final class ScreenshotBackgroundBookkeeping {
    static let shared = ScreenshotBackgroundBookkeeping()
    static let sessionIdentifier = "personalassistant.screenshot.upload"
    private let delegate = ScreenshotUploadDelegate()
    private var session: URLSession?
    private weak var store: AppStore?
    private var completion: (() -> Void)?
    private var consuming = false

    /// 获取恢复时应保留的处理中任务；参数：无；返回值：持久化后台任务 ID；不启动网络。
    static func pendingJobIDs() -> Set<String> { Set(ScreenshotUploadFiles.contexts().map { $0.id }) }

    /// 恢复后台会话；参数：store 为唯一应用状态容器；返回值：无；重新接管系统任务，不重新上传。
    func restore(store: AppStore) {
        self.store = store
        guard session == nil else { return }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForRequest = 110
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let pending = ScreenshotUploadFiles.contexts()
        // 恢复回调无输入和返回；优先处理进程中断前已经收到并落盘的结果。
        Task { await consumeResults(); await reconcile(pending) }
    }

    /// 核对系统是否仍持有恢复任务；参数：contexts 为恢复时已有上下文；返回值：无；强退取消或提交中断后标记失败并要求重新选图，不能留下永久“识别中”。
    private func reconcile(_ contexts: [ScreenshotUploadContext]) async {
        guard let session else { return }
        let tasks = await session.allTasks
        let ids = Set(tasks.compactMap { $0.taskDescription })
        for context in contexts {
            guard let file = try? ScreenshotUploadFiles.url(context.id, suffix: "context"), FileManager.default.fileExists(atPath: file.path) else { continue }
            if ids.contains(context.id) { store?.screenshotRunning.insert(context.id); continue }
            if let result = try? ScreenshotUploadFiles.url(context.id, suffix: "result"), FileManager.default.fileExists(atPath: result.path) { continue }
            await fail(context.id, message: "后台识别已中断，请重新选图")
        }
    }

    /// 提交已有截图；参数：job 为已持久化的当前空间任务，store 为共享会话；返回值：无；先保存身份快照及上传正文，失败保留错误元数据并清理图片，成功立即交给系统网络进程。
    func submit(_ job: ScreenshotJob, store: AppStore) throws {
        restore(store: store)
        guard let finance = store.finance else { throw APIError(status: 0, message: "本机账本不可用") }
        defer { finance.screenshotImages.removeValue(forKey: job.id) }
        do {
            let settings = try finance.screenshotBook().settings
            guard settings.enabled, settings.configID > 0, !settings.consentID.isEmpty else { throw APIError(status: 0, message: "请启用图片记账并同意图片外发") }
            guard let token = store.api.token, finance.cachedProfile != nil, finance.space["server"] as? String == store.api.baseURL else { throw APIError(status: 0, message: "请先登录并开启同步") }
            guard let image = finance.screenshotImages[job.id] ?? job.image, let session else { throw APIError(status: 0, message: "截图不可用") }
            let server = try APIClient.normalize(store.api.baseURL)
            guard let url = URL(string: server + "/ai/screenshot") else { throw APIError(status: 0, message: "服务器地址无效") }
            let context = ScreenshotUploadContext(id: job.id, spaceKey: finance.activeKey, server: server, tokenHash: Self.hash(token), settings: settings)
            let payload: [String: Any] = ["configId": settings.configID, "configVersion": settings.configVersion, "image": "data:image/jpeg;base64," + image,
                                          "categories": finance.rows("categories").filter { $0["type"] as? String == "expense" }.compactMap { $0["name"] as? String }]
            try ScreenshotUploadFiles.write(JSONEncoder().encode(context), id: job.id, suffix: "context")
            try ScreenshotUploadFiles.write(JSONSerialization.data(withJSONObject: payload), id: job.id, suffix: "payload")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            var processing = job; processing.state = "processing"; processing.message = "正在识别"
            try finance.updateScreenshot(processing)
            let upload = session.uploadTask(with: request, fromFile: try ScreenshotUploadFiles.url(job.id, suffix: "payload"))
            upload.taskDescription = job.id
            _ = ScreenshotActivityReporter.start(id: job.id)
            store.screenshotRunning.insert(job.id)
            upload.resume()
        } catch {
            var failed = job; failed.state = "failed"; failed.message = error.localizedDescription
            try finance.updateScreenshot(failed)
            ScreenshotUploadFiles.remove(job.id)
            throw error
        }
    }

    /// 计算用于身份一致性检查的摘要；参数：token 为当前凭据；返回值：SHA256 字符串，不保存原凭据。
    private static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// 消费已保存响应；参数：无；返回值：无；验证身份及设置后才原子入账，重放终态不重复创建交易。
    func consumeResults() async {
        // 完成事件可能与响应回调交错；等待当前批次结束，不能提前归还系统唤醒时间。
        while consuming { try? await Task.sleep(for: .milliseconds(50)) }
        guard let store, let finance = store.finance else { return }
        consuming = true
        defer { consuming = false }
        for context in ScreenshotUploadFiles.contexts() {
            guard let file = try? ScreenshotUploadFiles.url(context.id, suffix: "result"), let data = try? Data(contentsOf: file) else { continue }
            do {
                let result = try JSONDecoder().decode(ScreenshotUploadResult.self, from: data)
                guard finance.activeKey == context.spaceKey, store.api.baseURL == context.server,
                      store.api.token.map(Self.hash) == context.tokenHash, try finance.screenshotBook().settings == context.settings else {
                    throw APIError(status: 0, message: "账号或图片记账设置已变化，请重新处理")
                }
                guard var job = try finance.screenshotBook().jobs.first(where: { $0.id == context.id }) else { throw APIError(status: 0, message: "截图任务不存在") }
                if job.state == "posted" || job.state == "review" || job.state == "ignored" {
                    // 已提交或已由用户处理的记录不被迟到的响应覆盖，也不再次入账。
                    ScreenshotUploadFiles.remove(context.id); store.screenshotRunning.remove(context.id)
                    continue
                }
                if let error = result.error { throw APIError(status: 0, message: error) }
                guard (200..<300).contains(result.status) else {
                    if result.status == 401 { store.api.onUnauthorized?() }
                    let body = (try? JSONSerialization.jsonObject(with: result.data)) as? [String: Any]
                    throw APIError(status: result.status, message: body?["error"] as? String ?? body?["message"] as? String ?? "识别请求失败（\(result.status)）")
                }
                job.extraction = try JSONDecoder().decode(Envelope<ScreenshotExtraction>.self, from: result.data).data
                job = try finance.prepareScreenshot(job)
                if job.message.isEmpty { job = try finance.postScreenshot(job, manual: false) }
                else { job = try finance.includeIncompleteScreenshot(job) }
                ScreenshotUploadFiles.remove(context.id); store.screenshotRunning.remove(context.id)
                let activity = Activity<ScreenshotActivityAttributes>.activities.first { $0.attributes.id == context.id }
                await ScreenshotActivityReporter.finish(activity, phase: .posted)
            } catch { await fail(context.id, message: error.localizedDescription) }
        }
    }

    /// 保存失败原因到任务所属空间；参数：id 为后台任务，message 为简短错误；返回值：无；不切换空间，不覆盖已入账记录，磁盘失败保留临时响应供恢复。
    func fail(_ id: String, message: String) async {
        guard let store, let finance = store.finance, let context = ScreenshotUploadFiles.contexts().first(where: { $0.id == id }) else { return }
        do {
            try finance.failScreenshot(id, spaceKey: context.spaceKey, message: message)
            ScreenshotUploadFiles.remove(id); store.screenshotRunning.remove(id)
        } catch { finance.syncError = error.localizedDescription }
        let activity = Activity<ScreenshotActivityAttributes>.activities.first { $0.attributes.id == id }
        await ScreenshotActivityReporter.finish(activity, phase: .failed)
    }

    /// 保存系统唤醒的完成回调；参数：identifier 为后台会话标识，completion 为无参数无返回系统回调；返回值：无；未知会话直接完成，不延迟系统。
    func attachCompletion(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { completion(); return }
        self.completion = completion
    }

    /// 归还系统后台事件；参数：无；返回值：无；先完成结果落盘及入账，再允许应用挂起。
    func finishEvents() async {
        await consumeResults()
        let callback = completion; completion = nil; callback?()
    }
}

/// 接收系统后台上传唤醒，不创建独立账本或主动打开主界面。
final class ScreenshotBackgroundAppDelegate: NSObject, UIApplicationDelegate {
    /// 接收后台 URLSession 事件；参数：application 为系统应用，identifier 为会话标识，completionHandler 为系统完成回调；返回值：无；恢复共享状态及上传会话。
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        let coordinator = ScreenshotBackgroundBookkeeping.shared
        coordinator.attachCompletion(identifier: identifier, completion: completionHandler)
        coordinator.restore(store: AppStore.shared)
    }
}
