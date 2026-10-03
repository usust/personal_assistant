// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"fmt"
	"reflect"
	"time"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// splitInstallment 精确拆分非负金额；参数：total 为分金额，terms 为已校验规则；返回值：各期金额，尾差归首期或末期，无副作用。
func splitInstallment(total domain.Money, terms domain.InstallmentTerms) ([]domain.Money, error) {
	n := domain.Money(terms.Periods)
	base := total / n
	if terms.Rounding == "round" && (total%n)*2 >= n {
		base++
	}
	result := make([]domain.Money, terms.Periods)
	for i := range result {
		result[i] = base
	}
	index := 0
	if terms.Remainder == "last" {
		index = len(result) - 1
	}
	result[index] += total - base*n
	if result[index] < 0 {
		// 拒绝本次操作：金额过小，请减少期数或选择向下取整。
		return nil, Invalid("金额过小，请减少期数或选择向下取整")
	}
	return result, nil
}

// calculateInstallment 试算逐月计划；参数：principal 为正数本金，terms 为用户规则；返回值：精确本息计划或校验错误，无数据库写入。
func calculateInstallment(principal domain.Money, terms domain.InstallmentTerms) (domain.InstallmentPlan, error) {
	plan := domain.InstallmentPlan{InstallmentTerms: terms, Principal: principal, Total: principal + terms.Interest, Rows: []domain.InstallmentRow{}}
	// 检查文本长度与必填约束。
	if !validText(terms.Name, 128, true) || terms.Periods < 2 || terms.Periods > 480 || !validDate(terms.FirstDate) || principal <= 0 || terms.Interest < 0 || plan.Total > maxMoney {
		// 拒绝本次操作：请检查名称、期数（2–480）、首期日期和利息。
		return plan, Invalid("请检查名称、期数（2–480）、首期日期和利息")
	}
	if (terms.InterestMode != "spread" && terms.InterestMode != "first") || (terms.Rounding != "round" && terms.Rounding != "floor") || (terms.Remainder != "first" && terms.Remainder != "last") {
		// 拒绝本次操作：分期计算规则无效。
		return plan, Invalid("分期计算规则无效")
	}
	if terms.DebtMode != "" && terms.DebtMode != "spread" && terms.DebtMode != "upfront" {
		// 拒绝本次操作：欠款计入方式无效。
		return plan, Invalid("欠款计入方式无效")
	}
	if terms.InterestCreditMode != "" && terms.InterestCreditMode != "spread" && terms.InterestCreditMode != "upfront" {
		// 拒绝本次操作：利息占用额度方式无效。
		return plan, Invalid("利息占用额度方式无效")
	}
	start := terms.StartPeriod
	if start == 0 {
		start = 1
	}
	if start < 1 || start > terms.Periods || terms.RestoredCredit < 0 || terms.RestoredCredit > maxMoney {
		// 拒绝本次操作：请检查起始期数和额度恢复金额。
		return plan, Invalid("请检查起始期数和额度恢复金额")
	}
	// 分摊各期金额并处理舍入差额。
	principals, err := splitInstallment(principal, terms)
	if err != nil {
		return plan, err
	}
	interests := make([]domain.Money, terms.Periods)
	if terms.InterestMode == "first" {
		interests[0] = terms.Interest
	} else {
		// 分摊各期金额并处理舍入差额。
		interests, err = splitInstallment(terms.Interest, terms)
		if err != nil {
			return plan, err
		}
	}
	// 按业务格式解析日期或时间。
	first, _ := time.Parse("2006-01-02", terms.FirstDate)
	plan.Total = 0
	var generatedPrincipal domain.Money
	for i := range principals {
		if i+1 < start {
			continue
		}
		// 固定原始日号，月末截断，防止 1 月 31 日跳过 2 月或此后持续漂移。
		month := time.Date(first.Year(), first.Month()+time.Month(i), 1, 0, 0, 0, 0, time.UTC)
		// 取得日期中的日，供周期边界计算。
		day := min(first.Day(), month.AddDate(0, 1, -1).Day())
		// 将业务时间转换为约定的存储或展示格式。
		date := month.AddDate(0, 0, day-1).Format("2006-01-02")
		// 检查日期是否满足业务格式。
		if !validDate(date) || principals[i]+interests[i] <= 0 {
			// 拒绝本次操作：每期金额须大于零，日期须在有效范围内。
			return plan, Invalid("每期金额须大于零，日期须在有效范围内")
		}
		plan.Total += principals[i] + interests[i]
		generatedPrincipal += principals[i]
		plan.Rows = append(plan.Rows, domain.InstallmentRow{Period: i + 1, Date: date, Principal: principals[i], Interest: interests[i], Amount: principals[i] + interests[i], Status: "pending"})
	}
	if terms.RestoredCredit > generatedPrincipal {
		// 拒绝本次操作：额度恢复不能超过待生成账单的本金合计。
		return plan, Invalid("额度恢复不能超过待生成账单的本金合计")
	}
	return plan, nil
}

