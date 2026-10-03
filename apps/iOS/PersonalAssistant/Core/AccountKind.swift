import Foundation

/// 跨端共享的用途分组和产品类型，银行选择仍限定用户保留的 161 家。
struct AccountKindCatalog: Decodable {
    struct Section: Decodable, Identifiable { let id: String; let title: String }
    let sections: [Section]
    let items: [AccountKind]

    /// 加载共享类型目录；参数：无；返回值：目录或 nil；只读本地资源，失败由选择页提示。
    static let bundled: AccountKindCatalog? = {
        guard let url = Bundle.main.url(forResource: "AccountKinds", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()
}

struct AccountKind: Decodable, Identifiable {
    let id: String
    let name: String
    let section: String
    let type: String
    let institution: String
    let icon: String
    let aliases: [String]
    let isCredit: Bool
    let route: String

    /// 转换为现有账户接口选项；参数：无；返回值：不携带新服务端字段的机构选项；无副作用。
    var provider: AccountProvider {
        AccountProvider(id: id, name: name, type: type, institution: institution, icon: icon, aliases: aliases,
                        group: isCredit ? .credit : type == "alipay" || type == "wechat" ? .wallet : .other, isCredit: isCredit)
    }
}
