import Foundation
import Security

/// 本机助手快照，不携带 API 密钥；模型配置与现有界面协议保持一致。
nonisolated struct AssistantLocalSnapshot {
    var configs: [AIConfig] = []
    var messages: [ChatMessage] = []
    var actions: [ChatAction] = []
    var chatConfigID: Int = 0
}

/// 密钥存取边界；生产实现仅使用本机 Keychain，测试可注入内存实现。
@MainActor protocol AssistantAPIKeyStoring {
    /// 读取密钥；参数：configID 为正整数配置 ID；返回值：密钥，不存在为 nil；失败抛错，不能将失败当作不存在。
    func read(configID: Int) throws -> String?
    /// 保存密钥；参数：value 为非空密钥，configID 为正整数配置 ID；返回值：无；失败抛错，不落盘到 JSON。
    func save(_ value: String, configID: Int) throws
    /// 删除密钥；参数：configID 为正整数配置 ID；返回值：无；不存在视为成功，其余失败抛错。
    func delete(configID: Int) throws
}

nonisolated enum AssistantLocalStoreError: Error, LocalizedError {
    case invalidConfiguration
    case invalidSelection
    case emptyAPIKey
    case unsupportedVersion(Int)
    case keychain(OSStatus)

    /// 返回不包含密钥或原始数据的错误说明；参数：无；返回值：可展示的中文错误。
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "本机模型配置无效，地址不能包含凭证、查询参数或片段。"
        case .invalidSelection: return "所选模型配置不存在。"
        case .emptyAPIKey: return "API 密钥不能为空。"
        case .unsupportedVersion: return "本机助手数据版本不受支持。"
        case .keychain: return "无法访问本机助手密钥。"
        }
    }
}

@MainActor final class AssistantKeychainStore: AssistantAPIKeyStoring {
    private let service: String

    /// 建立独立钥匙串命名空间；参数：service 为稳定服务标识，不应与登录令牌共用；返回值：密钥存储，不立即访问钥匙串。
    init(service: String = "personal-assistant.local-assistant.api-keys") { self.service = service }

