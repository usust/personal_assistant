import SwiftUI
import UIKit

struct CategoriesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .subheadline) private var groupFontSize: CGFloat = 15
    @State private var type = "expense"
    @State private var selectedGroup = "food"
    @State private var draft: CategoryDraft?
    @State private var error: String?

    /// 当前分组；参数：无；返回值：选中分组或当前收支类型的首项。
    private var group: CategoryGroup {
        CategoryCatalog.groups(for: type).first { $0.id == selectedGroup } ?? CategoryCatalog.groups(for: type)[0]
    }
    /// 当前分组已有分类；参数：无；返回值：真实保存的分类，不包含目录模板。
    private var categories: [TransactionCategory] {
        store.categories.filter { $0.type == type && CategoryCatalog.group(for: $0).id == group.id }
    }
    /// 构建顶部收支切换和独立滚动的左右分类栏；参数：无；返回值：适配深色与动态字号的分类管理页面。
    var body: some View {
        VStack(spacing: 0) {
            Picker("收支类型", selection: $type) {
                Text("支出").tag("expense")
                Text("收入").tag("income")
            }
            .pickerStyle(.segmented).padding(16)
            .onChange(of: type) { _, value in
                // 切换回调输入新旧收支值、返回无；重置到对应首组，避免收入显示支出内容。
                selectedGroup = CategoryCatalog.groups(for: value)[0].id
            }
            if let error { InlineError(message: error).padding(.horizontal); Button("重试") { Task { await reload() } } }
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(CategoryCatalog.groups(for: type)) { item in
                            groupButton(item)
                        }
                    }.padding(.horizontal, 6).padding(.vertical, 12)
                }
                .frame(width: groupColumnWidth)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.name).font(.title2.bold())
                            Spacer()
                            Text("\(categories.count) 项").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(categories) { category in
                                // 点击回调无参数、返回无；以真实业务 ID 和原始字段建立编辑草稿，不创建新分类。
                                Button { draft = CategoryDraft(category: category) } label: {
                                    tile(name: category.name, icon: CategoryCatalog.icon(for: category), color: .listColor(category.color))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("编辑分类，\(category.name)")
                                .accessibilityValue(type == "income" ? "收入，\(group.name)" : "支出，\(group.name)")
                                .accessibilityHint("修改名称、分组、图标和颜色")
                            }
                        }
                        Button { draft = CategoryDraft(group: group) } label: {
                            Label("自定义分类", systemImage: "plus.circle")
                                .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(Color.listColor(group.color).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        }.tint(.listColor(group.color))
                    }.padding(18)
                }.id(group.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("分类管理").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("新建分类", systemImage: "plus") { draft = CategoryDraft(group: group) } }
        .sheet(item: $draft) { CategoryEditor(draft: $0) }
        .task { await reload() }
    }
    /// 网格布局；参数：无；返回值：常规字号两列起，大字号自动单列。
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 140 : 76), spacing: 12)] }

    /// 计算分类栏紧凑宽度；参数：无；返回值：当前类型最长名称的动态字号宽度，加按钮左右各 10 点及栏内左右各 6 点留白，按钮至少宽 44 点。
    private var groupColumnWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: groupFontSize, weight: .semibold)
        // 测量回调接收目录分组，返回选中状态字宽；统一使用较宽的半粗体，切换选中项时栏宽不跳动。
        let titleWidth = CategoryCatalog.groups(for: type).map {
            ($0.name as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(max(44, titleWidth + 20)) + 12
    }

    /// 创建一级分组按钮；参数：item 为目录分组；返回值：适配名称字宽的图标、名称和选中标记按钮，名称保持单行，点击仅修改本页选择。
    private func groupButton(_ item: CategoryGroup) -> some View {
        let selected = group.id == item.id
        return Button { selectedGroup = item.id } label: {
            VStack(spacing: 7) {
                Image(systemName: item.icon).font(.system(size: 21, weight: .medium)).frame(height: 25)
                Text(item.name).font(.system(size: groupFontSize, weight: selected ? .semibold : .regular))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(selected ? Color.listColor(item.color) : .secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(selected ? Color(uiColor: .secondarySystemGroupedBackground) : .clear, in: RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Color.listColor(item.color)).frame(width: 3, height: 22).offset(x: -6) }
            }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 构建可编辑项目外观；参数：name 为名称，icon 为系统符号，color 为分类保存的颜色；返回值：图标、编辑角标及完整名称，由外层按钮提供编辑操作。
    private func tile(name: String, icon: String, color: Color) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 24, weight: .regular))
                .foregroundStyle(color).frame(width: 58, height: 58)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 19))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill").font(.system(size: 17))
                        .symbolRenderingMode(.palette).foregroundStyle(color, Color(uiColor: .secondarySystemGroupedBackground))
                        .offset(x: 3, y: 3)
                }
                .accessibilityHidden(true)
            Text(name).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 94, alignment: .top)
            .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    /// 刷新真实分类；参数：无；返回值：无，错误保留现有列表并提供重试。
    private func reload() async {
        do { try await store.loadFinance(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct CategoryDraft: Identifiable {
    let id = UUID()
    let businessID: Int?
    let original: TransactionCategory?
    let type: String
    var groupKey: String
    var name: String
    var icon: String
    var color: String

    /// 创建新增草稿；参数：group 为当前收支目录分组；返回值：名称为空、继承目录外观的新草稿，无持久化副作用。
    init(group: CategoryGroup) {
        businessID = nil; original = nil; type = group.type
        groupKey = group.id; name = ""; icon = group.icon; color = group.color
    }

    /// 创建编辑草稿；参数：category 为已保存的分类，包含稳定业务 ID；返回值：保留原始字段、收支类型及当前展示外观的独立草稿，无持久化副作用。
    init(category: TransactionCategory) {
        businessID = category.id; original = category; type = category.type
        groupKey = CategoryCatalog.group(for: category).id
        name = category.name; icon = CategoryCatalog.icon(for: category); color = category.color
    }

    /// 可写展示字段；参数：无；返回值：包含去除首尾空白名称的四个白名单字段，不包含收支类型及业务 ID。
    var fields: [String: Any] {
        ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "groupKey": groupKey, "icon": icon, "color": color]
    }

    /// 编辑差异；参数：无；返回值：仅包含用户改动的展示字段；旧分类的推断分组和图标不因打开编辑器而补写，未提交字段及历史引用保持原值。
    var changes: [String: Any] {
        guard let original else { return fields }
        return Values.patch(original: ["name": original.name, "groupKey": CategoryCatalog.group(for: original).id,
                                       "icon": CategoryCatalog.icon(for: original), "color": original.color], edited: fields)
    }
}

private struct CategoryEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: CategoryDraft
    @State private var iconGroup = ""
    @State private var iconSearch = ""
    @State private var busy = false
    @State private var error: String?

    /// 编辑分类资料；参数：无；返回值：固定收支类型的名称、分组、颜色及图标表单，保存时锁定关闭。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        SymbolTile(symbol: draft.icon, color: .listColor(draft.color)).accessibilityHidden(true)
                        TextField("分类名称", text: $draft.name).accessibilityLabel("分类名称")
                    }
                    Picker("分组", selection: $draft.groupKey) {
                        ForEach(CategoryCatalog.groups(for: draft.type)) { group in
                            Label(group.name, systemImage: group.icon).tag(group.id)
                        }
                    }
                    LabeledContent("类型", value: draft.type == "income" ? "收入" : "支出")
                    ColorPicker("颜色", selection: customColor, supportsOpacity: false)
                }
                Section("图标") {
                    // 显式组合为一个表单行，避免嵌套 LabeledContent / Label 的自动样式产生额外占位。
                    // 当前图标独立展示，不受目录筛选和搜索结果影响，库外的已保存符号也予以保留。
                    HStack(spacing: 12) {
                        Text("当前图标")
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Image(systemName: draft.icon)
                            Text(CategoryCatalog.iconName(for: draft.icon))
                        }
                        .foregroundStyle(Color.listColor(draft.color))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("当前图标，\(CategoryCatalog.iconName(for: draft.icon))")
                    .accessibilityAddTraits(.isSelected)
                    // 搜索控件使用普通文本框并由横向容器确定行高，随系统字号自然伸缩。
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("搜索图标", text: $iconSearch)
                            .textFieldStyle(.plain)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("搜索图标")
                    }
                    Picker("图标分组", selection: $iconGroup) {
                        Text("全部图标").tag("")
                        ForEach(CategoryCatalog.groups) { group in
                            Text("\(group.type == "income" ? "收入" : "支出") · \(group.name)").tag(group.id)
                        }
                    }
                    if visibleIcons.isEmpty {
                        Text("没有匹配图标").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 14) {
                            ForEach(visibleIcons) { option in iconButton(option) }
                        }.padding(.vertical, 8)
                    }
                }
                if let error { InlineError(message: error) }
            }
            .navigationTitle(draft.businessID == nil ? "新建分类" : "编辑分类").navigationBarTitleDisplayMode(.inline)
            .disabled(busy).interactiveDismissDisabled(busy)
            .toolbar {
                // 保存回调无参数、返回无；有效输入只提交一次，空差异直接关闭。
                SaveToolbar(busy: busy, valid: validName) { Task { await save() } }
            }
        }
    }

    /// 图标搜索结果；参数：无；返回值：按选定目录与中文搜索词筛选的去重图标，当前选择不受结果影响。
    private var visibleIcons: [CategoryIcon] { CategoryCatalog.icons(groupID: iconGroup, matching: iconSearch) }

    /// 校验名称；参数：无；返回值：去除首尾空白后非空且 UTF-8 不超过服务端 64 字节限制时为 true。
    private var validName: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.utf8.count <= 64
    }

    /// 构建图标按钮；参数：option 为目录生成的有效系统符号与中文名称；返回值：至少 44 点点击区域、支持 VoiceOver 选中状态的按钮，仅更新草稿。
    private func iconButton(_ option: CategoryIcon) -> some View {
        let selected = draft.icon == option.symbol
        // 点击回调无参数、返回无；只更新图标，不联动改写颜色和目录归属。
        return Button { draft.icon = option.symbol } label: {
            Image(systemName: option.symbol).font(.title2).frame(maxWidth: .infinity, minHeight: 52)
                .background(selected ? Color.listColor(draft.color).opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.listColor(draft.color) : .clear, lineWidth: 2) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Color.listColor(draft.color))
            .accessibilityLabel(option.name).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 系统颜色盘绑定；参数：无；返回值：将不透明 RGB 转为 #RRGGBB 的草稿绑定，无法转换的颜色保持原值。
    private var customColor: Binding<Color> {
        // 读取回调无输入、返回当前颜色；写入回调接收系统选择颜色、返回无，仅更新草稿中的十六进制颜色。
        Binding(get: { Color.listColor(draft.color) }, set: { selected in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(selected).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            draft.color = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        })
    }

    /// 保存新增或编辑分类；参数：无；返回值：无；新增 POST、编辑仅 PATCH 变化字段且不提交 type，失败保留输入，成功关闭并刷新，刷新失败不重复提交。
    private func save() async {
        guard !busy, validName else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            if let businessID = draft.businessID {
                let fields = draft.changes
                guard !fields.isEmpty else { dismiss(); return }
                try await store.api.mutate("/finance/categories/\(businessID)", method: "PATCH", body: fields)
            } else {
                var fields = draft.fields; fields["type"] = draft.type
                try await store.api.mutate("/finance/categories", method: "POST", body: fields)
            }
            dismiss()
            await store.refreshAfterMutation(.finance)
        } catch { self.error = error.localizedDescription }
    }
}
