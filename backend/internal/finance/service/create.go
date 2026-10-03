// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// saveAccount 保存白名单字段；参数：db 为事务，owner 为身份，op 为创建或更新，in 含字段与目标 ID；返回值：账户或错误，更新严格通过 map；欠款校准生成快照且不计收支；普通账户的校准独立于待确认流水与消费分期，贷款账户保留待确认校验。
func (s *Service) saveAccount(db *gorm.DB, owner uint64, op string, in Input) (domain.Account, error) {
	create := op == "finance.account.create"
	// 校验账户字段并构建本次允许写入的更新集合。
	fields, e := accountFields(in.Changes, create)
	if e != nil {
		return domain.Account{}, e
	}
	a := domain.Account{OwnerID: owner, AccountType: "cash", Currency: "CNY", IncludeInNetWorth: true, Selectable: true, BillDayInclusive: true}
	if create {
		// 保存新建的业务记录。
		if e = repository.CreateAccount(db, &a); e != nil {
			return a, e
		}
	} else {
		// 按所属用户读取账户并检查可用状态。
		a, e = account(db, owner, in.ID, true)
		if e != nil {
			return a, e
		}
	}
	previousBalance := a.Balance
	if !create {
		// 禁止普通字段更新破坏已发生的还款历史。
		if e = protectLoanHistory(a, fields); e != nil {
			return a, e
		}
	}
	// 判断是否需要重算贷款计划。
	if loanChanged(fields) {
		fields["loan_revision"] = a.LoanRevision + 1
	}
	if next, ok := fields["balance"].(domain.Money); !create && a.Institution == "贷款" && ok && next != previousBalance {
		// 贷款剩余本金沿用专用还款流程的保护；信用卡等账户直接校准余额，不修改草稿或分期计划。
		var pending int64
		// 统计符合条件的业务记录。
		if e = repository.CountPendingAccountTransactions(db, owner, a.ID, &pending); e != nil {
			return a, e
		}
		if pending > 0 {
			// 拒绝本次操作：请先处理该账户的待确认流水，再修改当前欠款。
			return a, Invalid("请先处理该账户的待确认流水，再修改当前欠款")
		}
	}
	// 仅写入本次经过校验的变更字段。
	if e = repository.UpdateAccount(db, owner, a.ID, fields); e != nil {
		return a, e
	}
	// 按所属用户读取账户并检查可用状态。
	a, e = account(db, owner, a.ID, true)
	if e != nil {
		return a, e
	}
	// 判断是否需要重算贷款计划。
	if loanChanged(fields) || (create && a.Institution == "贷款") {
		// 验证贷款账户条件并生成计划。
		plan, err := validateLoanAccount(db, a)
		if err != nil {
			return a, err
		}
		if create && a.Institution == "贷款" && plan == nil {
			// 拒绝本次操作：请填写贷款还款计划。
			return a, Invalid("请填写贷款还款计划")
		}
		a.LoanPlan = plan
		// 首次录入已还期数就冻结计划，后来清零已还期数也不能重新解释历史。
		if plan != nil && a.LoanPaidPeriods > 0 && a.LoanScheduleJSON == "" {
			// 序列化业务数据，供存储或响应使用。
			encoded, err := json.Marshal(plan.Schedule)
			if err != nil {
				return a, err
			}
			a.LoanScheduleJSON = string(encoded)
			// 仅写入本次经过校验的变更字段。
			if e = repository.UpdateAccount(db, owner, a.ID, map[string]any{"loan_schedule_json": a.LoanScheduleJSON}); e != nil {
				return a, e
			}
		}
		if create && plan != nil {
			if _, supplied := fields["balance"]; !supplied {
				a.Balance = -plan.RemainingPrincipal
				a.AvailableBalance = a.Balance
				// 仅写入本次经过校验的变更字段。
				if e = repository.UpdateAccount(db, owner, a.ID, map[string]any{"balance": a.Balance}); e != nil {
					return a, e
				}
			}
		}
	}
	// 实际剩余本金不允许为负；仅对显式余额校准验证，避免改资料时重写历史数据。
	if _, submitted := fields["balance"]; submitted && a.Institution == "贷款" && a.Balance > 0 {
		// 拒绝本次操作：贷款剩余本金不能为负数。
		return a, Invalid("贷款剩余本金不能为负数")
	}
	if a.ReminderDays >= 0 && a.RepaymentDay == 0 && a.LoanPrincipal == 0 {
		// 拒绝本次操作：请先设置还款日期。
		return a, Invalid("请先设置还款日期")
	}
	if create || a.Balance != previousBalance {
		// 保存新建的业务记录。
		e = repository.CreateSnapshot(db, &domain.Snapshot{OwnerID: owner, AccountID: a.ID, Balance: a.Balance})
		if e == nil && create {
			// 确保用户拥有业务所需的分类目录。
			e = ensureCategories(db, owner)
		}
	}
	return a, e
}

