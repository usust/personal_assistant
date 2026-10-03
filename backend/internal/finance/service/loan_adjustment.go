// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"fmt"
	"math/big"
	"reflect"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// accountLoanPlan 读取权威计划；参数：a 为已授权账户；返回值：动态摘要和完整快照或错误，无写入；快照损坏不回退重算历史。
func accountLoanPlan(a domain.Account) (*domain.LoanPlan, error) {
	if a.LoanScheduleJSON == "" {
		// 根据贷款条款计算还款计划。
		plan, err := buildLoanPlan(a.LoanTerms)
		if err == nil {
			plan.Revision = a.LoanRevision
		}
		return plan, err
	}
	var rows []domain.LoanPayment
	// 解析业务记录集合，供后续校验与处理。
	if json.Unmarshal([]byte(a.LoanScheduleJSON), &rows) != nil || len(rows) != a.LoanPeriods {
		// 拒绝本次操作：贷款计划数据异常，请重新加载。
		return nil, Invalid("贷款计划数据异常，请重新加载")
	}
	// 结合实际还款汇总当前贷款状态。
	return summarizeLoanPlan(a, rows)
}

// summarizeLoanPlan 从分期快照计算摘要；参数：a 提供原始本金、已还期数和版本，rows 为按期次排列的分期；返回值：完整计划或一致性错误，无写入。
func summarizeLoanPlan(a domain.Account, rows []domain.LoanPayment) (*domain.LoanPlan, error) {
	if a.LoanPaidPeriods < 0 || a.LoanPaidPeriods > len(rows) {
		// 拒绝本次操作：已还期数不能超过总期数。
		return nil, Invalid("已还期数不能超过总期数")
	}
	plan := &domain.LoanPlan{Revision: a.LoanRevision, PaidPeriods: a.LoanPaidPeriods, RemainingPrincipal: a.LoanPrincipal, Schedule: rows}
	remaining := a.LoanPrincipal
	for i, row := range rows {
		if row.Period != i+1 || row.Principal < 0 || row.Interest < 0 || row.Principal > remaining || row.Remaining != remaining-row.Principal || row.Payment < 0 || row.Payment > maxMoney || (!row.PaymentOverridden && row.Payment != row.Principal+row.Interest) || (row.PaymentOverridden && row.Payment <= 0) {
			// 拒绝本次操作：贷款计划金额不一致。
			return nil, Invalid("贷款计划金额不一致")
		}
		remaining = row.Remaining
		if row.Payment > 0 {
			plan.LastPaymentPeriod = row.Period
		}
		plan.TotalInterest += row.Interest
		if plan.TotalInterest > maxMoney {
			// 拒绝本次操作：贷款总利息超出上限。
			return nil, Invalid("贷款总利息超出上限")
		}
		if row.Period == a.LoanPaidPeriods {
			plan.RemainingPrincipal = row.Remaining
		}
		if row.Period > a.LoanPaidPeriods && row.Payment > 0 && plan.Next == nil {
			copy := row
			plan.Next = &copy
		}
	}
	if remaining != 0 {
		// 拒绝本次操作：贷款计划末期未结清本金。
		return nil, Invalid("贷款计划末期未结清本金")
	}
	// 从各期计划汇总贷款金额。
	populateLoanTotals(plan)
	return plan, nil
}

// protectLoanHistory 阻止普通 PATCH 改写原合同；参数：a 为修改前账户，fields 为白名单字段；返回值：错误或 nil，会在必要时向 map 补入旧计划快照。
func protectLoanHistory(a domain.Account, fields map[string]any) error {
	if a.LoanPrincipal <= 0 || (a.LoanPaidPeriods == 0 && a.LoanScheduleJSON == "") {
		return nil
	}
	original := map[string]any{"loan_principal": a.LoanPrincipal, "loan_annual_rate": a.LoanAnnualRate, "loan_method": a.LoanMethod, "loan_periods": a.LoanPeriods, "loan_first_payment_date": a.LoanFirstPaymentDate}
	for key, value := range original {
		// 比较业务字段是否发生实际变化。
		if next, supplied := fields[key]; supplied && !reflect.DeepEqual(next, value) {
			// 拒绝本次操作：已有还款历史，请从贷款计划调整利率与金额。
			return Invalid("已有还款历史，请从贷款计划调整利率与金额")
		}
	}
	// 兼容升级前已有已还期数但尚无快照的账户；在清零期数之前先固定历史。
	if a.LoanScheduleJSON == "" {
		// 读取账户保存的贷款计划。
		plan, err := accountLoanPlan(a)
		if err != nil {
			return err
		}
		// 序列化业务数据，供存储或响应使用。
		encoded, err := json.Marshal(plan.Schedule)
		if err != nil {
			return err
		}
		fields["loan_schedule_json"] = string(encoded)
	}
	return nil
}

