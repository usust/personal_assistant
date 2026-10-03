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
                                tile(name: category.name, icon: CategoryCatalog.icon(for: category), color: .listColor(group.color))
                            }
                        }
                        Button { draft = CategoryDraft(group: group, name: "", icon: group.icon) } label: {
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
        .toolbar { Button("新建分类", systemImage: "plus") { draft = CategoryDraft(group: group, name: "", icon: group.icon) } }
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

    /// 构建项目单元；参数：name 为名称，icon 为系统符号，color 为分组颜色；返回值：图标及完整名称视图。
    private func tile(name: String, icon: String, color: Color) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 24, weight: .regular))
                .foregroundStyle(color).frame(width: 58, height: 58)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 19))
                .accessibilityHidden(true)
            Text(name).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 94, alignment: .top).accessibilityElement(children: .combine)
    }
    /// 刷新真实分类；参数：无；返回值：无，错误保留现有列表并提供重试。
    private func reload() async {
        do { try await store.loadFinance(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct CategoryDraft: Identifiable {
    let id = UUID()
    let group: CategoryGroup
    var name: String
    var icon: String
}

private struct CategoryEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: CategoryDraft
    @State private var busy = false
    @State private var error: String?
    /// 编辑分类名称和图标；参数：无；返回值：继承收支与一级分组的新增表单，保存时锁定关闭。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        SymbolTile(symbol: draft.icon, color: .listColor(draft.group.color))
                        TextField("分类名称", text: $draft.name)
                    }
                    LabeledContent("一级分类", value: draft.group.name)
                    LabeledContent("类型", value: draft.group.type == "income" ? "收入" : "支出")
                }
                Section("图标") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 14) {
                        ForEach(Array(Set([draft.group.icon] + draft.group.items.map(\.icon))).sorted(), id: \.self) { icon in
                            Button { draft.icon = icon } label: {
                                Image(systemName: icon).font(.title2).frame(width: 52, height: 52)
                                    .background(draft.icon == icon ? Color.listColor(draft.group.color).opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay { RoundedRectangle(cornerRadius: 14).stroke(draft.icon == icon ? Color.listColor(draft.group.color) : .clear, lineWidth: 2) }
                            }.buttonStyle(.plain).foregroundStyle(Color.listColor(draft.group.color))
                                .accessibilityLabel(draft.group.items.first { $0.icon == icon }?.name ?? draft.group.name)
                                .accessibilityAddTraits(draft.icon == icon ? .isSelected : [])
                        }
                    }.padding(.vertical, 8)
                }
                if let error { InlineError(message: error) }
            }
            .navigationTitle("新建分类").navigationBarTitleDisplayMode(.inline)
            .disabled(busy).interactiveDismissDisabled(busy)
            .toolbar { SaveToolbar(busy: busy, valid: !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.name.count <= 64) { Task { await save() } } }
        }
    }
    /// 保存分类分组及图标；参数：无；返回值：无；失败保留输入，写入成功后关闭并刷新，刷新失败不重复提交。
    private func save() async {
        busy = true; defer { busy = false }
        do {
            try await store.api.mutate("/finance/categories", body: ["name": draft.name.trimmingCharacters(in: .whitespacesAndNewlines), "type": draft.group.type, "color": draft.group.color, "groupKey": draft.group.id, "icon": draft.icon])
            dismiss()
            await store.refreshAfterMutation(.finance)
        } catch { self.error = error.localizedDescription }
    }
}
