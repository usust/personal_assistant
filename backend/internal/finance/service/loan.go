// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"math/big"
	"regexp"
	"strings"
	"time"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// loanFields 校验单个贷款字段；参数：key 为已提交字段名，raw 为非 null JSON；返回值：数据库列、值与校验错误，无持久化副作用。
func loanFields(key string, raw json.RawMessage) (string, any, error) {
	columns := map[string]string{"loanPrincipal": "loan_principal", "loanAnnualRate": "loan_annual_rate", "loanMethod": "loan_method", "loanPeriods": "loan_periods", "loanPaidPeriods": "loan_paid_periods", "loanFirstPaymentDate": "loan_first_payment_date", "loanLender": "loan_lender", "loanReceivingAccountId": "loan_receiving_account_id"}
	column, ok := columns[key]
	if !ok {
		// 拒绝本次操作：未知贷款字段。
		return "", nil, Invalid("未知贷款字段")
	}
	switch key {
	case "loanPrincipal":
		var value domain.Money
		// 解析待校验字段，供后续校验与处理。
		if e := json.Unmarshal(raw, &value); e != nil {
			return "", nil, e
		}
		if value < 0 {
			// 拒绝本次操作：贷款本金不能为负数。
			return "", nil, Invalid("贷款本金不能为负数")
		}
		return column, value, nil
	case "loanPeriods", "loanPaidPeriods":
		var value int
		// 解析待校验字段，供后续校验与处理。
		if json.Unmarshal(raw, &value) != nil || value < 0 || value > 480 {
			// 拒绝本次操作：贷款期数须在 0 至 480 之间。
			return "", nil, Invalid("贷款期数须在 0 至 480 之间")
		}
		return column, value, nil
	case "loanReceivingAccountId":
		var value uint64
		// 解析待校验字段，供后续校验与处理。
		if json.Unmarshal(raw, &value) != nil {
			// 拒绝本次操作：收款账户无效。
			return "", nil, Invalid("收款账户无效")
		}
		return column, value, nil
	default:
		var value string
		// 解析待校验字段，供后续校验与处理。
		if json.Unmarshal(raw, &value) != nil || len(value) > 128 {
			// 拒绝本次操作：贷款文本无效。
			return "", nil, Invalid("贷款文本无效")
		}
		if key == "loanAnnualRate" && value != "" {
			// 将利率解析为精确数值，避免浮点误差。
			if _, e := loanRate(value); e != nil {
				return "", nil, e
			}
		}
		if key == "loanMethod" && value != "" && value != "annuity" && value != "equal_principal" && value != "interest_only" {
			// 拒绝本次操作：还款方式无效。
			return "", nil, Invalid("还款方式无效")
		}
		// 检查日期是否满足业务格式。
		if key == "loanFirstPaymentDate" && value != "" && !validDate(value) {
			// 拒绝本次操作：首次还款日期无效。
			return "", nil, Invalid("首次还款日期无效")
		}
		return column, value, nil
	}
}

// loanRate 解析合同年利率；参数：raw 为百分数，0–100，最多四位小数；返回值：精确月利率或错误，不含手续费。
func loanRate(raw string) (*big.Rat, error) {
	// 检查字段是否符合约定格式。
	if !regexp.MustCompile(`^(0|[1-9][0-9]{0,2})(\.[0-9]{1,4})?$`).MatchString(raw) {
		// 拒绝本次操作：年利率须为 0 至 100 的数字，最多四位小数。
		return nil, Invalid("年利率须为 0 至 100 的数字，最多四位小数")
	}
	// 将输入转换为精确数值。
	rate, ok := new(big.Rat).SetString(raw)
	// 比较精确数值以判断业务边界。
	if !ok || rate.Cmp(big.NewRat(100, 1)) > 0 {
		// 拒绝本次操作：年利率超出范围。
		return nil, Invalid("年利率超出范围")
	}
	// 以精确数值计算比值。
	return rate.Quo(rate, big.NewRat(1200, 1)), nil
}

// roundLoan 将非负分金额四舍五入；参数：value 为精确分值；返回值：整数分，调用者保证不超金额上限。
func roundLoan(value *big.Rat) domain.Money {
	// 以精确数值计算乘积。
	n := new(big.Int).Mul(value.Num(), big.NewInt(2))
	// 计算当前业务需要的偏移或累计值。
	n.Add(n, value.Denom())
	// 以精确数值计算乘积。
	d := new(big.Int).Mul(value.Denom(), big.NewInt(2))
	// 提取用于金额计算的整数值。
	return domain.Money(n.Quo(n, d).Int64())
}