// adjustedLoanPlan 根据操作范围调整计划；参数：a 为合同，before 为权威旧计划，in 为变更；返回值：新计划或校验错误，reprice 调息并校准本期，旧 payment 仅修正单期，不改旧切片和真实余额。
func adjustedLoanPlan(a domain.Account, before *domain.LoanPlan, in domain.LoanAdjustmentInput) (*domain.LoanPlan, error) {
	if in.Revision == nil || *in.Revision != a.LoanRevision {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("%w: 贷款计划已变化，请刷新后重新试算", ErrConflict)
	}
	// 已还期数仅划分计划展示状态，不能阻止用户修正过去录入的计划；真实账本不参与重算。
	if in.FromPeriod < 1 || in.FromPeriod > len(before.Schedule) {
		// 拒绝本次操作：请选择有效的生效期次。
		return nil, Invalid("请选择有效的生效期次")
	}
	if in.Kind == "reprice" {
		// 按银行账单条件重新定价。
		return repricedLoanPlan(a, before, in)
	}
	if in.Kind != "" {
		// 单独应用指定的贷款调整。
		return independentlyAdjustedLoanPlan(a, before, in)
	}
	if in.Scope != "" {
		// 拒绝本次操作：请选择单期金额调整。
		return nil, Invalid("请选择单期金额调整")
	}
	// 将利率解析为精确数值，避免浮点误差。
	rate, err := loanRate(in.AnnualRate)
	if err != nil {
		return nil, err
	}
	if (in.PaymentMode != "auto" && in.PaymentMode != "fixed") || (in.PaymentMode == "auto" && in.Payment != nil) || (in.PaymentMode == "fixed" && (in.Payment == nil || *in.Payment <= 0 || *in.Payment > maxMoney)) {
		// 拒绝本次操作：请选择有效的还款金额方式。
		return nil, Invalid("请选择有效的还款金额方式")
	}
	start := in.FromPeriod - 1
	opening := a.LoanPrincipal
	if start > 0 {
		opening = before.Schedule[start-1].Remaining
	}
	if opening <= 0 {
		// 拒绝本次操作：该期之前的计划本金已结清。
		return nil, Invalid("该期之前的计划本金已结清")
	}
	terms := a.LoanTerms
	terms.LoanPrincipal = opening
	terms.LoanAnnualRate = in.AnnualRate
	terms.LoanPeriods = len(before.Schedule) - start
	terms.LoanPaidPeriods = 0
	// 根据贷款条款计算还款计划。
	suffix, err := buildLoanPlan(terms)
	if err != nil {
		return nil, err
	}
	remaining := opening
	for i := range suffix.Schedule {
		row := &suffix.Schedule[i]
		// 日期复用原始完整计划，避免生效日在二月导致之后永远变为 28/29 日。
		row.Period = start + i + 1
		row.Date = before.Schedule[start+i].Date
		// 等额本金调息保留原本金摊销，避免重新平分剩余本金导致每期出现分币漂移。
		if in.PaymentMode == "auto" && a.LoanMethod == "equal_principal" {
			row.Principal = before.Schedule[start+i].Principal
			if row.Principal > remaining || i == len(suffix.Schedule)-1 {
				row.Principal = remaining
			}
			// 按贷款金额精度处理计算结果。
			row.Interest = roundLoan(new(big.Rat).Mul(big.NewRat(int64(remaining), 1), rate))
			remaining -= row.Principal
			row.Remaining = remaining
			row.Payment = row.Principal + row.Interest
		}
		if in.PaymentMode == "fixed" {
			row.CustomPayment = true
			// 按贷款金额精度处理计算结果。
			row.Interest = roundLoan(new(big.Rat).Mul(big.NewRat(int64(remaining), 1), rate))
			if remaining > 0 && *in.Payment <= row.Interest {
				// 拒绝本次操作：每期本息须大于当期利息。
				return nil, Invalid("每期本息须大于当期利息")
			}
			row.Principal = *in.Payment - row.Interest
			if row.Principal > remaining || i == len(suffix.Schedule)-1 {
				row.Principal = remaining
			}
			remaining -= row.Principal
			row.Remaining = remaining
			row.Payment = row.Principal + row.Interest
		}
		// 已确认的单期应还额始终独立保留；调息只重算本息，不把修正金额传播为后续月供。
		if original := before.Schedule[start+i]; original.PaymentOverridden {
			row.Payment, row.PaymentOverridden = original.Payment, true
			if original.InterestCalibrated {
				if row.Payment < row.Principal {
					// 拒绝本次操作：调整后本金超过已校准账单金额，请先核对该期账单。
					return nil, Invalid("调整后本金超过已校准账单金额，请先核对该期账单")
				}
				row.Interest, row.InterestCalibrated = row.Payment-row.Principal, true
			}
		}
	}
	rows := append([]domain.LoanPayment{}, before.Schedule[:start]...)
	rows = append(rows, suffix.Schedule...)
	// 结合实际还款汇总当前贷款状态。
	return summarizeLoanPlan(a, rows)
}

