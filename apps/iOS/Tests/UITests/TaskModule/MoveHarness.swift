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
    override func startLoading() {
        let data = Data(#"{"message":"injected read failure"}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
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
@main struct MoveHarness {
    /// 创建虚构任务；参数id为主键，parent为父ID，list为清单，archived为归档；返回固定任务，不读写真实存储。
    static func row(_ id: Int, parent: Int? = nil, list: Int = 1, archived: Bool = false) -> AssistantTask {
        AssistantTask(id: id, title: "节点", remark: "保留备注", listId: list, parentId: parent, taskType: id == 1 ? "main" : "subtask", priority: "medium", startDate: "", startTime: "", endDate: "", endTime: "", archived: archived, sortOrder: id, progressTotal: 10, progressCompleted: 5, progressStep: 1, progressUnit: "页")
    }
    /// 执行真实Store写后读失败验收；参数无；返回无；仅隔离内存传输，断言失败终止进程。
    @MainActor static func main() async throws {
        let ordering=[row(1),row(2),row(3),row(4),row(5)]
        precondition(Values.taskOrderPreservingHidden(ordering, orderedVisibleIDs:[5,1,3]) == [5,2,1,4,3])
        precondition(Values.taskOrderPreservingHidden(ordering, orderedVisibleIDs:[5,5]) == [1,2,3,4,5])
        print("PASS production ordering preserves hidden slots and rejects duplicate IDs")
        let store = AppStore()
        store.profile = Profile(id: 1, account: "test", nickname: "test", role: "user")
        let original = [row(1), row(2, parent: 1, archived: true), row(3, parent: 2), row(8, list: 9)]
        store.tasks = original
        var moved = original[0]; moved.listId = 2
        // 确认写回调输入无、输出服务器确认根；模拟已确认写，与真实刷新503组成可控恢复边界。
        let saved = try await store.writeTask { moved }
        store.upsertTask(saved)
        await store.refreshTaskWrite()
        precondition(store.tasks.map(\.listId) == [2, 2, 2, 9], "read failure exposed split local tree")
        precondition(store.tasks[1].archived && store.tasks[2].parentId == 2 && store.tasks[2].remark == "保留备注")
        precondition(store.taskWriteBlocked && store.taskNotice?.contains("已保存") == true)
        print("PASS real AppStore confirmed subtree move remains coherent after GET503")
        let unknown = AppStore(); unknown.profile = store.profile; unknown.tasks = original
        do {
            // 未知写回调输入无、输出无；传输丢失时不提供成功根，因此不得应用整树推断。
            try await unknown.writeTask { throw URLError(.networkConnectionLost) }
            fatalError("unknown response should fail")
        } catch {}
        precondition(unknown.tasks == original && unknown.taskWriteBlocked)
        print("PASS unknown move does not infer local subtree changes")
    }
}
