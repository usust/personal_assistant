import Foundation

/// 展示分类独立于服务端账户类型；网络银行按产品查找习惯与民营、直销银行放在同一入口。
enum AccountProviderGroup: String, Codable, CaseIterable, Identifiable {
    case national, jointStock, digital, city, ruralCommercial, ruralCooperative, ruralCredit, village, mutual
    case foreign, foreignBranch, policy, housing, wallet, credit, other

    // 用户保留的选择范围；被移除类别仅用于历史账户解析，不再出现在分类、搜索或信用卡机构列表中。
    static let selectable: [AccountProviderGroup] = [.national, .jointStock, .digital, .city, .wallet, .credit, .other]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .national: "国有大型银行"
        case .jointStock: "全国股份制银行"
        case .digital: "网络与民营银行"
        case .city: "城市商业银行"
        case .ruralCommercial: "农村商业银行"
        case .ruralCooperative: "农村合作银行"
        case .ruralCredit: "农村信用社与联合社"
        case .village: "村镇银行"
        case .mutual: "农村资金互助社"
        case .foreign: "外资法人银行"
        case .foreignBranch: "外国及港澳台银行内地分行"
        case .policy: "政策性与开发性银行"
        case .housing: "住房储蓄银行"
        case .wallet: "支付钱包"
        case .credit: "平台信用与借款账户"
        case .other: "现金、储蓄与投资"
        }
    }
    var symbol: String {
        switch self {
        case .digital: "network"
        case .wallet: "wallet.bifold"
        case .credit: "creditcard"
        case .other: "banknote"
        default: "building.columns"
        }
    }
}

/// 官方目录快照，完整性信息随资源一并打包，便于离线核对和展示截止日期。
struct AccountProviderCatalog: Decodable {
    let asOf: String
    let bankCount: Int
    let providers: [AccountProvider]