// repricedLoanPlan 同时调息和校准银行本期账单；参数：a 为授权合同，before 为旧计划，in 须通过版本和期次校验且提供新年利率及正金额；返回值：新计划或校验错误，无写入。
func repricedLoanPlan(a domain.Account, before *domain.LoanPlan, in domain.LoanAdjustmentInput) (*domain.LoanPlan, error) {
	if in.Scope != "period" || in.PaymentMode != "" || in.Payment == nil || *in.Payment <= 0 || *in.Payment > maxMoney {
		// 拒绝本次操作：请提供本期应还金额及年利率。
		return nil, Invalid("请提供本期应还金额及年利率")
	}
	// 单独应用指定的贷款调整。
	result, err := independentlyAdjustedLoanPlan(a, before, domain.LoanAdjustmentInput{Kind: "rate", Revision: in.Revision, FromPeriod: in.FromPeriod, AnnualRate: in.AnnualRate})
	if err != nil {
		return nil, err
	}
	row := &result.Schedule[in.FromPeriod-1]
	if *in.Payment < row.Principal {
		// 拒绝本次操作：本期应还金额不能小于计划本金；提前还本须单独处理。
		return nil, Invalid("本期应还金额不能小于计划本金；提前还本须单独处理")
	}
	// 本期跨调息日可能采用分段计息：以银行账单校准利息，本金链保持不变；后续仍按明确的新利率计算。
	row.Payment = *in.Payment
	row.Interest = row.Payment - row.Principal
	row.PaymentOverridden, row.InterestCalibrated = true, true
	// 结合实际还款汇总当前贷款状态。
	return summarizeLoanPlan(a, result.Schedule)
}