// installment 读取、试算或原子转换支出；参数：db 为已锁定用户的事务，owner 为身份，op 为操作，in 含原账单 ID 和规则；返回值：计划或错误，失败全部回滚。
func installment(db *gorm.DB, owner uint64, op string, in Input) (domain.InstallmentPlan, error) {
	var bill domain.Transaction
	var plan domain.InstallmentPlan
	// 读取满足条件的目标记录。
	var err error
	bill, err = repository.ReadTransaction(db, owner, in.ID)
	if err != nil {
		// 将数据库查询失败转换为业务错误。
		return plan, missing(err)
	}
	if op == "finance.installment.plan" {
		if bill.InstallmentJSON == "" {
			return plan, ErrNotFound
		}
		// 解析已保存的计划，供后续校验与处理。
		if err := json.Unmarshal([]byte(bill.InstallmentJSON), &plan); err != nil {
			return plan, err
		}
		var children []domain.Transaction
		// 读取符合业务条件的记录集合。
		if err := repository.ReadInstallmentChildren(db, owner, bill.ID, &children); err != nil {
			return plan, err
		}
		for i := range plan.Rows {
			for _, child := range children {
				if child.InstallmentPeriod == plan.Rows[i].Period {
					plan.Rows[i].TransactionID = child.ID
					plan.Rows[i].Status = child.Status
					plan.Rows[i].Date = child.TransactionDate
					if child.Status == "posted" {
						plan.Posted++
					}
				}
			}
		}
		return plan, nil
	}
	var terms domain.InstallmentTerms
	// 严格解析业务输入，避免无效字段进入操作流程。
	if err := Decode(in.Changes, &terms); err != nil {
		return plan, err
	}
	// 已保存计划的编辑试算仅计算新规则，不撤销流水、不修改余额。
	if op == "finance.installment.preview" && bill.Status == "installment" && bill.InstallmentParentID == nil {
		// 按本金和分期条件计算计划。
		return calculateInstallment(bill.Amount, terms)
	}
	// 同规则重试返回已保存计划，拒绝将已转换账单再次拆分。
	if bill.InstallmentJSON != "" {
		// 解析已保存的计划，供后续校验与处理。
		if err := json.Unmarshal([]byte(bill.InstallmentJSON), &plan); err != nil {
			return plan, err
		}
		// 比较业务字段是否发生实际变化。
		if op == "finance.installment.create" && reflect.DeepEqual(plan.InstallmentTerms, terms) {
			// 执行分期业务操作并维护计划。
			return installment(db, owner, "finance.installment.plan", in)
		}
		return plan, ErrConflict
	}
	// 仅接收经过校验的资料字段；试算只修改内存，保存时与分期转换一起原子写入。
	fields := map[string]any{}
	if terms.CategoryID != nil {
		bill.CategoryID = nil
		if *terms.CategoryID != 0 {
			var category domain.Category
			// 读取满足条件的目标记录。
			var err error
			category, err = repository.ReadCategory(db, owner, *terms.CategoryID)
			if err != nil {
				// 将数据库查询失败转换为业务错误。
				return plan, missing(err)
			}
			if category.Type != "expense" {
				// 拒绝本次操作：分类类型不匹配。
				return plan, Invalid("分类类型不匹配")
			}
			bill.CategoryID = terms.CategoryID
		}
		fields["category_id"] = bill.CategoryID
	}
	if terms.Description != nil {
		// 检查文本长度与必填约束。
		if !validText(*terms.Description, 2000, false) {
			// 拒绝本次操作：账单备注不能超过 2000 字节。
			return plan, Invalid("账单备注不能超过 2000 字节")
		}
		bill.Description = *terms.Description
		fields["description"] = bill.Description
	}
	var refundCount int64
	// 统计符合条件的业务记录。
	if err := repository.CountRefunds(db, owner, bill.ID, &refundCount); err != nil {
		return plan, err
	}
	// 已退款支出与退款记录不能转为分期，避免再次释放已退回的余额。
	if bill.Type != "expense" || bill.Status != "posted" || bill.InstallmentParentID != nil || bill.RefundParentID != nil || refundCount > 0 {
		// 拒绝本次操作：仅普通已入账支出可以转分期。
		return plan, Invalid("仅普通已入账支出可以转分期")
	}
	// 按所属用户读取账户并检查可用状态。
	if _, err := account(db, owner, bill.AccountID, true); err != nil {
		return plan, err
	}
	// 按本金和分期条件计算计划。
	plan, err = calculateInstallment(bill.Amount, terms)
	if err != nil || op == "finance.installment.preview" {
		return plan, err
	}
	// 冲回原支出，再建立逐期待入账流水；外层事务保证不留下部分拆分或重复扣款。
	if err = apply(db, owner, bill, -1); err != nil {
		return plan, err
	}
	// 一次性计入只预记实际生成范围内本金；利息仍按每期确认，收支统计仍以子流水入账为准。
	if terms.DebtMode == "upfront" {
		var principal domain.Money
		for _, row := range plan.Rows {
			principal += row.Principal
		}
		// 将流水影响计入或冲回账户余额。
		if err = apply(db, owner, domain.Transaction{AccountID: bill.AccountID, Type: "expense", Amount: principal}, 1); err != nil {
			return plan, err
		}
	}
	for i := range plan.Rows {
		period := &plan.Rows[i]
		// 生成当前操作需要的展示或协议文本。
		child := domain.Transaction{OwnerID: owner, RequestID: fmt.Sprintf("installment_%d_%d", bill.ID, period.Period), AccountID: bill.AccountID, Type: "expense", Amount: period.Amount, CategoryID: bill.CategoryID, Counterparty: bill.Counterparty, TransactionDate: period.Date, Description: fmt.Sprintf("%s · %d/%d", terms.Name, period.Period, terms.Periods), Status: "pending", Source: "http", InstallmentParentID: &bill.ID, InstallmentPeriod: period.Period}
		if terms.Description != nil || bill.Description != "" {
			child.Description = bill.Description
		}
		// 保存新建的业务记录。
		if err = repository.CreateTransaction(db, &child); err != nil {
			return plan, err
		}
		period.TransactionID = child.ID
	}
	// 序列化业务数据，供存储或响应使用。
	data, err := json.Marshal(plan)
	if err != nil {
		return plan, err
	}
	fields["status"] = "installment"
	fields["installment_json"] = string(data)
	// 仅写入本次经过校验的变更字段。
	err = repository.UpdateTransaction(db, owner, bill.ID, fields)
	return plan, err
}

