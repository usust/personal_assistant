import Foundation
import Security

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// 凭证只存入设备钥匙串，不写入偏好设置、日志或业务缓存。
enum TokenVault {
    /// 构造钥匙串查询；参数：server 为规范化服务器地址；返回值：按服务器隔离的查询字典；无副作用。
    static func query(_ server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "vip.lylab.personalassistant", kSecAttrAccount as String: server]
    }
    /// 读取登录凭证；参数：server 为服务器地址；返回值：token，不存在时 nil；不输出密钥。
    static func read(_ server: String) -> String? {
        var fields = query(server)
        fields[kSecReturnData as String] = true
        fields[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(fields as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// 保存凭证；参数：token 为非空凭证，server 为服务器地址；返回值：无；钥匙串不可用时抛错。
    static func save(_ token: String, server: String) throws {
        let fields = query(server)
        let data = Data(token.utf8)
        var status = SecItemUpdate(fields as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = fields
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIError(status: Int(status), message: "无法安全保存登录凭证，请解锁设备后重试。") }
    }
    /// 删除凭证；参数：server 为服务器地址；返回值：无；副作用为清除对应钥匙串条目。
    static func delete(_ server: String) { SecItemDelete(query(server) as CFDictionary) }
}

@MainActor
final class APIClient {
    var baseURL: String
    var token: String?
    var onUnauthorized: (() -> Void)?
    var localFinance: FinanceLocalStore?
    var localFinanceError: String?
    private let session: URLSession

    /// 初始化 API 客户端；参数：baseURL 为含 /api 的地址，session 可注入测试会话，nil 使用无磁盘缓存的临时会话；返回值：客户端；不发起网络请求。
    init(baseURL: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 校验服务器地址；参数：raw 为用户输入；返回值：规范化 URL；无效地址或公网明文地址抛错，无副作用。
    static func normalize(_ raw: String) throws -> String {
        guard var url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && isLocalHTTPHost(host)) else {
            throw APIError(status: 0, message: "请输入 HTTPS 服务地址（含 /api），或局域网 HTTP 地址，例如 http://192.168.88.185:20000/api。")
        }
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = "/" + (url.path.isEmpty ? "api" : url.path)
        guard let normalized = url.url?.absoluteString else { throw APIError(status: 0, message: "服务器地址无效") }
        return normalized
    }

    /// 测试服务器健康接口；参数：raw 为未保存的 API 地址，session 为可选测试会话，nil 创建独立临时会话；返回值：无。
    /// 地址、网络、HTTP 或健康协议错误抛出；不读取钥匙串、不携带登录凭证，也不修改现有客户端或会话。
    static func testConnection(_ raw: String, session: URLSession? = nil) async throws {
        let base = try normalize(raw)
        let client = APIClient(baseURL: base, session: session)
        let data = try await client.networkData("/health", method: "GET", body: nil)
        // 同时校验业务信封和服务身份，避免代理欢迎页或其他服务被误判为连接成功。
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = envelope["code"] as? Int, code == 200,
              let health = envelope["data"] as? [String: Any],
              health["service"] as? String == "personal-assistant",
              health["status"] as? String == "ok" else {
            throw APIError(status: 0, message: "服务器健康响应无效")
        }
    }

    /// 判断明文 HTTP 是否为本地服务；参数：host 为 URLComponents 解析的主机名；返回值：localhost、.local、回环或 RFC 1918 IPv4 为 true；拒绝公网、伪装后缀及非标准 IPv4，不解析 DNS，无副作用。
    static func isLocalHTTPHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || (normalized.hasSuffix(".local") && normalized.count > 6) { return true }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        // 按四段十进制逐段校验，避免把 192.168.example.com 或八进制地址当作内网 IP。
        let bytes = parts.compactMap { UInt8($0) }
        guard bytes.count == 4, zip(parts, bytes).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
        return bytes[0] == 127 || bytes[0] == 10 ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168)
    }

    /// 请求并解包业务数据；类型 T 为响应模型；参数：path 为固定 API 路径，method 为 HTTP 方法，body 为白名单字段，query 为筛选条件；返回值：解码数据；网络/业务/解码错误抛出。
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> T {
        let data = try await routedData(path, method: method, body: body, query: query)
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }

    /// 执行无需读取响应的写操作；参数：path、method 为固定端点，body 为校验后的白名单字典；返回值：无；HTTP 失败抛错，不自动重试写入。
    func mutate(_ path: String, method: String = "POST", body: [String: Any] = [:]) async throws {
        _ = try await routedData(path, method: method, body: body)
    }

    /// 优先分发财务请求到本机；参数：path/method/body/query 为原请求；返回值：信封字节；账本打开失败时阻止财务写入，其他模块保持网络访问。
    private func routedData(_ path: String, method: String, body: [String: Any]?, query: [URLQueryItem] = []) async throws -> Data {
        if path.hasPrefix("/finance/") {
            if let localFinanceError { throw APIError(status: 0, message: localFinanceError) }
            if let localFinance { return try await localFinance.handle(path, method: method, body: body, query: query, api: self) }
        }
        return try await networkData(path, method: method, body: body, query: query)
    }

    /// 发送 JSON；参数：path 为路径，method 为方法，body 为可选字典，query 为查询；返回值：响应字节；401 清理会话，禁止携带凭证跟随重定向。
    func networkData(_ path: String, method: String, body: [String: Any]?, query: [URLQueryItem] = []) async throws -> Data {
        let base = try Self.normalize(baseURL)
        let requestToken = token
        guard var components = URLComponents(string: base + path) else { throw APIError(status: 0, message: "服务器地址无效") }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError(status: 0, message: "请求地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = path == "/health" ? 10 : (path == "/ai/chat" || path == "/ai/screenshot" || path == "/health-management/reports") ? 110 : 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "服务器响应无效") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 && requestToken != nil && token == requestToken && baseURL == base { onUnauthorized?() }
            // 当前后端统一使用 message；旧 error 仅用于兼容历史服务，不能覆盖新协议提示。
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError(status: http.statusCode, message: error?["message"] as? String ?? error?["error"] as? String ?? "请求失败（\(http.statusCode)），请稍后重试。")
        }
        return data
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// 禁止自动重定向泄露凭证；参数：session/task 为当前请求，response 为跳转响应，request 为新请求，completionHandler 为系统回调；返回值：无，回调 nil 终止跳转。
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
