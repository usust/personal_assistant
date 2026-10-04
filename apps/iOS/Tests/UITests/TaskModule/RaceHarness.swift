import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 通知替身隔离任务验收；不请求权限或修改排程。
@MainActor enum CreditReminders {
    /// 清理替身；参数无；返回无，无副作用。
    static func clear() {}
    /// 同步替身；参数为财务账户；返回无，无副作用。
    static func sync(_ accounts: [FinancialAccount]) async throws {}
}
/// 手动延迟读取协议，测试真实 AppStore 方法并精确控制响应顺序。
nonisolated class PreviewProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var pending: [PreviewProtocol] = []
    /// 接管预览请求；参数为请求；返回 true，全部请求进入隔离队列。
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// 保留请求；参数为请求；返回原请求。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// 暂存读取；参数无；返回无，只有 release 才响应。
    override func startLoading() { Self.lock.lock(); Self.pending.append(self); Self.lock.unlock() }
    /// 结束协议；参数无；返回无，不产生额外回调。
    override func stopLoading() {}
    /// 手动释放队列；参数 task 为固定快照；返回无，写入网络响应但不联网。
    static func release(_ task: AssistantTask) {
        lock.lock(); let requests = pending; pending = []; lock.unlock()
        for item in requests {
            let payload: Any
            if item.request.url!.path.hasSuffix("task-lists") { payload = [["id": 1,"name":"验收清单","remark":"","color":"#14B8A6","icon":"Folder"]] as [[String:Any]] } else { payload = [try! JSONSerialization.jsonObject(with: JSONEncoder().encode(task))] }
            let bytes = try! JSONSerialization.data(withJSONObject: ["data":payload])
            item.client?.urlProtocol(item, didReceive: HTTPURLResponse(url:item.request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!, cacheStoragePolicy:.notAllowed)
            item.client?.urlProtocol(item, didLoad:bytes);item.client?.urlProtocolDidFinishLoading(item)
        }
    }
    /// 读取队列数；参数无；返回并发请求数，锁保护。
    static var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
}
/// 满足 Debug 编译引用；继承受控协议，无额外业务。
nonisolated final class TaskScenarioProtocol: PreviewProtocol, @unchecked Sendable {}
@main struct RaceHarness {
    /// 创建任务快照；参数为进度；返回固定虚构任务，无副作用。
    static func row(_ value: Double) -> AssistantTask { AssistantTask(id:1,title:"竞态样本",remark:"",listId:1,parentId:nil,taskType:"subtask",priority:"medium",startDate:"",startTime:"",endDate:"",endTime:"",archived:false,sortOrder:0,progressTotal:10,progressCompleted:value,progressStep:1,progressUnit:"次") }
    /// 等待协议队列入场；参数无；返回无，不设随机延迟。
    @MainActor static func waitRead() async { while PreviewProtocol.count < 2 { await Task.yield() } }
    /// 验收过期读与写期间启动读；参数无；返回无，失败退出非零；真实 AppStore/APIClient 加隔离传输。
    @MainActor static func main() async throws {
        let store = AppStore();store.profile=Profile(id:1,account:"验收",nickname:"验收",role:"user");store.tasks=[row(2)]
        let before = Task { try await store.loadTasks() };await waitRead()
        let saved = try await store.writeTask { row(3) };store.upsertTask(saved)
        PreviewProtocol.release(row(2))
        do { try await before.value; fatalError("旧读不应成功") } catch is CancellationError { print("PASS old read rejected") }
        precondition(store.tasks[0].progressCompleted == 3 && store.taskWriteBlocked)
        // 精确将 GET 启动置于 mutation await 期间，随后先结束写再释放旧GET。
        let second = AppStore();second.profile=Profile(id:1,account:"验收",nickname:"验收",role:"user");second.tasks=[row(2)]
        var finish: CheckedContinuation<AssistantTask, Never>?
        let writing = Task { try await second.writeTask { await withCheckedContinuation { finish=$0 } } }
        while finish == nil { await Task.yield() }
        do { try await second.loadTasks(); fatalError("busy期间读不应成功") } catch is CancellationError { print("PASS busy read rejected before transport") }
        precondition(PreviewProtocol.count == 0, "busy read started transport")
        finish!.resume(returning:row(3));let result=try await writing.value;second.upsertTask(result)
        precondition(second.tasks[0].progressCompleted == 3 && second.taskWriteBlocked)
        let after = Task { try await second.loadTasks() };await waitRead();PreviewProtocol.release(row(3));try await after.value
        precondition(second.tasks[0].progressCompleted == 3 && !second.taskWriteBlocked)
        print("PASS fresh read unlocks")
        print("PASS race harness")
    }
}
