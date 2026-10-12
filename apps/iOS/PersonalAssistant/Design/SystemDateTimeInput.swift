import SwiftUI

/// 全局日期／时间入口；只在系统底部面板选择，确认后回写外层草稿。
struct SystemDateTimeInput: View {
    let title: String
    @Binding var selection: Date
    var displayedComponents: DatePickerComponents = [.date, .hourAndMinute]
    var range: ClosedRange<Date> = SystemDateTimeInput.allowedRange
    var showsTitle = true
    var displayValue: String? = nil
    @State private var presenting = false

    /// 提供系统选择器支持的公历范围；参数：无；返回值：1 至 9999 年的本地日期闭区间，与四位年份 API 格式一致；无副作用。
    static var allowedRange: ClosedRange<Date> {
        let calendar = Calendar(identifier: .gregorian)
        let first = calendar.date(from: DateComponents(year: 1, month: 1, day: 1))!
        let last = calendar.date(from: DateComponents(year: 9999, month: 12, day: 31, hour: 23, minute: 59, second: 59))!
        return first...last
    }

    /// 格式化当前日期或时分；参数：无；返回值：入口摘要，自定义摘要优先；不修改草稿。
    private var value: String {
        if let displayValue { return displayValue }
        if displayedComponents == .hourAndMinute { return Values.time(selection) }
        return Values.day(selection) + (displayedComponents.contains(.hourAndMinute) ? " " + Values.time(selection) : "")
    }

    /// 构建底部系统选择入口；参数：无；返回值：至少 44 点高的字段按钮和原生底部面板，取消不回写；无页面导航或网络副作用。
    var body: some View {
        // 点击回调无参数、返回无；仅打开系统面板，草稿由面板内部维护。
        Button { presenting = true } label: {
            HStack {
                if showsTitle { Text(title).foregroundStyle(.primary); Spacer(minLength: 12) }
                Text(value).foregroundStyle(showsTitle ? .secondary : .primary).multilineTextAlignment(.trailing)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + "，" + value)
        .accessibilityIdentifier(title + ".selector")
        // 选择行与系统表单控件共用紧凑高度，Form 中不再额外叠加默认上下留白。
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .sheet(isPresented: $presenting) {
            // 确认回调接收完整日期时间和全天状态、返回无；普通字段忽略全天状态，只回写一次。
            SystemDateTimePanel(title: title, initialDate: selection, displayedComponents: displayedComponents, range: range) { date, _ in
                selection = date
            }
        }
    }
}

/// 统一系统底部面板；日期与时间使用同一个原生滚轮，玻璃仅用于操作按钮。
struct SystemDateTimePanel: View {
    let title: String
    let displayedComponents: DatePickerComponents
    let range: ClosedRange<Date>
    let allowsAllDay: Bool
    let onConfirm: (Date, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Date
    @State private var allDay: Bool
    @State private var contentHeight: CGFloat = 420

    /// 初始化独立选择草稿；参数：title 为短标题，initialDate 为初值，displayedComponents 为日期／时间组件，range 为合法闭区间，allowsAllDay 控制是否允许只保存日期，initialAllDay 为初始全天状态，onConfirm 接收所选日期及全天状态；返回值：面板实例；初值截到合法范围，初始化不回写外层。
    init(title: String, initialDate: Date, displayedComponents: DatePickerComponents = [.date, .hourAndMinute], range: ClosedRange<Date> = SystemDateTimeInput.allowedRange, allowsAllDay: Bool = false, initialAllDay: Bool = false, onConfirm: @escaping (Date, Bool) -> Void) {
        self.title = title
        self.displayedComponents = displayedComponents
        self.range = range
        self.allowsAllDay = allowsAllDay
        self.onConfirm = onConfirm
        _draft = State(initialValue: min(max(initialDate, range.lowerBound), range.upperBound))
        _allDay = State(initialValue: allowsAllDay && initialAllDay)
    }

    /// 构建系统底部滚轮；参数：无；返回值：一次确认日期时间的底部面板；取消或下滑丢弃内部草稿，确认仅调用外层回调，无网络副作用。
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                // 取消回调无参数、返回无；丢弃面板草稿并回到同一表单。
                Button("取消") { dismiss() }.buttonStyle(.glass).accessibilityIdentifier("system-date-time-cancel")
                Spacer()
                Text(title).font(.headline)
                Spacer()
                // 确认回调无参数、返回无；一次传递完整日期时间，随后收起系统面板。
                Button("完成") { onConfirm(draft, allDay); dismiss() }.buttonStyle(.glassProminent).accessibilityIdentifier("system-date-time-done")
            }
            if allowsAllDay { Toggle("全天", isOn: $allDay) }
            // 日期与时间共用一个系统滚轮；全天只隐藏时分列，不另开时间页面或叠加选择器。
            DatePicker(title, selection: $draft, in: range, displayedComponents: allDay ? .date : displayedComponents)
                .datePickerStyle(.wheel).labelsHidden()
                .frame(maxWidth: .infinity).frame(height: 216).clipped()
                .accessibilityIdentifier("system-date-time-wheel")

        }
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
        // 测量回调接收面板布局并返回完整高度；写入回调接收高度、返回无，使系统面板适应字号与全天开关。
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if height > 0 { contentHeight = ceil(height) }
        }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationCompactAdaptation(.sheet)
    }
}
