import SwiftUI

struct InlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline).foregroundStyle(.red).accessibilityLabel("错误：\(message)")
    }
}
struct SymbolTile: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let symbol: String
    var color: Color = .teal
    var size: CGFloat = 44
    /// 构建共用语义图标；参数：无；返回值：按 size 保持比例的中等字重符号与 12 点圆角淡色底，减少透明度时使用系统实底；不重复朗读所在行名称，无业务副作用。
    var body: some View {
        // 图标属于装饰图形，按容器比例保持大小；文字独立使用动态字体，避免辅助字号把图形挤出容器。
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color).frame(width: size, height: size)
            .background(reduceTransparency ? Color(uiColor: .tertiarySystemGroupedBackground) : color.opacity(0.1), in: RoundedRectangle(cornerRadius: AppVisualStyle.iconRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}
/// 内容区分组标题；只表达信息层级，不复制导航栏标题。
struct AppSectionHeading: View {
    let title: String
    var detail: String = ""

    /// 构建分组标题；参数：无；返回值：使用 headline 层级并随动态字号换行的左对齐标题与可选状态，不与页面主标题争夺层级；无业务副作用。
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer(minLength: 12)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
        }.accessibilityAddTraits(.isHeader)
    }
}

/// 导航目的地的内容标签；点击行为由外层系统 NavigationLink 提供，避免嵌套按钮。
struct AppDestinationLabel: View {
    let title: String
    let symbol: String
    var subtitle: String = ""
    var color: Color = .accentColor

    /// 构建入口标签；参数：无；返回值：图标、标题及可选简短状态，整行随文字增长且触控高度至少 44 点，无业务副作用。
    var body: some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.frame(minHeight: 44).padding(.vertical, 4)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .teal
    /// 构建金额指标卡片；参数：无；返回值：共享动态金额字体和实色内容卡片，无业务副作用。
    var body: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
                AmountText(value: value, emphasis: .standard).foregroundStyle(color)
            }
        }
            .accessibilityElement(children: .combine)
    }
}
struct SaveToolbar: ToolbarContent {
    @Environment(\.dismiss) private var dismiss
    let busy: Bool
    let valid: Bool
    let save: () -> Void
    /// 构建原生保存工具栏；参数：无；返回值：取消和优先保留的玻璃保存操作，busy 时禁止关闭或重复提交，save 无输入、返回值无；副作用由调用方定义。
    var body: some ToolbarContent {
        // 取消回调无参数、返回值无；仅在没有提交时关闭当前草稿面板。
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: save) { if busy { ProgressView() } else { Text("保存").bold() } }.disabled(busy || !valid)
                .buttonStyle(.glassProminent)
        }.visibilityPriority(.high)
    }
}
extension Color {
    /// 解析清单颜色；参数：hex 为 #RRGGBB；返回值：颜色，无效时使用青色；无副作用。
    static func listColor(_ hex: String) -> Color {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return .teal }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

/// 任务可选日期时间入口；表单仅保留开始／截止各一行，底部面板统一维护日期与时分草稿。
struct OptionalDateTimeInput: View {
    let title: String
    @Binding var enabled: Bool
    @Binding var date: Date
    @Binding var time: String
    @State private var presenting = false

    /// 合并任务拆分存储的日期和时分；参数：无；返回值：本地日历的完整日期时间，日期未设置时使用当前时间；无副作用。
    private var initialDate: Date {
        guard enabled else { return .now }
        // 转换回调接收冒号分隔的时分片段、返回可解析整数；历史空时间使用 09:00 作为面板时分草稿，全天确认仍保持空值。
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return Calendar(identifier: .gregorian).date(bySettingHour: parts.first ?? 9, minute: parts.count == 2 ? parts[1] : 0, second: 0, of: date) ?? date
    }

    /// 构建可选日期时间的单行入口；参数：无；返回值：至少 44 点高的日期行、行内清空按钮与系统底部面板，未设置日期默认全天；取消保留原值，确认和清空只修改表单草稿。
    var body: some View {
        HStack(spacing: 4) {
            // 点击回调无参数、返回无；开启同一底部面板，日期与时分不分别导航或弹出。
            Button { presenting = true } label: {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(enabled ? Values.day(date) + (time.isEmpty ? "" : " " + time) : "未设置")
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(title + ".selector")
            if enabled {
                // 清空回调无参数、返回无；仅清空当前字段的日期和隐藏时分，另一日期及其他草稿保持原值。
                Button {
                    enabled = false
                    time = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清除" + title + "日期")
                .accessibilityIdentifier(title + ".clear")
            }
        }
        // 原生选择行保持 44 点点击高度；去掉 Form 重复附加的上下留白，与其他系统字段对齐。
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .sheet(isPresented: $presenting) {
            // 新建、未设置或清空后的日期默认全天；已有具体时分的草稿保持非全天，避免覆盖原时间。
            SystemDateTimePanel(title: title, initialDate: initialDate, allowsAllDay: true, initialAllDay: !enabled || time.isEmpty) { selected, allDay in
                // 确认回调接收完整日期及全天状态、返回无；一次拆分写入任务草稿，保持 API 日期和时分字段兼容。
                date = selected
                time = allDay ? "" : Values.time(selected)
                enabled = true
            }
        }
    }
}
