import SwiftUI

/// 月份控制与两页汇总卡片，默认显示月度收支。
struct FinanceDashboardHeader: View {
    @Binding var month: FinanceMonth
    let summary: FinanceMonthSummary?
    let overview: FinanceOverview?
    @State private var page = 0
    @State private var hideAmounts = false
    @State private var pickingMonth = false
    /// 构建月份控制与滑动卡片；参数：无；返回值：点击年月或箭头切换月份，资产始终代表当前账户余额。
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button { pickingMonth = true } label: { Text(month.title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: true, vertical: false) }
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
                                firstTitle: "总收入", first: summary?.income, secondTitle: "月结余", second: summary?.balance, color: .red).tag(0)
                    summaryCard(title: "净资产 · CNY", symbol: "leaf.fill", amount: overview?.netWorth,
                                firstTitle: "总资产", first: overview?.totalAssets, secondTitle: "总负债", second: overview?.totalLiabilities, color: .accentColor).tag(1)
                }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: 166)
                HStack(spacing: 7) {
                    ForEach(0..<2) { index in
                        Button { withAnimation { page = index } } label: {
                            Circle().fill(page == index ? Color.accentColor : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                                .padding(.vertical, 8).padding(.horizontal, 3)
                        }.buttonStyle(.plain).accessibilityLabel(index == 0 ? "月度收支" : "当前资产")
                    }
                }.padding(.bottom, 6)
            }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $pickingMonth) {
            FinanceMonthPicker(selection: $month).presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }
    /// 绘制月份箭头；参数：symbol 为图标名，offset 为月份步长；返回值：带方向辅助标签的圆形按钮。
    private func monthArrow(_ symbol: String, offset: Int) -> some View {
        Button { month = month.shifted(offset) } label: {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28).background(.quaternary, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(offset < 0 ? "上个月" : "下个月")
    }
    /// 绘制统一汇总卡片；参数：title/symbol/amount 为主指标，firstTitle/first 和 secondTitle/second 为次指标，color 为主色；返回值：一大两小金额布局，未知金额显示占位，隐私状态共享。
    private func summaryCard(title: String, symbol: String, amount: String?, firstTitle: String, first: String?, secondTitle: String, second: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Spacer()
                Button { hideAmounts.toggle() } label: { Image(systemName: hideAmounts ? "eye.slash" : "eye").font(.subheadline).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(hideAmounts ? "显示金额" : "隐藏金额")
            }
            Text(amountText(amount)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).privacySensitive()
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(firstTitle + " " + amountText(first))
                Text(secondTitle + " " + amountText(second))
            }.font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.65).privacySensitive()
        }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
    }
    /// 格式化可隐藏金额；参数：value 为服务端金额或未加载；返回值：人民币金额、隐私占位或加载占位。
    private func amountText(_ value: String?) -> String { hideAmounts ? "••••" : value.map { Values.money($0) } ?? "—" }
}

/// 年份分组的月份网格，从底部快速跳转到目标月份。
struct FinanceMonthPicker: View {
    @Binding var selection: FinanceMonth
    @Environment(\.dismiss) private var dismiss
    @State private var firstYear = 2000
    @State private var lastYear = FinanceMonth.current().year + 2
    /// 构建可扩展年份网格；参数：无；返回值：年份分组、选中月份高亮和本月快捷入口，选择后立即关闭。
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if firstYear > 1900 { Button("更早年份") { firstYear = max(1900, firstYear - 20) } }
                        ForEach(firstYear...lastYear, id: \.self) { year in
                            VStack(alignment: .leading, spacing: 14) {
                                Text("\(String(year))年").font(.headline).foregroundStyle(year == selection.year ? Color.accentColor : .primary)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                                    ForEach(1...12, id: \.self) { month in
                                        let value = FinanceMonth(year: year, month: month)
                                        Button { selection = value; dismiss() } label: {
                                            Text("\(month)月").font(.body.weight(value == selection ? .semibold : .regular))
                                                .foregroundStyle(value == selection ? Color.accentColor : .primary)
                                                .frame(maxWidth: .infinity, minHeight: 48)
                                                .background(value == selection ? Color.accentColor.opacity(0.13) : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                                        }.buttonStyle(.plain).accessibilityLabel(value.title)
                                            .accessibilityAddTraits(value == selection ? .isSelected : [])
                                    }
                                }
                            }.id(year)
                        }
                        if lastYear < 9999 { Button("更多年份") { lastYear = min(9999, lastYear + 10) } }
                    }.padding(20)
                }.task {
                    // 初始化回调无参数、无返回值；将任意有效年份纳入网格，并定位当前所选年份。
                    firstYear = min(firstYear, selection.year); lastYear = max(lastYear, selection.year)
                    proxy.scrollTo(selection.year, anchor: .top)
                }
            }.navigationTitle("选择时间").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) }
                    ToolbarItem(placement: .confirmationAction) { Button("本月") { selection = .current(); dismiss() } }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }
}
