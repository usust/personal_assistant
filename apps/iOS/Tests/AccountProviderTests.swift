import Foundation

extension CoreTests {
    /// 验证官方目录完整性与历史／信用账户兼容；参数：无；返回值：无；失败终止测试，不连接真实 API。
    @MainActor static func checkAccountProviders() throws {
        check(AccountProvider.catalog?.bankCount == 3253, "加载打包的完整官方银行目录")
        check(AccountProvider.catalog?.asOf == "2025-12-31", "目录明确官方截止日期")
        check(AccountKindCatalog.bundled?.sections.count == 6 && AccountKindCatalog.bundled?.items.count == 66, "六类账户与 Web 共用 66 项目录")
        for kind in AccountKindCatalog.bundled?.items.filter({ $0.route.isEmpty }) ?? [] {
            let restored = AccountProvider.resolve(type: kind.type, institution: kind.institution)
            check(restored.id == kind.id && restored.icon == kind.icon && restored.isCredit == kind.isCredit, "用途类型保存重开保持一致：\(kind.name)")
        }
        let expected: [AccountProviderGroup: Int] = [.national: 6, .jointStock: 12, .city: 123, .digital: 20,
            .ruralCommercial: 1398, .ruralCooperative: 18, .ruralCredit: 336, .village: 1177, .mutual: 4,
            .foreign: 41, .foreignBranch: 114, .policy: 3, .housing: 1]
        for (group, count) in expected {
            check(AccountProvider.all.filter { $0.group == group }.count == count, "官方类别完整：\(group.title)")
        }
        check(AccountProvider.selectableBanks.count == 161, "精简选择范围保留 161 家银行")
        check(Set(AccountProvider.selectable.map(\.group)) == Set([.national, .jointStock, .digital, .city, .wallet, .credit, .other]), "分类、搜索与信用卡共用保留范围")
        let removedBank = AccountProvider.all.first { $0.group == .ruralCommercial }!
        check(!AccountProvider.selectable.contains { $0.id == removedBank.id } && AccountProvider.resolve(type: "bank", institution: removedBank.institution).id == removedBank.id, "移除选择项后仍可解析历史账户")
        let nanjing = AccountProvider.resolve(type: "bank", institution: "南京银行")
        check(nanjing.matches("nanjing") && nanjing.matches("njyh") && nanjing.matches("南京 江苏"), "支持全拼、首字母和多词地区搜索")
        for name in ["微众银行", "网商银行", "新网银行", "百信银行"] {
            let bank = AccountProvider.resolve(type: "bank", institution: name)
            check(bank.group == .digital && bank.id.hasPrefix("nfra-"), "网络银行能匹配：\(name)")
        }
        check(AccountProvider.resolve(type: "bank", institution: "长沙银行").matches("csyh"), "长沙地名首字母读音正确")
        check(AccountProvider.resolve(type: "bank", institution: "厦门银行").matches("xmyh"), "厦门地名首字母读音正确")
        let card = nanjing.creditCard()
        let restored = AccountProvider.resolve(type: card.type, institution: card.institution)
        check(card.type == "bank" && restored.id == card.id && restored.isCredit, "信用卡用现有 API 类型保存并恢复")
        check(card.creditCard() == card, "信用卡标记不会重复追加")
        for name in ["花呗", "京东白条", "借呗", "京东金条", "微粒贷"] {
            let provider = AccountProvider.resolve(type: "other", institution: name)
            check(provider.isCredit && provider.group == .credit, "平台信用账户能恢复：\(name)")
        }
        let custom = AccountProvider.custom(name: "  家乡信用合作社  ", type: "bank", credit: false)!
        check(custom.institution == "家乡信用合作社", "自定义机构去除边缘空白")
        let customCredit = AccountProvider.custom(name: "我的月付", type: "other", credit: true)!
        check(AccountProvider.resolve(type: "other", institution: customCredit.institution).isCredit, "自定义信用账户重新打开保留属性")
        check(AccountProvider.custom(name: " ", type: "bank", credit: false) == nil, "拒绝空机构")
        check(AccountProvider.custom(name: String(repeating: "银", count: 43), type: "bank", credit: false) == nil, "按 UTF-8 字节限制名称")
        check(AccountProvider.custom(name: "钱包", type: "cash", credit: true) == nil, "不允许无效自定义账户类型")
        check(AccountProvider.all.allSatisfy { $0.institution.utf8.count <= 128 && $0.name.utf8.count <= 128 }, "完整目录符合接口长度约束")
        // 错误资源必须显式失败，不能以部分目录继续冒充全部机构。
        let bad = Data(#"{"asOf":"2025-12-31","bankCount":3253,"providers":[]}"#.utf8)
        do {
            _ = try AccountProviderCatalog.decode(bad)
            check(false, "损坏目录不应解码成功")
        } catch { check(true, "损坏目录被拒绝") }
    }
}
