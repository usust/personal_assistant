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
    /// 响应指定请求；参数path、status、payload为固定测试响应；返回无，只作用于隔离协议。
    static func respond(_ path:String,status:Int=200,payload:Any) {
        lock.lock();let selected=pending.filter { $0.request.url!.path == path };pending.removeAll { $0.request.url!.path == path };lock.unlock()
        for item in selected { let envelope: [String:Any]
            if status==200 { envelope=["data":payload] } else { envelope=["message":"身份校验拒绝"] }
            let bytes=try! JSONSerialization.data(withJSONObject:envelope)
            item.client?.urlProtocol(item,didReceive:HTTPURLResponse(url:item.request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            item.client?.urlProtocol(item,didLoad:bytes);item.client?.urlProtocolDidFinishLoading(item)
        }
    }
    /// 检查请求是否入队；参数path为固定路径；返回布尔值，锁保护。
    static func has(_ path:String)->Bool { lock.lock();defer{lock.unlock()};return pending.contains { $0.request.url!.path == path } }
    /// 读取队列数；参数无；返回并发请求数，锁保护。
    static var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
}
/// 满足 Debug 编译引用；继承受控协议，无额外业务。
nonisolated final class TaskScenarioProtocol: PreviewProtocol, @unchecked Sendable {}
@main struct CloudIdentityHarness {
    /// 等待真实URLSession请求；参数path为固定端点；返回无，无网络访问。
    @MainActor static func wait(_ path:String) async { while !PreviewProtocol.has(path) { await Task.yield() } }
    /// 复现登录身份校验401；参数无；返回无，打印导航和错误类型，真实Store/APIClient加受控传输。
    @MainActor static func main() async throws {
        let store=AppStore();store.profile=Profile(id:1,account:"A",nickname:"A",role:"user");store.api.token="A-token"
        store.messages=[ChatMessage(role:"user",content:"A-private-context")];store.chatSending=true;store.chatConfigID=99;store.syncWarning="A-warning"
        let ledger=try FinanceLocalStore(url:URL(fileURLWithPath:"/private/tmp/task-module-after/auth-"+UUID().uuidString+".sqlite"))
        _ = try ledger.writeLocal("/finance/accounts",method:"POST",body:["name":"离线账户","accountType":"cash","balance":"100.00"])
        try ledger.enable(server:store.api.baseURL,profile:store.profile!);store.finance=ledger
        let financeBefore=try JSONSerialization.data(withJSONObject:ledger.space,options:.sortedKeys)
        let nav=store.sessionID,cloud=store.cloudSessionID
        let logging=Task { do { try await store.login(account:"B",password:"fake",captcha:Captcha(captcha_id:"fake",image:"",expires_at:9999),answer:"test-fixture");return "success" } catch { return String(describing:type(of:error))+":"+error.localizedDescription } }
        await wait("/api/auth/login")
        precondition(store.sessionID==nav && store.cloudSessionID != cloud && !store.canUseCloud && store.isAuthenticating)
        precondition(store.messages.isEmpty && !store.chatSending && store.chatConfigID==0 && store.syncWarning==nil)
        let snapshot=try JSONSerialization.data(withJSONObject:ledger.space,options:.sortedKeys);precondition(snapshot==financeBefore)
        print("PASS login start preserves nav and finance, clears AI, blocks cloud")
        PreviewProtocol.respond("/api/auth/login",payload:["token":"B-token"]);await wait("/api/users/me")
        precondition(store.api.token=="B-token" && !store.canUseCloud)
        PreviewProtocol.respond("/api/users/me",status:401,payload:NSNull())
        let outcome=await logging.value
        precondition(outcome.hasPrefix("APIError:") && store.sessionID==nav && !store.isAuthenticating && store.api.token==nil)
        print("401 outcome:",outcome,"navPreserved:",store.sessionID==nav,"financePreserved:",(try JSONSerialization.data(withJSONObject:ledger.space,options:.sortedKeys))==financeBefore)
        // 模拟已有账号请求延迟跨入 B 登录，真实 Store 必须丢弃旧任务和配置。
        store.api.token="A-token"
        let oldTasks=Task { try await store.loadTasks() };await wait("/api/tasks");await wait("/api/task-lists")
        let oldConfigs=Task { try await store.loadConfigs() };await wait("/api/setting/ai/provider_config")
        let success=Task { try await store.login(account:"B",password:"fake",captcha:Captcha(captcha_id:"fake",image:"",expires_at:9999),answer:"test-fixture") }
        await wait("/api/auth/login");PreviewProtocol.respond("/api/auth/login",payload:["token":"B-token"])
        await wait("/api/users/me");PreviewProtocol.respond("/api/users/me",payload:["id":2,"account":"B","nickname":"B","role":"user"])
        try await success.value
        precondition(store.profile?.id==2 && store.canUseCloud && store.sessionID != nav && store.messages.isEmpty)
        print("PASS B success rotates navigation with empty A history")
        PreviewProtocol.respond("/api/tasks",payload:[]);PreviewProtocol.respond("/api/task-lists",payload:[])
        PreviewProtocol.respond("/api/setting/ai/provider_config",payload:[])
        do { try await oldTasks.value;fatalError("old tasks accepted") } catch is CancellationError {}
        do { try await oldConfigs.value;fatalError("old configs accepted") } catch is CancellationError {}
        print("PASS old A task/config responses cancelled")
        // 预览只在初始化和凭证副作用中使用；仅临时关预览读取计算属性，证明 token 门槛。
        store.isPreview=false;store.api.token=nil;precondition(!store.canUseCloud);store.api.token="B-token";precondition(store.canUseCloud);store.isPreview=true
        let bnav=store.sessionID,bcloud=store.cloudSessionID
        store.messages=[ChatMessage(role:"user",content:"B")];store.chatSending=true
        let bfinance=try JSONSerialization.data(withJSONObject:ledger.space,options:.sortedKeys)
        let current=Task { try await store.loadConfigs() };await wait("/api/setting/ai/provider_config")
        PreviewProtocol.respond("/api/setting/ai/provider_config",status:401,payload:NSNull())
        do { try await current.value;fatalError("401 succeeded") } catch {}
        precondition(store.sessionID != bnav && store.cloudSessionID != bcloud && store.messages.isEmpty && !store.chatSending && store.api.token==nil)
        let currentFinance=try JSONSerialization.data(withJSONObject:ledger.space,options:.sortedKeys);precondition(currentFinance==bfinance)
        print("PASS current 401 clears cloud and preserves finance; credential gate separately checked")
    }
}
