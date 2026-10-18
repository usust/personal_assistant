import SwiftUI

/// 月份控制与三页汇总卡片，默认显示月度收支。
struct FinanceDashboardHeader: View {
    @Binding var month: FinanceMonth
    let summary: FinanceMonthSummary?
    let overview: FinanceOverview?
    @State private var page = 0
    @State private var hideAmounts = false
    @State private var cardHeight: CGFloat = 166
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var monthArrowSize: CGFloat = 28
    /// 构建月份控制与汇总分页；参数：无；返回值：分层的月份、原生选择器与实底汇总，大字号改为纵向月份和菜单选择；资产仍为当前余额，仅修改展示状态和所选月份。
    var body: some View {
        VStack(spacing: AppVisualStyle.itemSpacing) {
            Group {
                // 辅助字号将日期和月份操作分行，保留完整日期与独立的 44 点触控区。
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        monthSelector
                        monthControls
                    }
                } else {
                    HStack(spacing: 4) {
                        monthSelector
                        monthControls
                    }
                }
            }
            // 分组列表会裁切行的顶部圆角，月份控件内缩，避免首位年份落入裁切区域。
            .padding(.top, 12).padding(.horizontal, 4)
            // 两种原生选择器与横滑共用 page；辅助字号不挤压分段文字，减少动态效果时取消附加切页动画。
            if dynamicTypeSize.isAccessibilitySize {
                summaryPicker.pickerStyle(.menu)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                summaryPicker.pickerStyle(.segmented).controlSize(.large)
                    .frame(minHeight: 44)
            }
            TabView(selection: $page) {
                // 汇总始终属于所选月份；历史月份不能误标为当前月。
                summaryCard(title: month == .current() ? "本月支出" : "月度支出", symbol: "arrow.up.right.circle.fill", amount: summary?.expense,
                            firstTitle: month == .current() ? "本月收入" : "月度收入", first: summary?.income, secondTitle: "月结余", second: summary?.balance, color: FinanceVisualStyle.expense).tag(0)
                summaryCard(title: "净资产 · CNY", symbol: "leaf.fill", amount: overview?.netWorth,
                            firstTitle: "总资产", first: overview?.totalAssets, secondTitle: "总负债", second: overview?.totalLiabilities, color: .accentColor).tag(1)
                summaryCard(title: "待报销", symbol: "receipt", amount: summary?.reimbursementPending,
                            firstTitle: "已报销", first: summary?.reimbursementReceived, secondTitle: "报销总额", second: summary?.reimbursementTotal, color: .accentColor).tag(2)
            }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: cardHeight)
                // 高度回调接收三页内容的最大自然高度、返回值无；字号或窗口宽度变化时同步调整，不让分段控件占用金额空间。
                .onPreferenceChange(FinanceSummaryHeight.self) { height in if height > 0 { cardHeight = max(166, height) } }
                .cardSurface()
        }
        .buttonStyle(.plain)
    }
    /// 构建月份入口；参数：无；返回值：保留账本日历与年月摘要的原生日期按钮；确认只回写所选月份，无网络副作用。
    private var monthSelector: some View {
        SystemDateTimeInput(title: "月份", selection: monthDate, displayedComponents: .date, range: monthRange, showsTitle: false, displayValue: month.title)
            .font(.headline)
            .environment(\.calendar, monthCalendar)
            .environment(\.timeZone, monthCalendar.timeZone)
            .accessibilityLabel("选择月份，\(month.title)")
    }

    /// 构建月份快捷操作；参数：无；返回值：上一月、下一月及必要时的本月按钮；只修改月份绑定，不更改筛选粒度。
    private var monthControls: some View {
        HStack(spacing: 4) {
            monthArrow("chevron.left", offset: -1)
            monthArrow("chevron.right", offset: 1)
            Spacer(minLength: 0)
            if month != .current() {
                // 回到本月回调无参数、返回值无；沿用原有月份取值，不改变日期筛选规则。
                Button { month = .current() } label: {
                    Text("本月").font(.subheadline.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
            }
        }
    }

    /// 构建汇总页选择器；参数：无；返回值：保持既有页码和辅助功能标识的系统 Picker；选择只更新分页，减少动态效果时不添加动画。
    private var summaryPicker: some View {
        Picker("财务汇总", selection: $page.animation(reduceMotion ? nil : .easeInOut(duration: 0.2))) {
            Text(month == .current() ? "本月" : "月度").tag(0)
            Text("资产").tag(1)
            Text("报销").tag(2)
        }.accessibilityIdentifier("finance-summary-pages")
    }

    /// 提供账本月份使用的日历；参数：无；返回值：UTC+8 公历，避免设备时区造成月份漂移；无副作用。
    private var monthCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 28800)!
        return calendar
    }
    /// 限制原位月份选择范围；参数：无；返回值：1900 至 9999 年的日期闭区间，与月份箭头范围一致；无副作用。
    private var monthRange: ClosedRange<Date> {
        monthCalendar.date(from: DateComponents(year: 1900, month: 1, day: 1))!...monthCalendar.date(from: DateComponents(year: 9999, month: 12, day: 31))!
    }
    /// 转换月份与系统日期选择绑定；参数：无；返回值：按月首日展示、写入只更新年月的绑定；不改变账本筛选粒度。
    private var monthDate: Binding<Date> {
        // 读取回调无参数、返回月首日期；写入回调接收所选日期、返回无；年月转换统一使用账本 UTC+8 时区。
        Binding(get: { monthCalendar.date(from: DateComponents(year: month.year, month: month.month, day: 1))! },
                set: { month = .current($0) })
    }
    /// 绘制紧凑月份箭头；参数：symbol 为 SF Symbols 方向图标名，offset 为月份步长，此处仅传入 -1 或 1；返回值：随日期字号缩放、点击区域至少 44 点的原生玻璃按钮；点击仅更新所选月份。
    private func monthArrow(_ symbol: String, offset: Int) -> some View {
        // 点击回调无参数、无返回值；沿用账本月份范围切换，不改变日期选择粒度。
        Button { month = month.shifted(offset) } label: {
            // 玻璃圆形保持与日期文字协调的视觉尺寸，外层单独保留点击留白，避免系统按钮内边距放大圆形。
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: monthArrowSize, height: monthArrowSize)
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(offset < 0 ? "上个月" : "下个月")
    }
    /// 绘制统一汇总卡片；参数：title 为主指标名，symbol 为系统符号，amount 为可缺失主金额，firstTitle/first、secondTitle/second 分别为两个次指标名称及可缺失金额，color 为主指标语义色；返回值：主金额突出、次指标以分隔线分层的动态高度布局；未知值不补零，隐藏状态仍由三页共享，无业务副作用。
    private func summaryCard(title: String, symbol: String, amount: String?, firstTitle: String, first: String?, secondTitle: String, second: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: AppVisualStyle.itemSpacing) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.subheadline).foregroundStyle(color).accessibilityHidden(true)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // 隐私回调无参数、返回值无；仅切换三页共用的金额可见状态，不改动金额来源或格式化逻辑。
                Button { hideAmounts.toggle() } label: { Image(systemName: hideAmounts ? "eye.slash" : "eye").font(.subheadline).foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额")
            }
            AmountText(value: amountText(amount)).foregroundStyle(color).privacySensitive()
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    secondaryAmount(firstTitle, value: first).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    secondaryAmount(secondTitle, value: second).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: AppVisualStyle.itemSpacing) { secondaryAmount(firstTitle, value: first); secondaryAmount(secondTitle, value: second) }
            }.privacySensitive()
        }.padding(AppVisualStyle.cardInset).fixedSize(horizontal: false, vertical: true)
            .background {
                // 测量回调接收当前卡片的实际尺寸、返回高度偏好；只驱动展示布局，不修改财务数据。
                GeometryReader { geometry in Color.clear.preference(key: FinanceSummaryHeight.self, value: geometry.size.height) }
            }
    }
    /// 绘制辅助金额；参数：title 为指标名，value 为可缺失金额；返回值：名称与数字分层的动态字体视图，不重复固定字号；无业务副作用。
    private func secondaryAmount(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            AmountText(value: amountText(value), emphasis: .compact)
        }
    }
    /// 格式化可隐藏金额；参数：value 为服务端金额或未加载；返回值：人民币金额、隐私占位或加载占位。
    private func amountText(_ value: String?) -> String { hideAmounts ? "••••" : value.map { Values.money($0) } ?? "—" }
}

/// 汇总分页自然高度的布局偏好，避免固定容器裁切动态字号。
private struct FinanceSummaryHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    /// 合并分页高度；参数：value 为当前最大高度，nextValue 为无参数、返回下一高度的系统回调；返回值：无，通过 inout 保留最大值，无业务副作用。
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
