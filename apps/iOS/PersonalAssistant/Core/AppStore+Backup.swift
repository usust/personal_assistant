import Foundation

extension AppStore {
    /// 捕获本机账本并按需读取完整云端快照；参数：scope 为全部账号数据或仅本机账本；返回值：可保存的版本化 JSON 文件；无业务写入，缺模块、会话变化、取消或网络错误抛出，不把失败降级成本机备份。
    func exportBackup(scope: DataBackup.Scope) async throws -> Data {
        guard !isAuthenticating else { throw APIError(status: 409, message: "请等待登录完成") }
        guard let finance else { throw APIError(status: 0, message: localStorageError ?? "无法读取本机账本") }
        let generation = sessionID
        let cloudGeneration = cloudSessionID
        let key = finance.activeKey
        let server = api.baseURL
        let userID = profile?.id
        let token = api.token
        if scope == .account {
            guard canUseCloud, let userID else { throw APIError(status: 401, message: "请先登录，再导出全部数据") }
            // 绑定信息而非历史空间名称决定归属；游客空间明确绑定后也不能随其他账号导出。
            if let boundProfile = finance.cachedProfile {
                guard boundProfile.id == userID, finance.space["server"] as? String == server else {
                    throw DataBackup.Failure.wrongOwner
                }
            } else if key != "guest" {
                throw DataBackup.Failure.wrongOwner
            }
        }
        // 在任何网络等待之前深拷贝完整空间。同步可能随后确认并移除命令，文件仍保留捕获时的队列，避免未上传数据丢失。
        let local = try DataBackup.captureLocal(
            key: key, space: finance.space,
            preferences: DataBackup.preferences(spaceKey: key),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
        let snapshot: Data?
        if scope == .account { snapshot = try await api.networkData("/backup/export", method: "GET", body: nil) }
        else { snapshot = nil }
        try Task.checkCancellation()
        // 注销、切换账号/服务器或空间后，丢弃旧请求，禁止把两位用户的数据混在同一文件中。
        guard generation == sessionID, cloudGeneration == cloudSessionID, key == finance.activeKey,
              server == api.baseURL, userID == profile?.id, token == api.token else { throw CancellationError() }
        return try DataBackup.makeFile(local: local, server: snapshot, ownerID: userID, serverURL: server)
    }
}
