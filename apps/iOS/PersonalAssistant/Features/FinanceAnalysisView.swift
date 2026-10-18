import SwiftUI
import Charts

/// 财务首页与账单详情共用分析页，只读取完整总览，不请求或汇总分页流水。
struct BillAnalysisView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var summary: FinanceOverview?
    @State private var stateSessionID: UUID?
    @State private var requestID = UUID()
    @State private var updatedAt: Date?
    @State private var loading = false
    @State private var error: String?

    /// 获取当前会话数据；参数：无；返回值：属于当前会话的统计，身份改变时立即隐藏旧值，等待新请求；无副作用。
    private var currentSummary: FinanceOverview? { stateSessionID == store.sessionID ? summary : nil }
    /// 获取当前会话错误；参数：无；返回值：当前身份的读取错误，旧会话错误不显示；无副作用。
    private var currentError: String? { stateSessionID == store.sessionID ? error : nil }
    /// 跟踪本机账本与身份变化；参数：无；返回值：自动加载任务标识，账本修订后重新读取完整汇总。
    private var loadIdentity: String { "\(store.sessionID)|\(store.finance?.revision ?? 0)" }

    /// 构建财务分析；参数：无；返回值：动态字号友好的原生列表、图表与明细，未知不补零，失败显示旧值状态并支持重试；无写入副作用。
    var body: some View {
        List {
            if let error = currentError {
                Section {
                    if currentSummary != nil {
                        Label("更新失败，以下为上次读取的数据", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange).accessibilityAddTraits(.updatesFrequently)
                    }
                    InlineError(message: error)
                    // 重试回调无参数、返回值无；保留旧数据发起新读取，由请求代号防止过期结果覆盖。
                    Button("重试") { Task { await load() } }.disabled(loading)
                }
            }
            if let summary = currentSummary {
                let report = FinanceAnalysis.report(summary)
                Section {
                    if loading { ProgressView("正在更新…") }
                    if let updatedAt {
                        LabeledContent("读取时间") {
                            Text(updatedAt, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                }
                monthlySection(report)
                trendSection(report)
                categorySection(report)
                assetSection(report)
                Section {
                    ForEach(report.insights) { insight in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(insight.title).font(.headline)
                            Text(insight.detail).font(.subheadline).foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("记录洞察")
                } footer: {
                    Text("本月尚未结束，仅分析已记录净额，不作整月同比或环比判断。")
                }
            } else if currentError == nil {
                Section { ProgressView("加载分析…") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("财务分析").navigationBarTitleDisplayMode(.inline)
        // 自动加载回调无参数、返回值无；身份或账本修订变化会取消旧任务并读取新总览。
        .task(id: loadIdentity) { await load() }
        // 下拉回调无参数、返回值无；刷新失败不清除已成功读取的当前会话数据。
        .refreshable { await load() }
        // 退出回调无参数、返回值无；作废按钮产生的非结构化任务，防止离开后写入页面状态。
        .onDisappear { requestID = UUID(); loading = false }
    }

    /// 构建当月收支；参数：report 为完整总览的解析结果；返回值：收入、净支出、结余及有效储蓄率，净退款和零收入保留必要说明。
    private func monthlySection(_ report: FinanceAnalysisReport) -> some View {
        Section {
            metric("收入", value: FinanceAnalysis.money(report.income), color: .teal)
            metric(report.expense.map { $0 < 0 } == true ? "净支出（净退款）" : "净支出", value: FinanceAnalysis.money(report.expense), color: .orange)
            metric("结余", value: FinanceAnalysis.money(report.balance))
            metric("储蓄率", value: FinanceAnalysis.percent(report.savingsRate))
            metric("支出占收入", value: FinanceAnalysis.percent(report.expenseToIncome))
        } header: {
            Text("本月收支")
        } footer: {
            if report.expense.map({ $0 < 0 }) == true {
                Text("退款抵扣后支出为负，不评价储蓄率或支出占收入比。")
            } else if report.income.map({ $0 <= 0 }) == true {
                Text("收入非正，暂无可用的收入比例基数。")
            } else if report.income == nil || report.expense == nil || report.balance == nil {
                Text("部分金额缺失，相关指标暂不计算。")
            }
        }
    }

    /// 构建半年趋势；参数：report 为至多六个有效月份的净收支；返回值：原生分组柱状图与可展开金额明细，负支出保持负值，大字号以文字明细为主，不把缺值绘成零。
    private func trendSection(_ report: FinanceAnalysisReport) -> some View {
        Section {
            if report.months.isEmpty {
                Text("暂无趋势数据").foregroundStyle(.secondary)
            } else {
                if !dynamicTypeSize.isAccessibilitySize {
                    Chart {
                        ForEach(report.months) { point in
                            if let income = point.income {
                                BarMark(x: .value("月份", point.month), y: .value("金额", chartValue(income)))
                                    .foregroundStyle(by: .value("类型", "收入"))
                                    .position(by: .value("类型", "收入"))
                            }
                            if let expense = point.expense {
                                BarMark(x: .value("月份", point.month), y: .value("金额", chartValue(expense)))
                                    .foregroundStyle(by: .value("类型", "净支出"))
                                    .position(by: .value("类型", "净支出"))
                            }
                        }
                    }
                    .chartForegroundStyleScale(["收入": Color.teal, "净支出": Color.orange])
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let month = value.as(String.self) { Text(String(month.suffix(2)) + "月") }
                            }
                        }
                    }
                    .frame(height: 220)
                    // 全部数值通过下方原生明细提供给 VoiceOver，避免重复朗读或只读取图形。
                    .accessibilityHidden(true)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    trendDetails(report.months)
                } else {
                    DisclosureGroup("月度金额明细") { trendDetails(report.months) }
                }
            }
        } header: {
            Text("近六个月收支趋势")
        } footer: {
            if !report.months.isEmpty { Text("负支出表示净退款；缺失金额或月份不补零。") }
        }
    }

    /// 构建趋势文字替代；参数：months 为有效月份，金额可缺失；返回值：包含年份的逐月收支及结余，供大字号和 VoiceOver 读取，无隐藏的图表专属数值。
    private func trendDetails(_ months: [FinanceAnalysisMonth]) -> some View {
        ForEach(months) { point in
            VStack(alignment: .leading, spacing: 8) {
                Text(point.month).font(.headline)
                metric("收入", value: FinanceAnalysis.money(point.income), color: .teal)
                metric(point.expense.map { $0 < 0 } == true ? "净支出（净退款）" : "净支出", value: FinanceAnalysis.money(point.expense), color: .orange)
                metric("结余", value: FinanceAnalysis.money(point.balance))
            }.padding(.vertical, 4)
                .accessibilityElement(children: .combine)
        }
    }

    /// 构建分类分布；参数：report 为所有分类净额与正值分母占比；返回值：前五项正值金额柱状图及完整分类金额列表，负值明确标为净退款，数据不完整时不展示百分比。
    private func categorySection(_ report: FinanceAnalysisReport) -> some View {
        // 排序回调按有效正净额降序，仅限制图表数量，不改变全量分类占比分母。
        let positive = report.categories.filter { ($0.amount ?? 0) > 0 }.sorted { ($0.amount ?? 0) > ($1.amount ?? 0) }
        let incomplete = report.categories.contains { $0.amount == nil }
        return Section {
            if report.categories.isEmpty {
                Text("暂无分类汇总").foregroundStyle(.secondary)
            } else {
                if !positive.isEmpty && !dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("正值分类金额 · 前五项").font(.caption).foregroundStyle(.secondary)
                        Chart(Array(positive.prefix(5))) { category in
                            BarMark(x: .value("金额", chartValue(category.amount ?? 0)), y: .value("分类", category.name))
                                .foregroundStyle(Color.orange)
                        }.frame(height: CGFloat(min(5, positive.count)) * 36 + 36)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(report.categories) { category in
                    VStack(alignment: .leading, spacing: 4) {
                        metric(category.name + (category.amount.map { $0 < 0 } == true ? "（净退款）" : ""),
                               value: FinanceAnalysis.money(category.amount), color: .orange)
                        if let share = category.share {
                            Text("占正值分类 \(FinanceAnalysis.percent(share))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if category.amount == nil {
                            Text("金额缺失").font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("本月支出分类")
        } footer: {
            if incomplete {
                Text("部分分类金额缺失，暂不计算占比。")
            } else if !report.categories.isEmpty {
                Text("占比以正值分类合计为分母；净退款不参与。分类金额已抵扣该类退款。")
            }
        }
    }

    /// 构建资产负债摘要；参数：report 为当前总览解析值；返回值：总资产、负债、净资产及有正资产基数时的资产负债率，无收入不足导致的替代估算。
    private func assetSection(_ report: FinanceAnalysisReport) -> some View {
        Section {
            metric("总资产", value: FinanceAnalysis.money(report.assets))
            metric("总负债", value: FinanceAnalysis.money(report.liabilities))
            metric("净资产", value: FinanceAnalysis.money(report.netWorth))
            metric("资产负债率", value: FinanceAnalysis.percent(report.debtRatio))
        } header: {
            Text("当前资产负债")
        } footer: {
            Text("仅含计入净资产的账户；资产非正或缺失时不计算负债率。")
        }
    }

    /// 绘制可换行指标；参数：title 为字段名称，value 为已格式化金额或比例，color 为系统语义色、默认主文本色；返回值：常规字号同行、大字号纵向排列的原生文本组合，VoiceOver 按名称和值读取。
    private func metric(_ title: String, value: String, color: Color = .primary) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Text(title).fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
            Text(value).monospacedDigit().foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(value == "—" ? "暂无数据" : value)
    }

    /// 转换图表数值；参数：value 为已验证的有限 Decimal；返回值：仅供绘图使用的 Double，统计及金额展示始终使用原 Decimal，不反向用于财务计算。
    private func chartValue(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }

    /// 加载完整本机总览；参数：无；返回值：无；成功原子替换当前会话数据，失败保留旧值并标示过期，取消、离开、身份变化或被新请求取代时不提交结果。
    @MainActor private func load() async {
        let session = store.sessionID
        let request = UUID()
        requestID = request
        if stateSessionID != session {
            summary = nil; updatedAt = nil; error = nil; stateSessionID = session
        }
        loading = true
        defer { if requestID == request { loading = false } }
        do {
            let result: FinanceOverview = try await store.api.request("/finance/overview")
            guard session == store.sessionID, requestID == request, !Task.isCancelled else { return }
            summary = result; updatedAt = .now; error = nil
        } catch {
            guard session == store.sessionID, requestID == request, !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
}