// buildLoanPlan 生成固定月利率计划；参数：terms 为完整贷款资料；返回值：精确到分的计划或校验错误；无写入，末期归还本金尾差。
func buildLoanPlan(terms domain.LoanTerms) (*domain.LoanPlan, error) {
	// 检查日期是否满足业务格式。
	if terms.LoanPrincipal <= 0 || terms.LoanPrincipal > maxMoney || terms.LoanPeriods < 1 || terms.LoanPeriods > 480 || terms.LoanPaidPeriods < 0 || terms.LoanPaidPeriods > terms.LoanPeriods || !validDate(terms.LoanFirstPaymentDate) {
		// 拒绝本次操作：请填写正数本金、1 至 480 期及首次还款日，已还期数不能超过总期数。
		return nil, Invalid("请填写正数本金、1 至 480 期及首次还款日，已还期数不能超过总期数")
	}
	// 将利率解析为精确数值，避免浮点误差。
	rate, e := loanRate(terms.LoanAnnualRate)
	if e != nil {
		return nil, e
	}
	if terms.LoanMethod != "annuity" && terms.LoanMethod != "equal_principal" && terms.LoanMethod != "interest_only" {
		// 拒绝本次操作：请选择还款方式。
		return nil, Invalid("请选择还款方式")
	}
	// 按业务格式解析日期或时间。
	first, _ := time.Parse("2006-01-02", terms.LoanFirstPaymentDate)
	// 创建利率或金额计算的精确操作数。
	base := big.NewRat(int64(terms.LoanPrincipal), 1)
	// 以精确数值计算比值。
	monthly := new(big.Rat).Quo(base, big.NewRat(int64(terms.LoanPeriods), 1))
	// 检查数值的正负是否符合业务约束。
	if terms.LoanMethod == "annuity" && rate.Sign() > 0 {
		// 计算当前业务需要的偏移或累计值。
		factor := new(big.Rat).Add(big.NewRat(1, 1), rate)
		// 创建利率或金额计算的精确操作数。
		power := big.NewRat(1, 1)
		for i := 0; i < terms.LoanPeriods; i++ {
			// 以精确数值计算乘积。
			power.Mul(power, factor)
		}
		// 以精确数值计算比值。
		monthly.Quo(new(big.Rat).Mul(new(big.Rat).Mul(base, rate), power), new(big.Rat).Sub(power, big.NewRat(1, 1)))
	}
	remaining := terms.LoanPrincipal
	plan := &domain.LoanPlan{RemainingPrincipal: remaining, PaidPeriods: terms.LoanPaidPeriods, Schedule: []domain.LoanPayment{}}
	for i := 1; i <= terms.LoanPeriods; i++ {
		// 按贷款金额精度处理计算结果。
		interest := roundLoan(new(big.Rat).Mul(big.NewRat(int64(remaining), 1), rate))
		// 按贷款金额精度处理计算结果。
		principal := roundLoan(monthly)
		if terms.LoanMethod == "annuity" {
			principal -= interest
		}
		if terms.LoanMethod == "interest_only" {
			principal = 0
		}
		if principal < 0 {
			principal = 0
		}
		if principal > remaining || i == terms.LoanPeriods {
			principal = remaining
		}
		remaining -= principal
		// 每期从首次还款日所在月计算，避免 31 日经二月后永久漂移至 28 日。
		month := time.Date(first.Year(), first.Month()+time.Month(i-1), 1, 0, 0, 0, 0, time.UTC)
		// 取得日期中的日，供周期边界计算。
		last := month.AddDate(0, 1, -1).Day()
		// 取得日期中的日，供周期边界计算。
		day := first.Day()
		if day > last {
			day = last
		}
		// 按业务周期边界构造日期。
		date := time.Date(month.Year(), month.Month(), day, 0, 0, 0, 0, time.UTC)
		// 取得日期中的年份，供周期计算。
		if date.Year() > 9999 {
			// 拒绝本次操作：贷款到期日期超出范围。
			return nil, Invalid("贷款到期日期超出范围")
		}
		if principal+interest > maxMoney {
			// 拒绝本次操作：单期还款金额超出上限。
			return nil, Invalid("单期还款金额超出上限")
		}
		// 将业务时间转换为约定的存储或展示格式。
		payment := domain.LoanPayment{Period: i, Date: date.Format("2006-01-02"), Principal: principal, Interest: interest, Payment: principal + interest, Remaining: remaining, AnnualRate: terms.LoanAnnualRate}
		plan.Schedule = append(plan.Schedule, payment)
		if payment.Payment > 0 {
			plan.LastPaymentPeriod = i
		}
		plan.TotalInterest += interest
		if plan.TotalInterest > maxMoney {
			// 拒绝本次操作：贷款总利息超出上限。
			return nil, Invalid("贷款总利息超出上限")
		}
		if i == terms.LoanPaidPeriods {
			plan.RemainingPrincipal = remaining
		}
		if i > terms.LoanPaidPeriods && payment.Payment > 0 && plan.Next == nil {
			copy := payment
			plan.Next = &copy
		}
	}
	// 从各期计划汇总贷款金额。
	populateLoanTotals(plan)
	return plan, nil
}

