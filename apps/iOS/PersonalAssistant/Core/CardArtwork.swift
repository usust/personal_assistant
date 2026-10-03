import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import CryptoKit

/// 搜索结果只包含公开卡面，不携带用户卡号或账务资料。
struct CardArtworkCandidate: Identifiable {
    var id: String { imageURL.absoluteString }
    let imageURL: URL
    let sourceURL: URL?
    let title: String
}

/// 卡面为本机展示偏好，与财务同步及余额独立。
struct SavedCardArtwork: Codable {
    let query: String
    let manual: Bool
    let image: Data
}

enum CardArtwork {
    /// 匹配已核验的卡种素材；参数：bank 为银行名，name 为卡片名称；返回值：资源名及原图裁切比例，未知银行、模糊卡种或不同等级返回 nil。
    static func preset(bank: String, name: String) -> (file: String, crop: CGRect)? {
        guard bank.contains("招商") || bank.contains("招行") else { return nil }
        let key = name.lowercased()
        if key.contains("皮卡丘") || key.contains("pikachu") || (key.contains("宝可梦") && !key.contains("家族")) {
            return ("CardArtCMBPikachu.jpg", CGRect(x: 0.018, y: 0.018, width: 0.964, height: 0.963))
        }
        if key.contains("初音未来") || key.contains("hatsune miku") {
            return ("CardArtCMBMiku.png", CGRect(x: 0.595, y: 0.576, width: 0.307, height: 0.235))
        }
        if (key.contains("全币") || key.contains("全幣")) && !["master", "万事达", "jcb", "运通", "白金", "留学"].contains(where: { key.contains($0) }) {
            return ("CardArtCMBVisa.png", CGRect(x: 0, y: 0, width: 1, height: 0.503))
        }
        if key.contains("百夫长") && key.contains("金卡") && !key.contains("白金") && !key.contains("黑金") {
            return ("CardArtCMBAmex.jpg", CGRect(x: 0.244, y: 0.456, width: 0.142, height: 0.156))
        }
        return nil
    }
    #if canImport(UIKit)
    /// 读取并裁切已核验素材；参数：bank 为银行名，name 为卡种名；返回值：纯卡面图片或 nil；裁切移除宣传文字与倒影，不联网、不修改原始素材。
    static func presetImage(bank: String, name: String) -> UIImage? {
        guard let preset = preset(bank: bank, name: name), let url = Bundle.main.url(forResource: preset.file, withExtension: nil),
              let source = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let rect = CGRect(x: preset.crop.minX * CGFloat(source.width), y: preset.crop.minY * CGFloat(source.height), width: preset.crop.width * CGFloat(source.width), height: preset.crop.height * CGFloat(source.height)).integral
        guard let cropped = source.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
    #endif
    /// 构建公开搜索词；参数：bank 为银行名，name 为卡种名；返回值：去除连续数字后的有限长度搜索词，避免名称中误填卡号被外发。
    static func query(bank: String, name: String) -> String {
        let text = bank + " " + name
        return String(text.replacingOccurrences(of: #"[0-9\s-]{4,}"#, with: " ", options: .regularExpression).prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 解析 HTML 实体；参数：text 为搜索页属性；返回值：常用实体解码后的文本，不执行网页代码。
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
    /// 验证远程图片地址；参数：text 为外部 URL；返回值：公共 HTTPS 地址或 nil，拒绝本机、私网和带凭据地址。
    static func publicURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.contains("."), !host.hasSuffix(".local"), host != "localhost",
              host.range(of: #"^[0-9.:]+$"#, options: .regularExpression) == nil else { return nil }
        return url
    }
    /// 解析公开搜索页候选；参数：html 为有限大小页面；返回值：最多 12 个去重 HTTPS 图片，页面结构变化时返回空列表。
    static func candidates(html: String) -> [CardArtworkCandidate] {
        var result: [CardArtworkCandidate] = []
        let pattern = #"\bm="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html), let data = unescape(String(html[range])).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["murl"] as? String, let url = publicURL(raw), !result.contains(where: { $0.imageURL == url }) else { continue }
            result.append(CardArtworkCandidate(imageURL: url, sourceURL: (object["purl"] as? String).flatMap(publicURL), title: unescape(object["t"] as? String ?? "卡面")))
            if result.count == 12 { break }
        }
        return result
    }
    /// 下载有上限的公开资源；参数：url 为 HTTPS 地址，limit 为字节上限；返回值：数据；超时、非成功状态或超限抛错，无认证 Cookie。
    static func fetch(_ url: URL, limit: Int) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= limit else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }
    /// 根据公开名称联网搜索；参数：query 为已清理卡种词；返回值：候选卡面；搜索不可用或无结果时抛错，不影响财务保存。
    static func search(_ query: String) async throws -> [CardArtworkCandidate] {
        // 招行公开产品页提供卡名与图片对应关系；优先读取官方目录，不依赖搜索结果排名猜卡面。
        if query.contains("招商") || query.contains("招行") {
            let source = URL(string: "https://market.cmbchina.com/ccard/xkyxk/index.html")!
            if let data = try? await fetch(source, limit: 2 * 1024 * 1024) {
                let values = officialCandidates(html: String(decoding: data, as: UTF8.self), source: source)
                    .filter { matches(title: $0.title, name: query) }
                if !values.isEmpty { return values }
            }
        }
        var url = URLComponents(string: "https://www.bing.com/images/search")!
        url.queryItems = [URLQueryItem(name: "q", value: query + " 信用卡 卡面"), URLQueryItem(name: "adlt", value: "strict")]
        let data = try await fetch(url.url!, limit: 2 * 1024 * 1024)
        let values = candidates(html: String(decoding: data, as: UTF8.self))
        guard !values.isEmpty else { throw NSError(domain: "CardArtwork", code: 1, userInfo: [NSLocalizedDescriptionKey: "暂未找到卡面，可从相册选择"] ) }
        return values
    }
    /// 判断是否允许自动采用；参数：candidate 为候选，name 为卡种，bank 为银行名称；返回值：对应银行官方来源且标题含卡种时为 true，泛称不自动猜选。
    static func automatic(_ candidate: CardArtworkCandidate, name: String, bank: String) -> Bool {
        let domains = ["招商": "cmbchina.com", "建设": "ccb.com", "工商": "icbc.com.cn", "农业": "abchina.com", "中国银行": "boc.cn", "交通": "bankcomm.com", "兴业": "cib.com.cn", "光大": "cebbank.com", "中信": "citicbank.com", "民生": "cmbc.com.cn", "平安": "pingan.com", "邮政": "psbc.com"]
        guard let host = candidate.sourceURL?.host?.lowercased(), domains.contains(where: { bank.contains($0.key) && (host == $0.value || host.hasSuffix("." + $0.value)) }) else { return false }
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 3 && matches(title: candidate.title, name: key)
    }
    /// 规范化卡种关键词；参数：value 为名称；返回值：移除通用银行、卡片措辞及空白的关键词，不推断具体版本。
    static func productKey(_ value: String) -> String {
        var text = value.lowercased().replacingOccurrences(of: "哔哩哔哩", with: "bilibili").replacingOccurrences(of: "b站", with: "bilibili")
        for word in ["招商银行", "招行", "信用账户", "信用卡", "联名", "（", "）", "(", ")", " "] { text = text.replacingOccurrences(of: word, with: "") }
        return text
    }
    /// 判断名称是否为同一卡种；参数：title 为公开标题，name 为用户卡种；返回值：完整规范化卡种一致或标题包含该卡种时为 true。
    static func matches(title: String, name: String) -> Bool {
        let key = productKey(name)
        return key.count >= 3 && productKey(title).contains(key)
    }
    /// 解析招行官方产品卡面；参数：html 为公开页面，source 为来源 URL；返回值：页面中明确对应卡名的图片，不使用广告背景。
    static func officialCandidates(html: String, source: URL) -> [CardArtworkCandidate] {
        guard let regex = try? NSRegularExpression(pattern: #"<img src="(images/pagecontent-main-row[^"]+)"[^>]*>[\s\S]{0,400}?<h6>([^<]+)</h6>"#) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let imageRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html),
                  let url = URL(string: String(html[imageRange]), relativeTo: source)?.absoluteURL else { return nil }
            return CardArtworkCandidate(imageURL: url, sourceURL: source, title: unescape(String(html[titleRange])).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    #if canImport(UIKit)
    /// 下载并规范化卡面；参数：candidate 为候选，automatic 表示是否要求卡片横纵比；返回值：剔除元数据后的 JPEG，尺寸不合适时抛错。
    @MainActor static func download(_ candidate: CardArtworkCandidate, automatic: Bool = false) async throws -> Data {
        let raw = try await fetch(candidate.imageURL, limit: 5 * 1024 * 1024)
        let data = try PaymentImageProcessor.normalizedImage(raw)
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        let ratio = image.size.width / image.size.height
        if automatic && !(1.3...1.95).contains(ratio) { throw URLError(.cannotDecodeContentData) }
        return data
    }
    #endif
    /// 生成账号隔离的缓存文件位置；参数：key 为账号空间与卡片组合键；返回值：应用支持目录文件 URL，创建目录失败抛错。
    static func file(_ key: String) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CardArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    /// 读取卡面缓存；参数：key 为账号隔离键；返回值：已保存卡面或 nil，不联网。
    static func load(_ key: String) -> SavedCardArtwork? {
        guard let url = try? file(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedCardArtwork.self, from: data)
    }
    /// 原子保存卡面；参数：value 为图片及手动选择标志，key 为隔离键；返回值：无；落盘失败抛错，图片只保存在本机。
    static func save(_ value: SavedCardArtwork, key: String) throws {
        try JSONEncoder().encode(value).write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