// independentlyAdjustedLoanPlan 分离调息与单期金额修正；参数：a 为合同，before 为完整旧计划，in 须已通过版本及期次校验；返回值：新计划或错误，不写库，金额只替换指定行的应还额。
func independentlyAdjustedLoanPlan(a domain.Account, before *domain.LoanPlan, in domain.LoanAdjustmentInput) (*domain.LoanPlan, error) {
	switch in.Kind {
	case "rate":
		if in.PaymentMode != "" || in.Payment != nil || in.Scope != "" {
			// 拒绝本次操作：利率调整不能同时修改还款金额。
			return nil, Invalid("利率调整不能同时修改还款金额")
		}
		// 将利率解析为精确数值，避免浮点误差。
		if _, err := loanRate(in.AnnualRate); err != nil {
			return nil, err
		}
	case "payment":
		if in.AnnualRate != "" {
			// 拒绝本次操作：金额调整不能同时修改利率。
			return nil, Invalid("金额调整不能同时修改利率")
		}
		if in.Scope != "period" || in.PaymentMode != "" || in.Payment == nil || *in.Payment <= 0 || *in.Payment > maxMoney {
			// 拒绝本次操作：请提供单期应还金额。
			return nil, Invalid("请提供单期应还金额")
		}
	default:
		// 拒绝本次操作：请选择利率或金额调整。
		return nil, Invalid("请选择利率或金额调整")
	}
	start := in.FromPeriod - 1
	if before.Schedule[start].Principal+before.Schedule[start].Remaining <= 0 {
		// 拒绝本次操作：该期之前的计划本金已结清。
		return nil, Invalid("该期之前的计划本金已结清")
	}
	if in.Kind == "payment" {
		// 复制整份快照，只更新该行；修正额与本息的差额单独展示，本金链和前后行逐项不变。
		rows := append([]domain.LoanPayment{}, before.Schedule...)
		rows[start].Payment = *in.Payment
		rows[start].PaymentOverridden = rows[start].Payment != rows[start].Principal+rows[start].Interest
		rows[start].InterestCalibrated = false
		// 结合实际还款汇总当前贷款状态。
		return summarizeLoanPlan(a, rows)
	}
	// 调息沿用原分段月供设置，避免将已保存的持续月供和单期金额修正混为一类。
	type configuration struct {
		rate    string
		mode    string
		payment domain.Money
	}
	var previous configuration
	var customAmount domain.Money
	result := &domain.LoanPlan{}
	*result = *before
	result.Schedule = append([]domain.LoanPayment{}, before.Schedule...)
	for i, row := range before.Schedule {
		// 自定义月供的末期补差和结清后的零尾期不是新的月供设置，继续使用之前的自定义额。
		if !row.CustomPayment {
			customAmount = 0
		} else if customAmount == 0 || row.Remaining > 0 {
			customAmount = row.Principal + row.Interest
		}
		if i < start {
			continue
		}
		current := configuration{rate: in.AnnualRate, mode: "auto"}
		if row.CustomPayment {
			current.mode, current.payment = "fixed", customAmount
		}
		if result.Schedule[i].Principal+result.Schedule[i].Remaining == 0 {
			result.Schedule[i].AnnualRate = current.rate
			result.Schedule[i].CustomPayment = current.mode == "fixed"
			continue
		}
		if i == start || current != previous {
			segment := domain.LoanAdjustmentInput{Revision: in.Revision, FromPeriod: i + 1, AnnualRate: current.rate, PaymentMode: current.mode}
			if current.mode == "fixed" {
				segment.Payment = &current.payment
			}
			var err error
			// 根据调整条件重算贷款计划。
			result, err = adjustedLoanPlan(a, result, segment)
			if err != nil {
				return nil, err
			}
		}
		previous = current
	}
	// 结合实际还款汇总当前贷款状态。
	return summarizeLoanPlan(a, result.Schedule)
}

// loanAdjustment 提供计划查询、试算及原子保存；参数：db 为用户锁事务，owner 为可信身份，op 为固定操作，in 为路径及 JSON；返回值：完整计划或错误，保存只更新快照与版本，不改余额和流水。
func loanAdjustment(db *gorm.DB, owner uint64, op string, in Input) (*domain.LoanPlan, error) {
	// 按所属用户读取账户并检查可用状态。
	a, err := account(db, owner, in.ID, true)
	if err != nil {
		return nil, err
	}
	if a.Institution != "贷款" || a.LoanPrincipal <= 0 {
		// 拒绝本次操作：请先补充贷款计划。
		return nil, Invalid("请先补充贷款计划")
	}
	// 读取账户保存的贷款计划。
	before, err := accountLoanPlan(a)
	if err != nil {
		return nil, err
	}
	if op == "finance.loan.plan" {
		return before, nil
	}
	var adjustment domain.LoanAdjustmentInput
	// 严格解析业务输入，避免无效字段进入操作流程。
	if err = Decode(in.Changes, &adjustment); err != nil {
		return nil, err
	}
	// 根据调整条件重算贷款计划。
	plan, err := adjustedLoanPlan(a, before, adjustment)
	if err != nil || op == "finance.loan.adjustment.preview" {
		return plan, err
	}
	// 序列化业务数据，供存储或响应使用。
	encoded, err := json.Marshal(plan.Schedule)
	if err != nil {
		return nil, err
	}
	fields := map[string]any{"loan_schedule_json": string(encoded), "loan_revision": a.LoanRevision + 1}
	// 仅写入本次经过校验的变更字段。
	affected, updateErr := repository.UpdateLoanRevision(db, owner, a.ID, a.LoanRevision, fields)
	if updateErr != nil {
		return nil, updateErr
	}
	if affected != 1 {
		// 为失败补充当前操作的错误上下文。
		return nil, fmt.Errorf("%w: 贷款计划已变化，请刷新", ErrConflict)
	}
	plan.Revision++
	return plan, nil
}
