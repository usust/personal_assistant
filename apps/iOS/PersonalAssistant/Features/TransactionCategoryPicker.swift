import SwiftUI

/// 所有记账分类选择共用的图标网格及底部子分类面板，选择只修改调用方草稿。
struct TransactionCategoryPicker: View {
    let type: String
    @Binding var categoryID: Int
    @Binding var categoryTemplate: (group: CategoryGroup, item: CategoryTemplate)?
    /// 参数和返回值均无；选择完成时通知调用方处理草稿或解析分类。
    var onSelection: () -> Void = {}
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var choosingGroup: CategoryGroup?
    @AppStorage("transactionCategoryListLayout") private var categoryListLayout = false
    /// 获取分类强调色；参数：无；返回值：支出珊瑚红，收入青绿色。
    private var entryColor: Color { type == "expense" ? Color(red: 0.96, green: 0.37, blue: 0.31) : .teal }
    /// 构建统一选择器；参数：无；返回值：圆形图标网格、下级标记及支持列表切换的底部子分类面板。
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 100 : 62), spacing: 10)], spacing: 12) {
            // 使用分类管理的同一一级目录；点击分组后选择已添加分类或目录推荐项。
            ForEach(CategoryCatalog.groups(for: type)) { group in
                Button { selectGroup(group) } label: {
                    categoryLabel(name: group.name, symbol: group.icon, selected: selectedCategoryGroup == group.id, hasChildren: hasSubcategories(group))
                }.buttonStyle(.plain).accessibilityAddTraits(selectedCategoryGroup == group.id ? .isSelected : [])
            }
            NavigationLink { CategoriesView() } label: {
                VStack(spacing: 5) {
                    Image(systemName: "plus").font(.title3).frame(width: 36, height: 36)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                    Text("管理分类").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    .sheet(item: $choosingGroup) { group in
        categoryChoices(group)
            .presentationDetents([.fraction(0.4)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationCompactAdaptation(.sheet)
    }
    }
    /// 判断分组是否有下级；参数：group 为一级目录；返回值：有推荐子项或非同名已添加分类时为 true，无副作用。
    private func hasSubcategories(_ group: CategoryGroup) -> Bool {
        !group.items.isEmpty || store.categories.contains { $0.type == group.type && CategoryCatalog.group(for: $0).id == group.id && $0.name != group.name }
    }
    /// 选择一级分类；参数：group 为点击目录；返回值：无；有下级打开底部选择器，无下级直接暂存对应分类。
    private func selectGroup(_ group: CategoryGroup) {
        if hasSubcategories(group) { choosingGroup = group }
        else if let category = store.categories.first(where: { $0.type == group.type && CategoryCatalog.group(for: $0).id == group.id }) { categoryID = category.id; categoryTemplate = nil }
        else { categoryID = 0; categoryTemplate = (group, CategoryTemplate(name: group.name, icon: group.icon)) }
        if !hasSubcategories(group) { onSelection() }
    }
    /// 返回选中分类对应的一级目录；参数：无；返回值：分类管理的分组 ID，未分类返回 nil。
    private var selectedCategoryGroup: String? {
        if let categoryTemplate { return categoryTemplate.group.id }
        guard let category = store.categories.first(where: { $0.id == categoryID }) else { return nil }
        return CategoryCatalog.group(for: category).id
    }
    /// 构建统一分类图标；参数：name 为名称，symbol 为系统图标，selected 为选中状态，hasChildren 表示有下级分类；返回值：圆形图标、下级标记和名称，无副作用。
    private func categoryLabel(name: String, symbol: String, selected: Bool, hasChildren: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 36, height: 36)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? entryColor : Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    if hasChildren {
                        Image(systemName: "ellipsis").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(uiColor: .secondarySystemGroupedBackground))
                            .frame(width: 13, height: 13).background(Color.primary, in: Circle()).offset(x: 2, y: 1)
                    }
                }
            Text(name).font(.caption).foregroundStyle(selected ? entryColor : .primary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 58, alignment: .top)
    }
    /// 展示底部分类选择面板；参数：group 为当前收支的一级分组；返回值：默认横向网格、可切换列表的半屏内容，选择只暂存草稿且不离开记账页。
    private func categoryChoices(_ group: CategoryGroup) -> some View {
        // 过滤回调接收已有分类或目录项，返回所属分组或是否尚未添加，口径与分类管理一致。
        let existing = store.categories.filter { $0.type == group.type && CategoryCatalog.group(for: $0).id == group.id }
        let suggested = group.items.filter { item in !store.categories.contains { $0.type == group.type && $0.name == item.name } }
        let choices = Group {
            ForEach(existing) { category in
                // 选择回调无参数、无返回值；保存真实 ID 并收起底部面板，保留其他记账草稿。
                categoryChoice(name: category.name, symbol: CategoryCatalog.icon(for: category), selected: categoryID == category.id && categoryTemplate == nil) {
                    categoryID = category.id; categoryTemplate = nil; choosingGroup = nil; onSelection()
                }
            }
            ForEach(suggested) { item in
                // 选择回调无参数、无返回值；推荐项只暂存，保存本笔记账时才解析真实分类。
                categoryChoice(name: item.name, symbol: item.icon, selected: categoryTemplate?.group.id == group.id && categoryTemplate?.item.name == item.name) {
                    categoryID = 0; categoryTemplate = (group, item); choosingGroup = nil; onSelection()
                }
            }
        }
        return VStack(spacing: 0) {
            HStack {
                // 关闭与布局切换回调均无参数、无返回值；关闭不改草稿，切换只保存本机显示偏好。
                Button { choosingGroup = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭分类选择")
                Spacer()
                Text(group.name).font(.headline)
                Spacer()
                Button { categoryListLayout.toggle() } label: {
                    Image(systemName: categoryListLayout ? "square.grid.3x3" : "list.bullet").frame(width: 44, height: 44)
                }.accessibilityLabel(categoryListLayout ? "切换图标网格" : "切换列表")
            }.foregroundStyle(.primary).buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 12)
            ScrollView {
                if categoryListLayout {
                    LazyVStack(spacing: 0) { choices }.padding(.horizontal, 16)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 100 : 62), spacing: 10)], spacing: 18) { choices }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Color(uiColor: .secondarySystemGroupedBackground))
    }
    /// 构建子分类选择项；参数：name 为名称，symbol 为图标，selected 为当前选择，action 为无参数无返回值的草稿选择回调；返回值：列表行或横排网格单元，无直接网络写入。
    private func categoryChoice(name: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if categoryListLayout {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(entryColor, in: Circle())
                        Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.subheadline)
                            .foregroundStyle(.secondary)
                    }.frame(minHeight: 64).contentShape(Rectangle())
                    Divider()
                }
            } else {
                categoryLabel(name: name, symbol: symbol, selected: selected)
            }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