// populateLoanTotals 按已还期数汇总本息；参数：plan 为含完整有效分期的非空计划；返回值：无，重置并更新摘要，不写账本，旧单期修正按应还额计入本息总额。
func populateLoanTotals(plan *domain.LoanPlan) {
	plan.PaidPrincipal, plan.PaidInterest, plan.PaidTotal = 0, 0, 0
	plan.RemainingInterest, plan.RemainingTotal, plan.TotalPayment = 0, 0, 0
	for _, row := range plan.Schedule {
		plan.TotalPayment += row.Payment
		if row.Period <= plan.PaidPeriods {
			plan.PaidPrincipal += row.Principal
			plan.PaidInterest += row.Interest
			plan.PaidTotal += row.Payment
		} else {
			plan.RemainingInterest += row.Interest
			plan.RemainingTotal += row.Payment
		}
	}
}

// validateLoanAccount 校验合并后的贷款资料和关联权限；参数：db 为事务，a 为账户；返回值：计划或错误；旧账户未填计划时仍可编辑。
func validateLoanAccount(db *gorm.DB, a domain.Account) (*domain.LoanPlan, error) {
	if a.LoanReceivingAccountID != 0 {
		if a.LoanReceivingAccountID == a.ID {
			// 拒绝本次操作：收款账户不能为贷款本身。
			return nil, Invalid("收款账户不能为贷款本身")
		}
		// 按所属用户读取账户并检查可用状态。
		if _, e := account(db, a.OwnerID, a.LoanReceivingAccountID, true); e != nil {
			return nil, e
		}
	}
	if a.LoanPrincipal == 0 {
		if a.LoanPeriods != 0 || a.LoanPaidPeriods != 0 || a.LoanAnnualRate != "" || a.LoanMethod != "" || a.LoanFirstPaymentDate != "" {
			// 拒绝本次操作：贷款计划需要填写本金。
			return nil, Invalid("贷款计划需要填写本金")
		}
		return nil, nil
	}
	// 读取账户保存的贷款计划。
	return accountLoanPlan(a)
}

// attachLoanPlan 附加只读计划摘要；参数：a 为已读取账户；返回值：无，旧数据无计划则省略，不改变数据库。
func attachLoanPlan(a *domain.Account) {
	a.LoanPlanLocked = a.LoanPaidPeriods > 0 || a.LoanScheduleJSON != ""
	if a.LoanPrincipal > 0 {
		// 读取账户保存的贷款计划。
		a.LoanPlan, _ = accountLoanPlan(*a)
		if a.LoanPlan != nil {
			a.LoanPlan.Schedule = nil
		}
	}
}

// loanChanged 检查请求是否包含贷款字段；参数：fields 为校验后的更新映射；返回值：是否包含贷款资料，无副作用。
func loanChanged(fields map[string]any) bool {
	for key := range fields {
		// 检查输入是否符合预期前缀。
		if strings.HasPrefix(key, "loan_") {
			return true
		}
	}
	return false
}

// loanPreview 解析试算请求；参数：raw 为贷款资料 JSON；返回值：还款计划或错误，不访问账户、不写入流水。
func loanPreview(raw json.RawMessage) (*domain.LoanPlan, error) {
	var terms domain.LoanTerms
	// 严格解析业务输入，避免无效字段进入操作流程。
	if e := Decode(raw, &terms); e != nil {
		return nil, e
	}
	// 字符串解析保持与保存接口一致；整数范围在计划计算中验证。
	return buildLoanPlan(terms)
}