    /// 解码并校验目录；参数：data 为本地资源 JSON；返回值：通过唯一性、字段与数量检查的快照；格式错误时抛错，无副作用。
    static func decode(_ data: Data) throws -> AccountProviderCatalog {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.bankCount > 0,
              result.providers.filter({ $0.type == "bank" }).count == result.bankCount,
              Set(result.providers.map(\.id)).count == result.providers.count,
              result.providers.allSatisfy({ !$0.name.isEmpty && !$0.institution.isEmpty && $0.institution.utf8.count <= 128 && !$0.searchKey.isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
}

/// 机构选项同时承载展示分类和持久化字段；不向服务器提交目录本地元数据。
struct AccountProvider: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let type: String
    let institution: String
    let icon: String
    let aliases: [String]
    var group: AccountProviderGroup = .other
    var region: String = ""
    var regulatoryType: String = ""
    var isCredit: Bool = false
    var searchKey: String = ""

    /// 加载打包快照；参数：无；返回值：有效目录或 nil；读取本地资源，失败由界面显示，不以部分目录冒充全部。
    static let catalog: AccountProviderCatalog? = {
        guard let url = Bundle.main.url(forResource: "AccountProviders", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? AccountProviderCatalog.decode(data)
    }()
    static let all: [AccountProvider] = catalog?.providers ?? []
    static let selectable = all.filter { AccountProviderGroup.selectable.contains($0.group) }
    static let selectableBanks = selectable.filter { $0.type == "bank" }
    static let defaultBank = selectable.first { $0.name == "招商银行" } ?? generic(type: "bank")
    static let common = selectable.filter { ["招商银行", "中国工商银行", "中国建设银行", "中国农业银行", "中国银行", "中国邮政储蓄银行"].contains($0.name) }
    private static let creditCardSuffix = "（信用卡）"
    private static let creditAccountSuffix = "（信用账户）"

    /// 初始化精确别名索引；参数：无；返回值：类型与名称对应的机构字典；无外部副作用，同名按官方目录顺序优先，避免行渲染重复扫描。
    private static let lookup: [String: AccountProvider] = {
        var values: [String: AccountProvider] = [:]
        for provider in all {
            for name in [provider.name, provider.institution] + provider.aliases {
                let key = provider.type + "|" + normalized(name)
                if values[key] == nil { values[key] = provider }
            }
        }
        return values
    }()

    /// 获取类型默认展示；参数：type 为已有服务端类型，未知类型原样保留；返回值：通用图标选项；无副作用。
    static func generic(type: String) -> AccountProvider {
        let names = ["bank": "银行卡", "alipay": "支付宝", "wechat": "微信支付", "cash": "现金", "savings": "储蓄账户", "investment": "投资账户", "other": "其他账户"]
        let icons = ["bank": "bank", "alipay": "alipay", "wechat": "wechat", "cash": "cash", "savings": "savings", "investment": "investment"]
        return AccountProvider(id: "generic-" + type, name: names[type] ?? "其他账户", type: type,
                               institution: "", icon: icons[type] ?? "wallet", aliases: [])
    }

    /// 规范搜索文本；参数：value 为任意输入；返回值：去空白、大小写和重音后的文本；无副作用。
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .lowercased().filter { !$0.isWhitespace }
    }

    /// 解析已有账户；参数：type 为服务端类型，institution 为原始机构名称；返回值：带原始持久化值的选项，信用标记可恢复；无副作用，不自动迁移历史字段。
    static func resolve(type: String, institution: String) -> AccountProvider {
        // 用途目录优先精确匹配，保证充值、理财、应收应付在跨端重新打开时恢复图标与含义。
        if let kind = AccountKindCatalog.bundled?.items.first(where: { item in
            item.route.isEmpty && item.type == type && ([item.institution, item.name] + item.aliases).contains { normalized($0) == normalized(institution) }
        }) { return kind.provider.preserving(institution) }
        if type == "bank", institution.hasSuffix(creditCardSuffix) {
            let bank = resolve(type: type, institution: String(institution.dropLast(creditCardSuffix.count)))
            return bank.creditCard().preserving(institution)
        }
        if type == "other", institution.hasSuffix(creditAccountSuffix) {
            let name = String(institution.dropLast(creditAccountSuffix.count))
            return AccountProvider(id: "custom-credit-" + institution, name: name, type: type, institution: institution,
                                   icon: "credit-card", aliases: [], group: .credit, isCredit: true)
        }
        if let match = lookup[type + "|" + normalized(institution)] { return match.preserving(institution) }
        let fallback = generic(type: type)
        return AccountProvider(id: "existing-\(type)-\(institution)", name: institution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback.name : institution,
                               type: type, institution: institution, icon: fallback.icon, aliases: [], group: fallback.group)
    }

    /// 保留服务器原值；参数：value 为未规范化的机构字段；返回值：只替换持久化字段的副本；无副作用。
    private func preserving(_ value: String) -> AccountProvider {
        AccountProvider(id: id, name: name, type: type, institution: value, icon: icon, aliases: aliases,
                        group: group, region: region, regulatoryType: regulatoryType, isCredit: isCredit, searchKey: searchKey)
    }

    /// 将用户已有银行卡标记为信用卡；参数：无，接收者应为银行；返回值：带可恢复信用标记的选项；不代表机构实际发行信用卡，不调用授信接口。
    func creditCard() -> AccountProvider {
        guard type == "bank", !isCredit else { return self }
        // 超长正式名称回退到显示简称，最终仍由表单按服务端 128 字节上限校验。
        let marked = institution + Self.creditCardSuffix
        return AccountProvider(id: "credit-" + id, name: name + "信用卡", type: "bank",
                               institution: marked.utf8.count <= 128 ? marked : name + Self.creditCardSuffix,
                               icon: icon, aliases: aliases, group: .credit, region: region, isCredit: true, searchKey: searchKey)
    }

    /// 构造自定义机构；参数：name 非空且持久化后最多 128 UTF-8 字节，type 仅限 bank/alipay/wechat/other/investment，credit 表示信用账户；返回值：有效选项或 nil；不写公共目录。
    static func custom(name: String, type: String, credit: Bool) -> AccountProvider? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["bank", "alipay", "wechat", "other", "investment"].contains(type), !value.isEmpty else { return nil }
        let stored = value + (credit ? (type == "bank" ? creditCardSuffix : creditAccountSuffix) : "")
        guard stored.utf8.count <= 128, !credit || type == "bank" || type == "other" else { return nil }
        let baseline = generic(type: type)
        return AccountProvider(id: "custom-\(type)-\(stored)", name: value, type: type, institution: stored,
                               icon: credit ? "credit-card" : baseline.icon, aliases: [], group: credit ? .credit : .other, isCredit: credit)
    }

    /// 搜索名称、别名、英文、拼音或首字母；参数：query 可含多词，空白匹配全部；返回值：是否每个词均命中；无副作用。
    func matches(_ query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { Self.normalized(String($0)) }
        let key = searchKey.isEmpty ? Self.normalized(([name, institution, region] + aliases).joined()) : searchKey
        return tokens.allSatisfy { key.contains($0) }
    }
}