    /// 构造仅匹配本机非同步密钥的查询；参数：configID 为正整数配置 ID；返回值：Keychain 查询；非法 ID 抛错。
    private func query(configID: Int) throws -> [String: Any] {
        guard configID > 0 else { throw AssistantLocalStoreError.invalidConfiguration }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: String(configID), kSecAttrSynchronizable as String: false]
    }

    /// 从钥匙串读取密钥；参数：configID 为正整数配置 ID；返回值：原始密钥，不存在为 nil；权限和解码失败抛错。
    func read(configID: Int) throws -> String? {
        var fields = try query(configID: configID)
        fields[kSecReturnData as String] = true
        fields[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(fields as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AssistantLocalStoreError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AssistantLocalStoreError.keychain(errSecDecode)
        }
        return value
    }

    /// 新建或替换密钥；参数：value 为非空原始密钥，configID 为正整数配置 ID；返回值：无；解锁后仅本设备可访问，不同步 iCloud，失败抛错。
    func save(_ value: String, configID: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantLocalStoreError.emptyAPIKey }
        let fields = try query(configID: configID)
        let updates: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(fields as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var addition = fields
            // 合并回调参数为旧属性和新属性；返回新属性，确保使用新的密钥和访问保护。
            addition.merge(updates) { _, new in new }
            status = SecItemAdd(addition as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AssistantLocalStoreError.keychain(status) }
    }

    /// 删除指定密钥；参数：configID 为正整数配置 ID；返回值：无；不存在视为成功，其他错误抛出。
    func delete(configID: Int) throws {
        let status = SecItemDelete(try query(configID: configID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantLocalStoreError.keychain(status) }
    }
}

/// 独立于账号的本机持久化。没有 APIClient、URLSession、网络推理、自动上传或同步行为。
/// 应用应共用一个实例；主线程串行读写保证同实例不会丢失配置与历史的交叉修改。
@MainActor final class AssistantLocalStore {
    private(set) var snapshot: AssistantLocalSnapshot
    let fileURL: URL
    private let keychain: any AssistantAPIKeyStoring

    /// 打开本机存储；参数：directory 为专用目录，nil 使用 Application Support；keychain 为可选测试替身，nil 使用本机钥匙串；返回值：已加载存储。损坏、版本不兼容或文件权限错误抛出且不覆盖原文件；无需登录，不读取密钥。
    init(directory: URL? = nil, keychain: (any AssistantAPIKeyStoring)? = nil) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PersonalAssistant/AssistantLocal", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // 不更改系统备份标志，沿用应用既有备份策略。
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        #endif
        fileURL = root.appendingPathComponent("assistant.json")
        self.keychain = keychain ?? AssistantKeychainStore()
        snapshot = AssistantLocalSnapshot()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.version == 1 else { throw AssistantLocalStoreError.unsupportedVersion(document.version) }
            let loaded = document.snapshot
            try Self.validate(loaded)
            snapshot = loaded
        }
    }

    /// 读取内存配置；参数：无；返回值：不含密钥的配置数组，不触发网络或钥匙串访问。
    func loadConfigurations() -> [AIConfig] { snapshot.configs }

    /// 原子替换配置列表；参数：configs 为唯一正 ID 的配置，selectedConfigID 为选择 ID（0 表示未选择），nil 保留现有有效选择否则回退 0；返回值：无。配置密钥需显式单独管理，失败保留内存与旧文件。
    func saveConfigurations(_ configs: [AIConfig], selectedConfigID: Int? = nil) throws {
        var updated = snapshot
        updated.configs = configs
        updated.chatConfigID = selectedConfigID ?? (configs.contains { $0.id == snapshot.chatConfigID } ? snapshot.chatConfigID : 0)
        try persist(updated)
    }

    /// 保存当前模型选择；参数：id 为已保存配置 ID 或 0（取消选择）；返回值：无；不存在的 ID 抛错，不改其他数据。
    func saveSelectedConfiguration(_ id: Int) throws {
        var updated = snapshot
        updated.chatConfigID = id
        try persist(updated)
    }

    /// 读取历史；参数：无；返回值：消息与动作数组，保留消息 UUID，不联网。
    func loadHistory() -> (messages: [ChatMessage], actions: [ChatAction]) { (snapshot.messages, snapshot.actions) }

    /// 原子保存消息和动作；参数：messages 为完整消息列表，actions 为完整动作列表，空数组表示清空；返回值：无；失败不改变快照或旧文件，不执行任何动作。
    func saveHistory(messages: [ChatMessage], actions: [ChatAction]) throws {
        var updated = snapshot
        updated.messages = messages
        updated.actions = actions
        try persist(updated)
    }

    /// 显式读取配置密钥；参数：configID 必须对应已保存配置；返回值：密钥或 nil；钥匙串失败向上传递，不发送请求。
    func readAPIKey(configID: Int) throws -> String? {
        try requireConfiguration(configID)
        return try keychain.read(configID: configID)
    }

    /// 显式保存配置密钥；参数：value 为非空密钥，configID 必须对应已保存配置；返回值：无；只写钥匙串，失败不写 JSON；编辑器留空保留旧值时不应调用本方法。
    func saveAPIKey(_ value: String, configID: Int) throws {
        try requireConfiguration(configID)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantLocalStoreError.emptyAPIKey }
        try keychain.save(value, configID: configID)
    }

    /// 删除密钥（可清理已移除配置）；参数：configID 为正整数配置 ID；返回值：无；只访问钥匙串，不修改配置，失败抛错。
    func deleteAPIKey(configID: Int) throws {
        guard configID > 0 else { throw AssistantLocalStoreError.invalidConfiguration }
        try keychain.delete(configID: configID)
    }

    /// 导出当前快照；参数：无；返回值：版本化 JSON 数据，不读取或包含钥匙串密钥。聊天正文按原样导出，用户自行粘贴的敏感文字不属于密钥字段；不写文件、不联网。
    func exportData() throws -> Data { try Self.encode(snapshot) }

    /// 校验密钥关联配置；参数：id 为配置 ID；返回值：无；缺失抛错，避免误用云端或其他空间 ID。
    private func requireConfiguration(_ id: Int) throws {
        guard snapshot.configs.contains(where: { $0.id == id }) else { throw AssistantLocalStoreError.invalidSelection }
    }

    /// 校验可落盘状态；参数：value 为候选快照；返回值：无；重复 ID、非法选择或含 URL 凭证的地址抛错，禁止把密钥塞入连接 URL。
    private static func validate(_ value: AssistantLocalSnapshot) throws {
        var ids = Set<Int>()
        for config in value.configs {
            guard config.id > 0, ids.insert(config.id).inserted,
                  let url = URLComponents(string: config.base_url),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw AssistantLocalStoreError.invalidConfiguration
            }
        }
        guard value.chatConfigID == 0 || ids.contains(value.chatConfigID) else { throw AssistantLocalStoreError.invalidSelection }
    }

    /// 编码白名单字段；参数：value 为快照；返回值：可持久化 JSON；编码失败抛错，密钥不在文档类型中。
    private static func encode(_ value: AssistantLocalSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(value))
    }

    /// 先写受保护临时文件再原子替换；参数：value 为候选快照；返回值：无；只有写入成功才发布快照，写失败保留旧数据。
    private func persist(_ value: AssistantLocalSnapshot) throws {
        try Self.validate(value)
        let data = try Self.encode(value)
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".assistant-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // 目录权限已限制为 0700；临时文件先设置 0600 与 iOS 完全保护，再进入原子重命名，避免替换后才补保护的窗口。
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        // 替换前同步并关闭临时文件；同步或关闭失败时保留旧文件与快照，清理未发布的临时文件。
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
        snapshot = value
    }

    /// 文档只收录非敏感配置字段，不持久化云端身份、所有权、共享权限或密钥。
    private struct ConfigurationRecord: Codable {
        let id: Int
        let name: String
        let model_name: String
        let provider_name: String
        let is_selected: Bool
        let base_url: String

        /// 投影配置到磁盘白名单；参数：value 为界面配置；返回值：无密钥配置记录。
        init(_ value: AIConfig) {
            id = value.id; name = value.name; model_name = value.model_name
            provider_name = value.provider_name; is_selected = value.is_selected; base_url = value.base_url
        }
        /// 恢复界面配置；参数：无；返回值：本机私有配置，不继承云端所有权。
        var config: AIConfig {
            AIConfig(id: id, name: name, model_name: model_name, provider_name: provider_name,
                     is_selected: is_selected, base_url: base_url, owner_type: "local", visibility: "private")
        }
    }

    private struct MessageRecord: Codable {
        let id: UUID
        let role: String
        let content: String
        /// 保留消息身份；参数：value 为消息；返回值：含 UUID 的磁盘记录，避免原 ChatMessage 编码丢失 ID。
        init(_ value: ChatMessage) { id = value.id; role = value.role; content = value.content }
        /// 还原消息；参数：无；返回值：具有原 UUID 的消息。
        var message: ChatMessage { ChatMessage(id: id, role: role, content: content) }
    }

    private struct ActionRecord: Codable {
        let name: String
        let success: Bool
        let error: String?
        /// 编码动作结果；参数：value 为动作，不会执行；返回值：可编码动作记录。
        init(_ value: ChatAction) { name = value.name; success = value.success; error = value.error }
        /// 还原动作结果；参数：无；返回值：原状态动作，无执行副作用。
        var action: ChatAction { ChatAction(name: name, success: success, error: error) }
    }

    private struct Document: Codable {
        var version = 1
        let configs: [ConfigurationRecord]
        let messages: [MessageRecord]
        let actions: [ActionRecord]
        let chatConfigID: Int
        /// 构造版本化文档；参数：value 为快照；返回值：不含密钥的文档。
        init(_ value: AssistantLocalSnapshot) {
            configs = value.configs.map(ConfigurationRecord.init)
            messages = value.messages.map(MessageRecord.init)
            actions = value.actions.map(ActionRecord.init)
            chatConfigID = value.chatConfigID
        }
        /// 还原快照；参数：无；返回值：待校验的完整本机状态。
        var snapshot: AssistantLocalSnapshot {
            AssistantLocalSnapshot(configs: configs.map(\.config), messages: messages.map(\.message),
                                   actions: actions.map(\.action), chatConfigID: chatConfigID)
        }
    }
}
