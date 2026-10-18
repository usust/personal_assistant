import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@main
struct CategoryCatalogTests {
    /// 验证旧分类解码、归组、自定义字段优先级及全量图标库；参数：无；返回值：无，断言失败使进程退出，解码失败抛出错误；Apple 平台同时验证系统符号实际可加载。
    static func main() throws {
        let old = try JSONDecoder().decode(TransactionCategory.self, from: Data(##"{"id":1,"name":"生活缴费","type":"expense","color":"#14B8A6"}"##.utf8))
        precondition(CategoryCatalog.group(for: old).id == "utilities")
        let custom = TransactionCategory(id: 2, name: "我的咖啡", type: "expense", color: "#14B8A6", groupKey: "food", icon: "cup.and.saucer")
        precondition(CategoryCatalog.group(for: custom).id == "food")
        precondition(CategoryCatalog.icon(for: custom) == "cup.and.saucer")
        let unknown = TransactionCategory(id: 3, name: "自定义旧收入", type: "income", color: "#14B8A6")
        precondition(CategoryCatalog.group(for: unknown).id == "other-income")
        let wrong = TransactionCategory(id: 4, name: "自定义收入", type: "income", color: "#14B8A6", groupKey: "food")
        precondition(CategoryCatalog.group(for: wrong).type == "income")
        for type in ["income", "expense"] {
            let groups = CategoryCatalog.groups(for: type)
            let names = groups.flatMap { $0.items.map(\.name) }
            precondition(Set(names).count == names.count, "同一收支类型不能有重复推荐项")
            precondition(groups.allSatisfy { !$0.items.isEmpty && !$0.icon.isEmpty })
        }
        // 新目录必须保留旧名称归属，显式选用的新分组则优先采用持久化字段。
        let legacyClothing = TransactionCategory(id: 5, name: "服饰", type: "expense", color: "#D57FA6")
        precondition(CategoryCatalog.group(for: legacyClothing).id == "shopping")
        let newClothing = TransactionCategory(id: 6, name: "服饰", type: "expense", color: "#D57FA6", groupKey: "clothing")
        precondition(CategoryCatalog.group(for: newClothing).id == "clothing")
        let invalidType = TransactionCategory(id: 7, name: "未知", type: "unknown", color: "#D57FA6")
        precondition(CategoryCatalog.group(for: invalidType).id == "other-expense")
        precondition(Set(CategoryCatalog.groups.map(\.id)).count == CategoryCatalog.groups.count)
        // 图标库包含全部现有目录和推荐项，不允许为了增加数量重复堆叠同一个符号。
        let library = CategoryCatalog.iconLibrary
        let symbols = Set(library.map(\.symbol))
        precondition(library.count >= 120, "分类图标至少 120 项")
        precondition(symbols.count == library.count, "图标库必须去重")
        precondition(CategoryCatalog.icons().map(\.symbol) == library.map(\.symbol))
        precondition(CategoryCatalog.icons(groupID: "").map(\.symbol) == library.map(\.symbol))
        precondition(CategoryCatalog.icons(matching: " \n ").count == library.count)
        precondition(CategoryCatalog.icons(groupID: "unknown").isEmpty)
        precondition(CategoryCatalog.icons(matching: "不存在的图标搜索词").isEmpty)
        for group in CategoryCatalog.groups {
            let grouped = CategoryCatalog.icons(groupID: group.id)
            let groupedSymbols = Set(grouped.map(\.symbol))
            precondition(groupedSymbols.count == grouped.count, "分组内图标必须去重")
            precondition(grouped.allSatisfy { $0.groupIDs.contains(group.id) })
            for symbol in [group.icon] + group.items.map(\.icon) {
                precondition(symbols.contains(symbol), "图标库遗漏目录符号：\(symbol)")
                precondition(groupedSymbols.contains(symbol), "分组遗漏目录符号：\(group.id)/\(symbol)")
            }
        }
        // 同一图标的多个中文用途必须都可搜索，分组筛选不得丢失共享符号。
        precondition(CategoryCatalog.icons(matching: "咖啡").contains { $0.symbol == "cup.and.saucer" })
        precondition(CategoryCatalog.icons(matching: "奶茶").contains { $0.symbol == "cup.and.saucer.fill" })
        precondition(CategoryCatalog.icons(matching: "餐饮 早餐").contains { $0.symbol == "sunrise" })
        precondition(CategoryCatalog.icons(groupID: "home", matching: "房租").contains { $0.symbol == "house" })
        precondition(CategoryCatalog.icons(groupID: "insurance", matching: "财产保险").contains { $0.symbol == "house" })
        precondition(CategoryCatalog.icons(groupID: "salary", matching: "收入").contains { $0.symbol == "briefcase" })
        // 餐具同时用于餐饮与工资餐补，共享用途关键词应合并；不共享的工资外币仍被餐饮筛选排除。
        precondition(CategoryCatalog.icons(groupID: "food", matching: "工资").contains { $0.symbol == "fork.knife" })
        precondition(CategoryCatalog.icons(groupID: "food", matching: "外币").isEmpty)
        // 收入弹窗默认范围覆盖真实收入来源，共享图标可跨收支搜索，但目录筛选不能越界。
        let income = CategoryCatalog.icons(type: "income")
        let incomeGroups = Set(CategoryCatalog.groups(for: "income").map(\.id))
        precondition(income.count >= 90, "收入图标应覆盖咨询、创作、经营、投资及补助等来源")
        precondition(income.allSatisfy { !incomeGroups.isDisjoint(with: $0.groupIDs) })
        precondition(CategoryCatalog.icons(type: "").map(\.symbol) == library.map(\.symbol))
        precondition(CategoryCatalog.icons(type: "unknown").isEmpty)
        precondition(CategoryCatalog.icons(groupID: "food", type: "income").isEmpty)
        precondition(CategoryCatalog.icons(matching: "专家咨询", type: "income").contains { $0.symbol == "person.crop.square" })
        precondition(CategoryCatalog.icons(matching: "收入 写作稿酬", type: "income").contains { $0.symbol == "doc.text" })
        precondition(CategoryCatalog.icons(matching: "政府补助", type: "income").contains { $0.symbol == "building.columns.fill" })
        precondition(CategoryCatalog.icons(matching: "房屋租金", type: "income").contains { $0.symbol == "house.lodge" })
        precondition(CategoryCatalog.icons(groupID: "side-job", matching: "摄影", type: "income").contains { $0.symbol == "camera.aperture" })
        precondition(CategoryCatalog.icons(groupID: "daily", matching: "肥皂").contains { $0.symbol == "bubbles.and.sparkles" })
        precondition(CategoryCatalog.icons(matching: "  CUP.AND.SAUCER  ").contains { $0.symbol == "cup.and.saucer" })
        precondition(CategoryCatalog.iconName(for: "cup.and.saucer") == "咖啡")
        precondition(CategoryCatalog.iconName(for: "doc.text", type: "income") == "写作稿酬")
        precondition(CategoryCatalog.iconName(for: "fork.knife", type: "income") == "餐补")
        precondition(CategoryCatalog.iconName(for: "custom.saved.symbol", type: "income") == "自定义图标")
        precondition(CategoryCatalog.iconName(for: "custom.saved.symbol") == "自定义图标")
        // 库外已保存图标继续使用原始值，搜索和浏览不改变分类的持久化外观。
        let saved = TransactionCategory(id: 8, name: "个性分类", type: "expense", color: "#123456", groupKey: "food", icon: "heart.circle")
        precondition(CategoryCatalog.icon(for: saved) == "heart.circle")
        for option in library {
            precondition(option.id == option.symbol)
            precondition(option.name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "图标缺少中文可访问名：\(option.symbol)")
            precondition(!option.keywords.isEmpty && !option.groupIDs.isEmpty)
            precondition(option.groupIDs.allSatisfy { id in CategoryCatalog.groups.contains { $0.id == id } })
            precondition(option.symbol.range(of: #"\A[a-z][a-z0-9.]{0,63}\z"#, options: .regularExpression) != nil)
            validateSymbol(option.symbol)
        }
        #if !canImport(AppKit) && !canImport(UIKit)
        print("SF Symbols 加载验证需在 Apple 平台执行")
        #endif
        print("Category catalog tests passed (\(library.count) unique icons)")
    }

    /// 验证系统符号可加载；参数：symbol 为目录中的 SF Symbols 名称；返回值：无，Apple 平台加载失败即断言失败，Linux 仅运行其余目录及搜索测试。
    private static func validateSymbol(_ symbol: String) {
        #if canImport(AppKit)
        precondition(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "无效分类图标：\(symbol)")
        #elseif canImport(UIKit)
        precondition(UIImage(systemName: symbol) != nil, "无效分类图标：\(symbol)")
        #endif
    }
}
