import Foundation

/// 独立测试替身，不访问真实钥匙串。
@MainActor private final class MemoryAssistantKeys: AssistantAPIKeyStoring {
    var values: [Int: String] = [:]
    var shouldFail = false
    var reads = 0
    /// 读取测试密钥；参数：configID 为配置 ID；返回值：密钥或 nil；启用故障时抛错。
    func read(configID: Int) throws -> String? {
        reads += 1
        if shouldFail { throw AssistantLocalStoreError.keychain(-1) }
        return values[configID]
    }
    /// 写入测试密钥；参数：value 为密钥，configID 为配置 ID；返回值：无；启用故障时抛错。
    func save(_ value: String, configID: Int) throws {
        if shouldFail { throw AssistantLocalStoreError.keychain(-1) }
        values[configID] = value
    }
    /// 删除测试密钥；参数：configID 为配置 ID；返回值：无；启用故障时抛错。
    func delete(configID: Int) throws {
        if shouldFail { throw AssistantLocalStoreError.keychain(-1) }
        values.removeValue(forKey: configID)
    }
}

@main private struct AssistantLocalStoreTests {
    /// 执行独立测试；参数：无；返回值：无；失败抛错退出，仅使用临时目录与内存密钥，不联网。
    @MainActor static func main() throws {
        let temporaryRoot = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = temporaryRoot.appendingPathComponent("assistant-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try roundTripAndSecrets(root.appendingPathComponent("roundtrip"))
        try invalidInput(root.appendingPathComponent("invalid"))
        try writeFailure(root.appendingPathComponent("failure"))
        try corruptAndFutureDocuments(root.appendingPathComponent("corrupt"))
        print("AssistantLocalStoreTests: passed (round trip, secrets, validation, write failure, corrupt/version guards)")
    }

    /// 构造测试模型；参数：id 为配置 ID，url 为无密钥地址；返回值：完整界面配置，云身份用于验证导出白名单。
    private static func config(_ id: Int = 1, url: String = "https://example.invalid/v1") -> AIConfig {
        AIConfig(id: id, name: "本机模型", model_name: "test-model", provider_name: "test",
                 is_selected: true, base_url: url, owner_type: "user", owner_id: 42, visibility: "shared")
    }

    /// 断言条件；参数：condition 为必须成立的条件，message 为失败说明；返回值：无；失败中止测试。
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    /// 验证调用抛错；参数：operation 为无参数无返回值的待测操作，允许副作用；返回值：无；未抛错则中止测试。
    @MainActor private static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected operation to fail") } catch { }
    }

