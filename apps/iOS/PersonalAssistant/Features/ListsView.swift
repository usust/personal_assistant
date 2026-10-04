import SwiftUI

struct ListsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var edited: TaskList?
    @State private var deleted: TaskList?
    @State private var error: String?
    /// 构建清单界面；参数：无；返回值：原生视图；操作回调受共享写保护约束。
    var body: some View {
        List {
            if let error { InlineError(message: error) }
            if let notice = store.taskNotice { InlineError(message: notice); Button("刷新任务") { Task { await store.refreshTaskWrite(confirmedWrite: false) } } }
            if store.lists.isEmpty { ContentUnavailableView("创建你的第一个清单", systemImage: "folder.badge.plus", description: Text("例如：生活、工作、阅读。")) }
            ForEach(store.lists) { list in
                Button { edited = list } label: {
                    TaskListPreview(name: list.name, remark: list.remark, icon: list.icon, color: list.color)
                }.disabled(store.taskWriteBusy || store.taskWriteBlocked).swipeActions { Button("删除", role: .destructive) { deleted = list }.disabled(store.taskWriteBusy || store.taskWriteBlocked) }
            }
        }.navigationTitle("我的清单").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }; ToolbarItem(placement: .primaryAction) { Button("新建清单", systemImage: "plus") { creating = true }.disabled(store.taskWriteBusy || store.taskWriteBlocked) } }
            .sheet(isPresented: $creating) { ListEditor(list: nil) }
            .sheet(item: $edited) { ListEditor(list: $0) }
            .alert("删除清单？", isPresented: Binding(get: { deleted != nil }, set: { if !$0 { deleted = nil } })) {
                Button("取消", role: .cancel) { deleted = nil }
                Button("删除", role: .destructive) { if let list = deleted { Task { await remove(list) } } }
            } message: { Text("此操作会同时删除清单中的全部任务和子任务，无法撤销。") }
    }
    /// 删除清单及任务；参数：list 为已确认清单；返回值：无；级联删除已确认清单，失败显示错误。
    private func remove(_ list: TaskList) async {
        let generation = store.cloudSessionID
        // 写回调输入无、输出无；只提交一次排序或删除请求，副作用由共享写保护约束。
        do { try await store.writeTask { try await store.api.mutate("/task-lists/\(list.id)", method: "DELETE") }; store.lists.removeAll { $0.id == list.id }; store.tasks.removeAll { $0.listId == list.id }; deleted = nil; await store.refreshTaskWrite() }
        catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription }
    }
}
struct ListEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let list: TaskList?
    @State private var name = ""
    @State private var remark = ""
    @State private var color = "#14B8A6"
    @State private var icon = "Folder"
    @State private var uncertainCreation = false
    @State private var busy = false
    @State private var error: String?
    /// 构建清单界面；参数：无；返回值：原生视图；操作回调受共享写保护约束。
    var body: some View {
        NavigationStack {
            Form {
                if uncertainCreation { InlineError(message: "创建结果未确认。请关闭表单并刷新清单，确认后再创建。") }
                else if let error { InlineError(message: error) }
                if list == nil {
                    Section {
                        TaskListPreview(name: name.isEmpty ? "清单名称" : name, remark: remark, icon: icon, color: color, centered: true)
                    }
                }
                Section {
                    TaskFloatingField(title: "清单名称", text: $name)
                    TaskFloatingField(title: "备注", text: $remark, multiline: true)
                }
                Section("颜色") {
                    // 17 个常用色与颜色盘固定为六列三行，避免出现不完整行。
                    colorGrid
                }
                Section("图标") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 12) {
                        // 图标回调：输入为跨端共用图标键与系统符号；返回选择按钮，仅更新草稿。
                        ForEach(TaskListAppearance.icons, id: \.key) { option in
                            Button { icon = option.key } label: {
                                Image(systemName: option.symbol).font(.title3)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .foregroundStyle(Color.listColor(color))
                                    .background(Color.listColor(color).opacity(icon == option.key ? 0.2 : 0.06), in: RoundedRectangle(cornerRadius: 14))
                                    .overlay { if icon == option.key { RoundedRectangle(cornerRadius: 14).stroke(Color.listColor(color), lineWidth: 2) } }
                            }.buttonStyle(.plain).accessibilityLabel(option.label)
                                .accessibilityAddTraits(icon == option.key ? .isSelected : [])
                        }
                    }
                }
            if !uncertainCreation, error == nil, let notice = store.taskNotice { InlineError(message: notice); Button("刷新任务") { Task { await store.refreshTaskWrite(confirmedWrite: false) } } }
            }.navigationTitle(list == nil ? "新建清单" : "编辑清单").navigationBarTitleDisplayMode(.inline)
                .toolbar { SaveToolbar(busy: busy, valid: !name.trimmingCharacters(in: .whitespaces).isEmpty && name.unicodeScalars.count <= 128 && remark.unicodeScalars.count <= 2000 && !uncertainCreation && !store.taskWriteBusy && !store.taskWriteBlocked) { Task { await save() } } }
                .interactiveDismissDisabled(busy)
                .task { name = list?.name ?? ""; remark = list?.remark ?? ""; color = list?.color ?? "#14B8A6"; icon = list?.icon ?? "Folder" }
        }
    }
    /// 构建完整行颜色网格；参数：无；返回值：六列三行的 17 个常用色与最后一个颜色盘入口，仅修改颜色草稿。
    private var colorGrid: some View {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 8), count: 6), spacing: 12) {
                        // 色块回调：输入为合法十六进制常用色；返回选择按钮，仅更新草稿。
                        ForEach(TaskListAppearance.colors, id: \.self) { value in
                            Button { color = value } label: {
                                Circle().fill(Color.listColor(value)).frame(width: 32, height: 32)
                                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
                                    .overlay { if color.uppercased() == value { Image(systemName: "checkmark").foregroundStyle(["#EAB308", "#38BDF8", "#6EE7B7", "#FFFFFF"].contains(value) ? Color.black : Color.white).font(.caption.bold()) } }
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel("颜色 \(value)")
                                .accessibilityAddTraits(color.uppercased() == value ? .isSelected : [])
                        }
                        // 颜色盘作为网格最后一格；隐藏可见标签，保留 VoiceOver 名称和系统颜色选择交互。
                        ColorPicker("选择颜色", selection: customColor, supportsOpacity: false)
                            .labelsHidden().frame(width: 44, height: 44)
                            .accessibilityLabel("选择更多颜色")
                    }
    }
    /// 系统颜色盘绑定；参数：无；返回值：不透明颜色绑定，将 RGB 转为服务端要求的 #RRGGBB，仅修改草稿。
    private var customColor: Binding<Color> {
        Binding(get: { Color.listColor(color) }, set: { selected in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(selected).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            color = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        })
    }
    /// 保存清单；参数：无；返回值：无；编辑只发送变化的白名单字段，创建与编辑均保存跨端共用图标键。
    private func save() async {
        let generation = store.cloudSessionID
        busy = true; defer { if generation == store.cloudSessionID { busy = false } }
        do {
            let edited: [String: Any] = ["name": name.trimmingCharacters(in: .whitespaces), "remark": remark, "color": color, "icon": icon]
            if let list {
                let fields = Values.patch(original: ["name": list.name, "remark": list.remark, "color": list.color, "icon": list.icon], edited: edited)
                // 清单编辑回调输入无、输出服务器清单实体；仅发送变化白名单字段。
                if !fields.isEmpty { let saved: TaskList = try await store.writeTask { try await store.api.request("/task-lists/\(list.id)", method: "PATCH", body: fields) }; if let index = store.lists.firstIndex(where: { $0.id == saved.id }) { store.lists[index] = saved } }
            } else {
                // 创建回调输入无、输出服务器清单实体；POST结果不明时不重试。
                let saved: TaskList = try await store.writeTask { try await store.api.request("/task-lists", method: "POST", body: edited) }; store.lists.append(saved) }
            dismiss(); await store.refreshTaskWrite()
        } catch { guard !(error is CancellationError), generation == store.cloudSessionID else { return }; self.error = error.localizedDescription; if list == nil && store.taskWriteBlocked { uncertainCreation = true } }
    }
}