// attachInstallmentCredit 汇总剩余专项恢复额及预留利息；参数：db 为当前事务，owner 为账户所有者，accounts 为待展示账户；返回值：查询、数据解析或溢出错误，成功只更新展示字段，不改余额或授信。
func attachInstallmentCredit(db *gorm.DB, owner uint64, accounts []domain.Account) error {
	var parents []domain.Transaction
	// 读取符合业务条件的记录集合。
	if err := repository.ReadInstallmentParents(db, owner, &parents); err != nil {
		return err
	}
	var posted []domain.Transaction
	// 读取符合业务条件的记录集合。
	if err := repository.ReadAllInstallmentChildren(db, owner, &posted); err != nil {
		return err
	}
	// 已入账或删除的期次均不再占用待入账额度；删除不恢复专项额度，避免重复释放。
	paid := map[uint64]map[int]bool{}
	pending := map[uint64]map[int]bool{}
	for _, row := range posted {
		if paid[*row.InstallmentParentID] == nil {
			paid[*row.InstallmentParentID] = map[int]bool{}
		}
		paid[*row.InstallmentParentID][row.InstallmentPeriod] = row.Status == "posted" || row.Status == "deleted"
		if pending[*row.InstallmentParentID] == nil {
			pending[*row.InstallmentParentID] = map[int]bool{}
		}
		pending[*row.InstallmentParentID][row.InstallmentPeriod] = row.Status == "pending"
	}
	totals := map[uint64]domain.Money{}
	reserved := map[uint64]domain.Money{}
	pendingAmounts := map[uint64]domain.Money{}
	pendingInterest := map[uint64]domain.Money{}
	for _, parent := range parents {
		var plan domain.InstallmentPlan
		// 解析已保存的计划，供后续校验与处理。
		if err := json.Unmarshal([]byte(parent.InstallmentJSON), &plan); err != nil {
			return err
		}
		remaining := plan.RestoredCredit
		for _, row := range plan.Rows {
			if paid[parent.ID][row.Period] {
				remaining = max(0, remaining-row.Principal)
			} else if pending[parent.ID][row.Period] {
				pendingAmounts[parent.AccountID] += row.Amount
				pendingInterest[parent.AccountID] += row.Interest
				if plan.InterestCreditMode == "upfront" {
					reserved[parent.AccountID] += row.Interest
				}
			}
		}
		totals[parent.AccountID] += remaining
		if totals[parent.AccountID] > maxMoney || reserved[parent.AccountID] > maxMoney {
			// 拒绝本次操作：专项恢复额度超出上限。
			return Invalid("专项恢复额度超出上限")
		}
	}
	for i := range accounts {
		accounts[i].InstallmentPendingAmount = pendingAmounts[accounts[i].ID]
		accounts[i].InstallmentPendingInterest = pendingInterest[accounts[i].ID]
		accounts[i].InstallmentCredit = totals[accounts[i].ID]
		accounts[i].InstallmentInterestReserved = reserved[accounts[i].ID]
	}
	return nil
}

// postDueInstallments 自动入账到期分期；参数：db 为已持用户锁的事务，owner 为用户 ID，now 为判定日期的时间；返回值：数据库或入账错误，调用方必须回滚；按 UTC+8 日期补记历史，不处理普通草稿。
func (s *Service) postDueInstallments(db *gorm.DB, owner uint64, now time.Time) error {
	// 将业务时间转换为约定的存储或展示格式。
	today := now.In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02")
	var rows []domain.Transaction
	// 读取符合业务条件的记录集合。
	if err := repository.ReadDueInstallments(db, owner, today, &rows); err != nil {
		return err
	}
	// 复用入账事务逻辑，确保预记本金不会重复扣减；状态与余额一起提交，重试只读取尚未入账的期次。
	for _, row := range rows {
		// 执行流水状态迁移并协调余额变化。
		if _, err := s.transition(db, owner, "finance.transaction.confirm", row.ID); err != nil {
			return err
		}
		// 保存新建的业务记录。
		if err := repository.CreateEvent(db, &domain.Event{OwnerID: owner, EntityID: row.ID, Operation: "finance.installment.post-due", Source: "system"}); err != nil {
			return err
		}
	}
	return nil
}
