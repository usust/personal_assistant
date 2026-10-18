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
        store.categories.filter { !$0.deleted && $0.type == type && CategoryCatalog.group(for: $0).id == group.id }
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
    @State private var choosingIcon = false
    @State private var confirmingDelete = false
    @State private var busy = false
    @State private var error: String?

    /// 编辑分类资料；参数：无；返回值：固定收支类型的资料表单、独立图标选择入口和已有分类的删除操作，提交时锁定关闭。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        // 点击回调无参数、返回无；打开选择弹窗，仅在选中图标后修改草稿。
                        Button { choosingIcon = true } label: {
                            SymbolTile(symbol: draft.icon, color: .listColor(draft.color))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("选择图标，\(CategoryCatalog.iconName(for: draft.icon, type: draft.type))")
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
                Section {
                    Button { choosingIcon = true } label: {
                        HStack(spacing: 12) {
                            Text("图标").foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: draft.icon)
                            Text(CategoryCatalog.iconName(for: draft.icon, type: draft.type))
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(Color.listColor(draft.color))
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("选择图标，\(CategoryCatalog.iconName(for: draft.icon, type: draft.type))")
                }
                if draft.businessID != nil {
                    Section {
                        Button("删除分类", role: .destructive) { confirmingDelete = true }
                            .frame(maxWidth: .infinity, minHeight: 44)
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
            .sheet(isPresented: $choosingIcon) {
                CategoryIconPicker(selection: $draft.icon, type: draft.type, color: .listColor(draft.color))
            }
            .alert("删除“\(draft.original?.name ?? draft.name)”？", isPresented: $confirmingDelete) {
                Button("删除分类", role: .destructive) { Task { await delete() } }
                Button("取消", role: .cancel) { }
            } message: {
                Text("历史流水保留原分类，删除后不可再选用。")
            }
        }
    }

    /// 校验名称；参数：无；返回值：去除首尾空白后非空且 UTF-8 不超过服务端 64 字节限制时为 true。
    private var validName: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.utf8.count <= 64
    }

    /// 删除已有分类；参数：无；返回值：无；仅提交持久化 ID，失败保留表单，成功关闭并刷新，历史流水引用由账本保留。
    private func delete() async {
        guard !busy, let businessID = draft.businessID else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            try await store.api.mutate("/finance/categories/\(businessID)", method: "DELETE")
            dismiss()
            await store.refreshAfterMutation(.finance)
        } catch { self.error = error.localizedDescription }
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

/// 分类图标独立选择弹窗；选择仅写入父表单草稿，关闭不提交分类资料。
private struct CategoryIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    let color: Color
    @State private var scope: String
    @State private var groupKey = ""
    @State private var query = ""

    /// 创建图标弹窗；参数：selection 为草稿系统符号绑定，type 为初始收入或支出范围，color 为当前分类颜色；返回值：优先展示对应收支图标的选择器，无持久化副作用。
    init(selection: Binding<String>, type: String, color: Color) {
        _selection = selection
        _scope = State(initialValue: type)
        self.color = color
    }

    /// 可选目录；参数：无；返回值：当前收支范围内的目录，全部范围时包含所有目录。
    private var groups: [CategoryGroup] {
        scope.isEmpty ? CategoryCatalog.groups : CategoryCatalog.groups(for: scope)
    }

    /// 当前搜索结果；参数：无；返回值：按收支、分组及关键词筛选的去重图标，保持目录顺序。
    private var icons: [CategoryIcon] {
        CategoryCatalog.icons(groupID: groupKey, matching: query, type: scope)
    }

    /// 构建图标筛选与搜索网格；参数：无；返回值：支持动态字号和 VoiceOver 的独立导航弹窗。
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Picker("图标范围", selection: $scope) {
                            Text("收入图标").tag("income")
                            Text("支出图标").tag("expense")
                            Text("全部图标").tag("")
                        }
                        .onChange(of: scope) { _, _ in
                            // 范围变化回调输入旧值和新值、返回无；清除旧分组，防止筛选条件互斥。
                            groupKey = ""
                        }
                        Spacer(minLength: 0)
                        Picker("图标分组", selection: $groupKey) {
                            Text("全部分组").tag("")
                            ForEach(groups) { group in
                                Text(scope.isEmpty ? "\(group.type == "income" ? "收入" : "支出") · \(group.name)" : group.name)
                                    .tag(group.id)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(color)
                    HStack(spacing: 10) {
                        Text("当前图标").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: selection).foregroundStyle(color)
                        Text(CategoryCatalog.iconName(for: selection, type: scope))
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                    if icons.isEmpty {
                        ContentUnavailableView {
                            Label("没有匹配图标", systemImage: "magnifyingglass")
                        } description: {
                            Text("试试其他关键词或图标分组")
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 14) {
                            ForEach(icons) { option in iconButton(option) }
                        }
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("选择图标").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索图标")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// 构建带名称的图标按钮；参数：option 为去重后的目录符号；返回值：至少 44 点点击区域和可朗读选中态，点击只更新草稿符号并关闭弹窗，不改颜色及分类分组。
    private func iconButton(_ option: CategoryIcon) -> some View {
        let selected = selection == option.symbol
        let name = CategoryCatalog.iconName(for: option.symbol, type: scope)
        // 点击回调无输入、返回无；父表单保存前选择只存在于草稿中。
        return Button {
            selection = option.symbol
            dismiss()
        } label: {
            VStack(spacing: 9) {
                Image(systemName: option.symbol).font(.system(size: 26))
                    .frame(height: 34).foregroundStyle(color)
                Text(name).font(.caption).foregroundStyle(.primary)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 80).padding(6)
            .background(selected ? color.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).stroke(selected ? color : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
