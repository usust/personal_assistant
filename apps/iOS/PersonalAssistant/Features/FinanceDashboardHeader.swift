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
    @ScaledMetric(relativeTo: .body) private var monthArrowSize: CGFloat = 28
    /// 构建月份控制与滑动卡片；参数：无；返回值：点击年月或箭头切换月份，资产始终代表当前账户余额。
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                // 系统日期控件在当前位置选择目标月份；账本只取年月，不引入按日筛选。
                SystemDateTimeInput(title: "月份", selection: monthDate, displayedComponents: .date, range: monthRange, showsTitle: false, displayValue: month.title)
                    .environment(\.calendar, monthCalendar)
                    .environment(\.timeZone, monthCalendar.timeZone)
                    .accessibilityLabel("选择月份，\(month.title)")
                monthArrow("chevron.left", offset: -1)
                monthArrow("chevron.right", offset: 1)
                Spacer(minLength: 0)
                if month != .current() {
                    Button("本月") { month = .current() }.font(.caption.weight(.medium))
                }
            }
            // 分组列表会裁切行的顶部圆角，月份控件内缩，避免首位年份落入裁切区域。
            .padding(.top, 12).padding(.horizontal, 4)
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    summaryCard(title: "总支出", symbol: "arrow.up.right.circle.fill", amount: summary?.expense,
                                firstTitle: "总收入", first: summary?.income, secondTitle: "月结余", second: summary?.balance, color: FinanceVisualStyle.expense).tag(0)
                    summaryCard(title: "净资产 · CNY", symbol: "leaf.fill", amount: overview?.netWorth,
                                firstTitle: "总资产", first: overview?.totalAssets, secondTitle: "总负债", second: overview?.totalLiabilities, color: .accentColor).tag(1)
                    summaryCard(title: "待报销 · 累计", symbol: "receipt", amount: overview?.reimbursementPending,
                                firstTitle: "已报销", first: overview?.reimbursementReceived, secondTitle: "报销总额", second: overview?.reimbursementTotal, color: .accentColor).tag(2)
                }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: cardHeight)
                    // 高度回调输入三页内容的最大自然高度、返回值无；字号或窗口宽度变化时同步调整，避免依赖缩字容纳内容。
                    .onPreferenceChange(FinanceSummaryHeight.self) { height in if height > 0 { cardHeight = max(166, height) } }
                HStack(spacing: 7) {
                    ForEach(0..<3) { index in
                        // 分页回调无输入、返回值无；减少动态效果时直接切页，其余使用短动画。
                        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = index } } label: {
                            Circle().fill(page == index ? Color.accentColor : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(["月度收支", "当前资产", "累计报销"][index])
                    }
                }.padding(.bottom, 6)
            }.cardSurface()
        }
        .buttonStyle(.plain)
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
    /// 绘制统一汇总卡片；参数：title/symbol/amount 为主指标，firstTitle/first 和 secondTitle/second 为次指标，color 为主色；返回值：动态高度的一大两小金额布局，窄屏或大字号自动纵向排列，未知金额显示占位，隐私状态共享。
    private func summaryCard(title: String, symbol: String, amount: String?, firstTitle: String, first: String?, secondTitle: String, second: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Spacer()
                Button { hideAmounts.toggle() } label: { Image(systemName: hideAmounts ? "eye.slash" : "eye").font(.subheadline).foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.plain).accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额")
            }
            AmountText(value: amountText(amount)).privacySensitive()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { secondaryAmount(firstTitle, value: first); secondaryAmount(secondTitle, value: second) }
                VStack(alignment: .leading, spacing: 12) { secondaryAmount(firstTitle, value: first); secondaryAmount(secondTitle, value: second) }
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