// createCategory 新建个人分类；参数：db 为事务，owner 为身份，raw 为 name/type/color 及可选 groupKey/icon 对象；返回值：分类或错误，同名同类型冲突。
func (s *Service) createCategory(db *gorm.DB, owner uint64, raw json.RawMessage) (domain.Category, error) {
	var in struct {
		GroupKey string `json:"groupKey"`
		Icon     string `json:"icon"`
		Name     string `json:"name"`
		Type     string `json:"type"`
		Color    string `json:"color"`
	}
	// 严格解析业务输入，避免无效字段进入操作流程。
	if e := Decode(raw, &in); e != nil {
		return domain.Category{}, e
	}
	// 规范化输入，避免首尾空白影响校验。
	in.Name = strings.TrimSpace(in.Name)
	// 检查分类分组与图标组合。
	if e := validateCategoryPresentation(in.Type, in.GroupKey, in.Icon); e != nil {
		return domain.Category{}, e
	}
	// 检查文本长度与必填约束。
	if !validText(in.Name, 64, true) || (in.Type != "income" && in.Type != "expense") {
		// 拒绝本次操作：分类名称或类型无效。
		return domain.Category{}, Invalid("分类名称或类型无效")
	}
	if in.Color == "" {
		in.Color = "#5658cf"
	}
	// 检查字段是否符合约定格式。
	if !colorPattern.MatchString(in.Color) {
		// 拒绝本次操作：颜色必须为 #RRGGBB。
		return domain.Category{}, Invalid("颜色必须为 #RRGGBB")
	}
	var count int64
	// 统计符合条件的业务记录。
	if e := repository.CountCategoryByName(db, owner, in.Name, in.Type, &count); e != nil {
		return domain.Category{}, e
	}
	if count > 0 {
		return domain.Category{}, ErrConflict
	}
	row := domain.Category{OwnerID: owner, Name: in.Name, Type: in.Type, Color: in.Color, GroupKey: in.GroupKey, Icon: in.Icon}
	// 保存新建的业务记录。
	e := repository.CreateCategory(db, &row)
	return row, e
}

// createTransaction 创建或幂等重放流水；参数：db 为事务，owner 为身份，raw 为字段，source 为可信来源；返回值：流水或冲突，AI 来源只产生待确认草稿。
func (s *Service) createTransaction(db *gorm.DB, owner uint64, raw json.RawMessage, source string) (domain.Transaction, error) {
	var in domain.TransactionInput
	// 严格解析业务输入，避免无效字段进入操作流程。
	if e := Decode(raw, &in); e != nil {
		return domain.Transaction{}, e
	}
	// 确认输入满足当前业务约束。
	if e := validateTransactionInput(in); e != nil {
		return domain.Transaction{}, e
	}
	// 序列化业务数据，供存储或响应使用。
	canonical, _ := json.Marshal(in)
	// 生成当前操作需要的展示或协议文本。
	hash := fmt.Sprintf("%x", sha256.Sum256(canonical))
	var existing domain.Transaction
	// 读取满足条件的目标记录。
	e := repository.FindRequestTransaction(db, owner, in.RequestID, &existing)
	if e == nil {
		if existing.Fingerprint != hash || existing.Source != source {
			// 为失败补充当前操作的错误上下文。
			return domain.Transaction{}, fmt.Errorf("%w: requestId 已用于不同内容或来源", ErrConflict)
		}
		return existing, nil
	}
	// 区分预期错误与需要继续上报的异常。
	if !errors.Is(e, gorm.ErrRecordNotFound) {
		return domain.Transaction{}, e
	}
	// 确认交易引用的账户与分类属于当前用户。
	if e = validateReferences(db, owner, in); e != nil {
		return domain.Transaction{}, e
	}
	row := domain.Transaction{Rebate: in.Rebate, RebateAccountID: in.RebateAccountID, RebatePending: in.RebatePending, Fee: in.Fee, OwnerID: owner, RequestID: in.RequestID, Fingerprint: hash, AccountID: in.AccountID, TargetAccountID: in.TargetAccountID, Type: in.Type, Amount: in.Amount - in.Discount, Discount: in.Discount, CategoryID: in.CategoryID, Counterparty: in.Counterparty, TransactionDate: in.TransactionDate, TransactionTime: in.TransactionTime, Description: in.Description, Source: source, Status: "posted"}
	if row.Rebate > 0 && row.RebateAccountID == nil {
		row.RebateAccountID = &row.AccountID
	}
	if source == "ai" || source == "recurring" {
		row.Status = "pending"
	}
	// 保存新建的业务记录。
	if e = repository.CreateTransaction(db, &row); e != nil {
		return row, e
	}
	if row.Status == "posted" {
		// 将流水影响计入或冲回账户余额。
		e = apply(db, owner, row, 1)
		if e == nil {
			// 为主流水建立关联返利。
			e = createRebate(db, owner, row)
		}
	}
	return row, e
}

// ensureCategories 补齐内置收支分类；参数：db 为已锁定用户记录的事务，owner 为身份；返回值：数据库错误或 nil；仅插入缺失的同类型同名分类，不覆盖已有 ID、图标或自定义资料。
func ensureCategories(db *gorm.DB, owner uint64) error {
	var existing []domain.Category
	// 读取符合业务条件的记录集合。
	if err := repository.FindCategories(db, owner, &existing); err != nil {
		return err
	}
	known := make(map[string]bool, len(existing))
	for _, row := range existing {
		known[row.Type+"|"+row.Name] = true
	}
	var missing []domain.Category
	for _, row := range builtinCategories {
		key := row.Type + "|" + row.Name
		if known[key] {
			continue
		}
		known[key] = true
		row.OwnerID = owner
		row.IsDefault = true
		missing = append(missing, row)
	}
	// 批量补齐与当前查询或开户共用事务，失败整体回滚；用户行锁防止并发重复初始化。
	if len(missing) == 0 {
		return nil
	}
	// 批量保存本次生成的业务记录。
	return repository.CreateCategories(db, missing)
}
