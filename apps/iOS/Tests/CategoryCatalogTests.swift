import Foundation
import AppKit

@main
struct CategoryCatalogTests {
    /// 验证旧分类解码、归组与自定义字段优先级；参数：无；返回值：无，断言失败使进程退出，解码失败抛出错误。
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
        // SF Symbols 名称无效不会导致编译失败，加载每个图标防止界面出现空白。
        for group in CategoryCatalog.groups {
            for symbol in [group.icon] + group.items.map(\.icon) {
                precondition(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "无效分类图标：\(symbol)")
            }
        }
        print("Category catalog tests passed")
    }
}