/// 清单列表紧邻图标左对齐；仅新建预览使用居中布局，编辑表单不显示预览。
private struct TaskListPreview: View {
    let name: String
    let remark: String
    let icon: String
    let color: String
    var centered = false
    /// 构建清单行；参数：无；返回值：名称与备注跟随 centered 对齐的视图，无副作用。
    /// 构建清单界面；参数：无；返回值：原生视图；操作回调受共享写保护约束。
    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: TaskListAppearance.symbol(icon), color: .listColor(color))
            VStack(alignment: centered ? .center : .leading, spacing: 5) {
                Text(name).font(.headline).foregroundStyle(Color.listColor(color))
                    .multilineTextAlignment(centered ? .center : .leading)
                if !remark.isEmpty { Text(remark).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(centered ? .center : .leading).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            // 仅新建预览保留对称留白；列表不保留右侧占位，文字紧邻图标。
            if centered { Color.clear.frame(width: 44, height: 44).accessibilityHidden(true) }
        }.padding(.vertical, 8)
    }
}

/// 任务表单浮动标签：聚焦或有值时将字段名移到左上，遵循减少动态效果设置。
struct TaskFloatingField: View {
    let title: String
    @Binding var text: String
    var multiline = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 构建清单界面；参数：无；返回值：原生视图；操作回调受共享写保护约束。
    var body: some View {
        let raised = focused || !text.isEmpty
        ZStack(alignment: .topLeading) {
            Text(title).font(raised ? .caption : .body).foregroundStyle(.secondary)
                .offset(y: raised ? 0 : 18).allowsHitTesting(false).accessibilityHidden(true)
            TextField(title, text: $text, prompt: Text(""), axis: multiline ? .vertical : .horizontal)
                .labelsHidden().focused($focused).padding(.top, 22)
                .lineLimit(1...(multiline ? 8 : 1)).accessibilityLabel(title)
        }.frame(minHeight: 54, alignment: .topLeading)
            .contentShape(Rectangle()).onTapGesture { focused = true }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: raised)
    }
}

