import SwiftUI

/// 按期调整贷款计划；account 为账户，plan 为同一版本的完整计划，fromPeriod 为用户选中的期次（包括已还）。
struct LoanAdjustmentEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: FinancialAccount
    @State private var baseline: LoanPlanSummary
    @State private var draft: LoanAdjustmentDraft
    @State private var preview: LoanPlanSummary?
    @State private var error: String?
    @State private var busy = false
    @State private var saved = false

    /// 构造指定期次表单；参数：account 为账户，plan 为完整权威计划，fromPeriod 须在计划内，kind 为金额或利率操作；返回值：编辑器，不触发网络写入。
    init(account: FinancialAccount, plan: LoanPlanSummary, fromPeriod: Int, kind: LoanAdjustmentKind) {
        self.account = account
        _baseline = State(initialValue: plan)
        let row = plan.schedule?.first { $0.period == fromPeriod } ?? plan.next ?? LoanPaymentSummary(period: fromPeriod, date: "", principal: "0", interest: "0", payment: "0", remaining: "0")
        _draft = State(initialValue: LoanAdjustmentDraft(row: row, fallbackRate: account.loanAnnualRate ?? "0", kind: kind))
    }

    /// 提供有期初本金的选项；参数：无；返回值：包含已还期次、保持原日期顺序的可调计划行。
    private var eligible: [LoanPaymentSummary] {
        (baseline.schedule ?? []).filter(LoanDetailPresentation.canAdjust)
    }

    /// 最近三期预览；参数：无；返回值：从生效期开始最多三期，末期不足三期时按实际数量展示。
    private var previewRows: [LoanPaymentSummary] {
        Array((preview?.schedule ?? []).filter { $0.period >= draft.fromPeriod }.prefix(3))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LoanCard {
                        VStack(spacing: 18) {
                            // 标签按固有宽度布局，把剩余空间交给期次，避免 LabeledContent 将日期挤到下一行。
                            HStack(spacing: 8) {
                                Text(draft.kind == .rate ? "生效期次" : "调整期次").fixedSize()
                                Spacer(minLength: 0)
                                Picker("生效期次", selection: $draft.fromPeriod) {
                                    ForEach(eligible, id: \.period) { row in Text("第 \(row.period) 期 · \(row.date)").tag(row.period) }
                                }.labelsHidden().lineLimit(1).minimumScaleFactor(0.75).accessibilityLabel(draft.kind == .rate ? "生效期次" : "调整期次")
                            }
                            Divider()
                            Group {
                                LabeledContent("调整后年利率") {
                                    HStack {
                                        TextField("年利率", text: $draft.annualRate).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                            .accessibilityIdentifier("loan-adjustment-rate")
                                        Text("%")
                                    }
                                }
                            }
                            if draft.kind == .payment {
                                Divider()
                                LabeledContent("本期应还金额") {
                                    TextField("金额", text: $draft.payment).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                        .accessibilityIdentifier("loan-adjustment-payment")
                                }
                            }
                        }.font(.subheadline)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.kind == .rate ? "从第 \(draft.fromPeriod) 期起调整利率，此前各期保持不变。" : "本期按账单校准，后续按年利率重算。")
                        if draft.fromPeriod <= (baseline.paidPeriods ?? 0) { Text("包含已还期次，不改动实际流水和余额。") }
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    Button { Task { await calculate() } } label: {
                        Text("预览调整结果").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent)
                        .disabled(!draft.valid || !eligible.contains(where: { $0.period == draft.fromPeriod }) || busy)
                    if !previewRows.isEmpty {
                        HStack {
                            Text("调整后近 \(previewRows.count) 期").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("还款预览").font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 4).padding(.top, 8)
                        ForEach(previewRows, id: \.period) { row in previewCard(row) }
                        if let preview {
                            if let end = preview.lastPaymentPeriod, end < (preview.schedule?.count ?? 0) {
                                Text("第 \(end) 期结清").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let error {
                        LoanCard { VStack(alignment: .leading, spacing: 12) { InlineError(message: error); Button("刷新计划") { Task { await reload() } } } }
                    }
                }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground)).scrollDismissesKeyboard(.interactively)
                .disabled(busy || saved)
                .navigationTitle(draft.kind.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(preview == nil || busy || saved) }
                }
                .overlay { if busy { ProgressView() } }
                .interactiveDismissDisabled(busy)
                // 输入变化使上次预览失效；回调输入旧新草稿、返回无，保存始终对应当前输入。
                .onChange(of: draft) { _, _ in preview = nil; error = nil }
                // 切换金额修正期次时预填该期应还；输入为新旧期次，返回无，不继承上一期的金额。
                .onChange(of: draft.fromPeriod) { _, period in
                    if draft.kind == .payment, let row = baseline.schedule?.first(where: { $0.period == period }) { draft.payment = row.payment; draft.annualRate = row.annualRate ?? account.loanAnnualRate ?? "0" }
                }
        }
    }

    /// 显示调整后的单期卡片；参数：row 为服务端试算期次；返回值：日期、金额及本息拆分，原应还额用于对照，无副作用。
    private func previewCard(_ row: LoanPaymentSummary) -> some View {
        LoanCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("第 \(row.period) 期").font(.subheadline.weight(.semibold))
                        Text(row.date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(Values.money(row.payment)).font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor)
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                        if let original = baseline.schedule?.first(where: { $0.period == row.period }) {
                            Text("原应还 \(Values.money(original.payment))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                // 同一文本统一缩放，三项保持同一行，窄屏不截断数值。
                Text("本金 \(Values.money(row.principal))  利息 \(Values.money(row.interest))  年利率 \(row.annualRate ?? account.loanAnnualRate ?? "0")%")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.65)
                if let correction = LoanDetailPresentation.paymentCorrection(row) {
                    Text("本期金额修正 \(correction)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.accessibilityIdentifier("loan-preview-period-\(row.period)")
    }

    /// 只读预览当前草稿；参数：无；返回值：无，失败保留输入，跨会话或取消后丢弃响应。
    private func calculate() async {
        guard !busy, draft.valid else { return }
        busy = true; error = nil; preview = nil; defer { busy = false }
        let generation = store.sessionID
        do {
            let result: LoanPlanSummary = try await store.api.request("/finance/accounts/\(account.id)/loan-adjustment-preview", method: "POST", body: draft.fields(revision: baseline.revision ?? 0))
            if generation == store.sessionID && !Task.isCancelled { preview = result }
        } catch { if generation == store.sessionID { self.error = error.localizedDescription } }
    }

    /// 保存已预览的变更；参数：无；返回值：无，后端校验版本并原子写计划，成功关闭后由父页刷新账户及提醒。
    private func save() async {
        guard !busy, !saved, preview != nil else { return }
        busy = true; error = nil; defer { busy = false }
        let generation = store.sessionID
        do {
            let _: LoanPlanSummary = try await store.api.request("/finance/accounts/\(account.id)/loan-adjustments", method: "POST", body: draft.fields(revision: baseline.revision ?? 0))
            guard generation == store.sessionID, !Task.isCancelled else { return }
            saved = true; dismiss()
        } catch { if generation == store.sessionID { preview = nil; self.error = error.localizedDescription } }
    }

    /// 刷新过期计划；参数：无；返回值：无，丢弃旧预览和草稿并选中新的可调期次，失败保留错误。
    private func reload() async {
        guard !busy else { return }
        busy = true; preview = nil; defer { busy = false }
        let generation = store.sessionID
        do {
            let result: LoanPlanSummary = try await store.api.request("/finance/accounts/\(account.id)/loan-plan")
            guard generation == store.sessionID, !Task.isCancelled else { return }
            baseline = result
            if let period = LoanDetailPresentation.adjustmentPeriod(result, today: Values.day()), let row = result.schedule?.first(where: { $0.period == period }) { draft = LoanAdjustmentDraft(row: row, fallbackRate: account.loanAnnualRate ?? "0", kind: draft.kind) }
            error = nil
        } catch { if generation == store.sessionID { self.error = error.localizedDescription } }
    }
}