    /// 验证重启、UUID、动作、权限、导出和密钥隔离；参数：directory 为隔离目录；返回值：无；测试异常向上传递。
    @MainActor private static func roundTripAndSecrets(_ directory: URL) throws {
        let keys = MemoryAssistantKeys()
        let store = try AssistantLocalStore(directory: directory, keychain: keys)
        check(store.snapshot.configs.isEmpty && store.snapshot.messages.isEmpty && store.snapshot.chatConfigID == 0, "Empty first launch")
        try store.saveConfigurations([config()], selectedConfigID: 1)
        let message = ChatMessage(role: "user", content: "本机草稿")
        try store.saveHistory(messages: [message], actions: [ChatAction(name: "task", success: false, error: "未执行")])
        try store.saveAPIKey("secret-only-in-keychain", configID: 1)
        let exported = try store.exportData()
        check(keys.reads == 0, "Export must never read keys")
        let text = String(decoding: exported, as: UTF8.self)
        check(!text.contains("secret-only-in-keychain") && !text.contains("api_key") && !text.contains("owner_id"), "Export excludes secrets and cloud identity")
        check(try Data(contentsOf: store.fileURL) == exported, "Disk matches safe export")
        let reopened = try AssistantLocalStore(directory: directory, keychain: keys)
        check(reopened.loadConfigurations().first?.name == "本机模型", "Configurations survive restart")
        check(reopened.snapshot.configs.first?.owner_type == "local" && reopened.snapshot.configs.first?.visibility == "private", "Restored config is local/private")
        check(reopened.snapshot.chatConfigID == 1, "Selection survives restart")
        let history = reopened.loadHistory()
        check(history.messages.first?.id == message.id && history.messages.first?.content == message.content, "Message and UUID survive restart")
        check(history.actions.first?.success == false && history.actions.first?.error == "未执行", "Actions survive restart")
        check(try reopened.readAPIKey(configID: 1) == "secret-only-in-keychain", "Explicit key read")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "File permissions 0600")
        let before = try reopened.exportData()
        keys.shouldFail = true
        // 故障回调无参数和返回值；确认钥匙串不可用时不写入 JSON 或吞掉错误。
        expectFailure { try reopened.saveAPIKey("replacement", configID: 1) }
        expectFailure { _ = try reopened.readAPIKey(configID: 1) }
        check(try reopened.exportData() == before, "Keychain failure leaves JSON unchanged")
        keys.shouldFail = false
        try reopened.saveConfigurations([])
        check(reopened.snapshot.chatConfigID == 0 && reopened.snapshot.messages.count == 1, "Removal clears selection, retains history")
        try reopened.deleteAPIKey(configID: 1)
        check(keys.values.isEmpty, "Orphan key explicitly removed")
        try reopened.saveHistory(messages: [], actions: [])
        check(try AssistantLocalStore(directory: directory, keychain: keys).snapshot.messages.isEmpty, "Explicit history clear persists")
    }

    /// 验证 ID 和 URL 白名单；参数：directory 为隔离目录；返回值：无；非法输入必须保留已有快照及文件。
    @MainActor private static func invalidInput(_ directory: URL) throws {
        let store = try AssistantLocalStore(directory: directory, keychain: MemoryAssistantKeys())
        try store.saveConfigurations([config()], selectedConfigID: 1)
        let before = try store.exportData()
        // 各故障回调无参数和返回值；覆盖引用、重复 ID、URL 内嵌密钥与空密钥。
        expectFailure { try store.saveSelectedConfiguration(2) }
        expectFailure { try store.saveConfigurations([config(), config()]) }
        expectFailure { try store.saveConfigurations([config(0)]) }
        expectFailure { try store.saveConfigurations([config()], selectedConfigID: 2) }
        for url in ["https://user:key@example.invalid", "https://example.invalid?api_key=secret", "https://example.invalid#secret", "file:///secret", "not a URL"] {
            expectFailure { try store.saveConfigurations([config(url: url)]) }
        }
        expectFailure { try store.saveAPIKey("", configID: 1) }
        expectFailure { try store.saveAPIKey("secret", configID: 2) }
        check(try store.exportData() == before && Data(contentsOf: store.fileURL) == before, "Invalid writes retain state")
        try store.saveConfigurations([config(2)])
        check(store.snapshot.chatConfigID == 0, "Missing current selection resets to zero")
    }

    /// 验证原子写入失败；参数：directory 为隔离目录；返回值：无；用只读目录阻止临时文件创建，恢复权限后核对原文件和快照。
    @MainActor private static func writeFailure(_ directory: URL) throws {
        let store = try AssistantLocalStore(directory: directory, keychain: MemoryAssistantKeys())
        try store.saveConfigurations([config()], selectedConfigID: 1)
        let before = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        // 故障回调无参数和返回值；写盘失败不能发布新历史。
        expectFailure { try store.saveHistory(messages: [ChatMessage(role: "user", content: "不应落盘")], actions: []) }
        check(store.snapshot.messages.isEmpty, "Failed write preserves snapshot")
        check(try Data(contentsOf: store.fileURL) == before, "Failed write preserves old file")
    }

    /// 验证损坏文件与未来版本不会被覆盖；参数：directory 为隔离目录；返回值：无；构造测试文件并核对错误后数据原样保留。
    @MainActor private static func corruptAndFutureDocuments(_ directory: URL) throws {
        let store = try AssistantLocalStore(directory: directory, keychain: MemoryAssistantKeys())
        try store.saveConfigurations([config()])
        var document = try JSONSerialization.jsonObject(with: store.exportData()) as! [String: Any]
        document["version"] = 999
        let future = try JSONSerialization.data(withJSONObject: document)
        try future.write(to: store.fileURL)
        // 故障回调无参数和返回值；未知版本与损坏内容必须报告错误，不重置用户数据。
        expectFailure { _ = try AssistantLocalStore(directory: directory, keychain: MemoryAssistantKeys()) }
        check(try Data(contentsOf: store.fileURL) == future, "Future version untouched")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: store.fileURL)
        expectFailure { _ = try AssistantLocalStore(directory: directory, keychain: MemoryAssistantKeys()) }
        check(try Data(contentsOf: store.fileURL) == corrupt, "Corrupt file untouched")
    }
}