/// 使用跨端共用键保存图标，iOS 通过 Apple SF Symbols 绘制，无需下载第三方图片。
private enum TaskListAppearance {
    // 按色系覆盖冷暖色与中性色，17 个预设加颜色盘正好组成三行。
    static let colors = ["#EF4444", "#FB7185", "#F97316", "#EAB308", "#A16207", "#EC4899",
                         "#8B5CF6", "#6366F1", "#3B82F6", "#38BDF8", "#06B6D4", "#14B8A6",
                         "#6EE7B7", "#22C55E", "#6B7280", "#111827", "#FFFFFF"]
    static let icons: [(key: String, symbol: String, label: String)] = [
        ("Folder", "folder.fill", "资料"), ("Checklist", "checklist", "清单"),
        ("Calendar", "calendar", "日程"), ("Bell", "bell.fill", "提醒"),
        ("Flag", "flag.fill", "目标"), ("Star", "star.fill", "重点"),
        ("Briefcase", "briefcase.fill", "工作"), ("DeviceLaptop", "laptopcomputer", "电脑"),
        ("Book", "book.fill", "阅读"), ("Pencil", "pencil", "写作"),
        ("Bulb", "lightbulb.fill", "想法"), ("Home", "house.fill", "家庭"),
        ("ShoppingCart", "cart.fill", "购物"), ("Wallet", "creditcard.fill", "财务"),
        ("Heart", "heart.fill", "健康"), ("Barbell", "dumbbell.fill", "健身"),
        ("Plane", "airplane", "旅行"), ("Car", "car.fill", "驾车"),
        ("Coffee", "cup.and.saucer.fill", "休闲"), ("Gift", "gift.fill", "礼物"),
        ("Camera", "camera.fill", "摄影"), ("Music", "music.note", "音乐"),
        ("Plant", "leaf.fill", "植物"), ("Paw", "pawprint.fill", "宠物"),
        ("ListCheck", "list.bullet", "待办事项"),
        ("ClipboardCheck", "checkmark.rectangle.fill", "检查清单"),
        ("ClipboardList", "list.clipboard.fill", "计划列表"),
        ("ProgressCheck", "chart.bar.fill", "任务进度"),
        ("CircleCheck", "checkmark.circle.fill", "完成事项"),
        ("SquareCheck", "checkmark.square.fill", "勾选任务"),
        ("TargetArrow", "target", "目标计划"),
        ("Timeline", "chart.xyaxis.line", "时间线"),
        ("CalendarEvent", "calendar.badge.plus", "新增日程"),
        ("CalendarTime", "calendar.badge.clock", "预约"),
        ("CalendarWeek", "calendar.day.timeline.left", "周计划"),
        ("CalendarMonth", "calendar.circle.fill", "月计划"),
        ("Clock", "clock.fill", "时间安排"),
        ("Alarm", "alarm.fill", "闹钟"),
        ("Route", "point.topleft.down.to.point.bottomright.curvepath", "行程路线"),
        ("Map", "map.fill", "地图"),
        ("MapPin", "mappin.and.ellipse", "地点"),
        ("Location", "location.fill", "定位"),
        ("Compass", "safari.fill", "方向"),
        ("World", "globe", "国际行程"),
        ("Train", "tram.fill", "火车"),
        ("Bus", "bus.fill", "公交"),
        ("Bike", "bicycle", "骑行"),
        ("Walk", "figure.walk", "步行"),
        ("Ship", "ferry.fill", "船运"),
        ("Luggage", "suitcase.rolling.fill", "旅行准备"),
        ("Tent", "tent.fill", "露营"),
        ("Mountain", "mountain.2.fill", "登山"),
        ("Building", "building.2.fill", "公司"),
        ("DeviceMobile", "iphone", "移动事务"),
        ("Mail", "envelope.fill", "邮件"),
        ("Message", "bubble.left.and.bubble.right.fill", "沟通"),
        ("Phone", "phone.fill", "电话"),
        ("Users", "person.2.fill", "团队"),
        ("User", "person.fill", "个人计划"),
        ("School", "graduationcap.fill", "学习"),
        ("Notebook", "book.closed.fill", "笔记"),
        ("Notes", "note.text", "记录"),
        ("FileText", "doc.text.fill", "文档"),
        ("Bookmark", "bookmark.fill", "收藏"),
        ("Edit", "square.and.pencil", "编辑"),
        ("Rocket", "paperplane.fill", "项目启动"),
        ("Trophy", "trophy.fill", "成就"),
        ("Medal", "medal.fill", "奖励"),
        ("ChartLine", "chart.line.uptrend.xyaxis", "数据分析"),
        ("Cash", "banknote.fill", "现金"),
        ("PigMoney", "dollarsign.circle.fill", "储蓄"),
        ("Receipt", "doc.plaintext", "账单"),
        ("Basket", "basket.fill", "采购"),
        ("BuildingStore", "storefront.fill", "商店"),
        ("ToolsKitchen2", "fork.knife", "烹饪"),
        ("Cake", "birthday.cake.fill", "生日"),
        ("Heartbeat", "waveform.path.ecg", "健康计划"),
        ("Stethoscope", "stethoscope", "医疗"),
        ("Pill", "pills.fill", "用药"),
        ("Run", "figure.run", "跑步"),
        ("BallFootball", "soccerball", "运动"),
        ("Trees", "tree.fill", "户外"),
        ("Sun", "sun.max.fill", "白天"),
        ("Moon", "moon.fill", "夜晚"),
        ("Cloud", "cloud.fill", "天气"),
        ("Dog", "dog.fill", "狗狗"),
        ("Cat", "cat.fill", "猫咪"),
        ("Palette", "paintpalette.fill", "创作"),
        ("ChefHat", "frying.pan.fill", "美食"),
        ("Tools", "wrench.and.screwdriver.fill", "维修"),
        ("Wifi", "wifi", "网络"),
        ("Beach", "beach.umbrella.fill", "度假")
    ]
    /// 解析清单图标；参数：key 为已保存图标键或旧版 folder；返回值：系统符号名称，未知键回退文件夹且不改写原值。
    static func symbol(_ key: String) -> String {
        icons.first { $0.key == key }?.symbol ?? "folder.fill"
    }
}
