// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"time"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// statementClosing 获取自然月账单日；参数：month 为该月任意日期，day 为 1…31；返回值：短月截到月末的当地零点，无副作用。
func statementClosing(month time.Time, day int) time.Time {
	// 按业务周期边界构造日期。
	first := time.Date(month.Year(), month.Month(), 1, 0, 0, 0, 0, month.Location())
	// 取得日期中的日，供周期边界计算。
	last := first.AddDate(0, 1, -1).Day()
	// 按日历周期推算业务日期。
	return first.AddDate(0, 0, min(day, last)-1)
}

// creditStatement 汇总最近已出账期应还；参数：db 为用户锁事务，owner 为身份，id 为账户，now 为当前时间；返回值：账期及剩余应还或错误；归档和跨用户不可读，未配置账单日返回 configured=false。
func creditStatement(db *gorm.DB, owner, id uint64, now time.Time) (domain.CreditStatement, error) {
	result := domain.CreditStatement{}
	// 按所属用户读取账户并检查可用状态。
	a, err := account(db, owner, id, true)
	if err != nil {
		return result, err
	}
	if a.BillingDay < 1 || a.BillingDay > 31 {
		return result, nil
	}
	// 将时间转换到业务使用的时区。
	now = now.In(time.FixedZone("UTC+8", 28800))
	// 按业务周期边界构造日期。
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	// 按业务周期边界构造日期。
	month := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
	// 确定本周期的账单截止日期。
	closing := statementClosing(month, a.BillingDay)
	end := closing
	if !a.BillDayInclusive {
		// 按日历周期推算业务日期。
		end = end.AddDate(0, 0, -1)
	}
	// 包含账单日交易时须等当天结束再出账，避免当天新记流水改变一个已宣称固定的账期。
	if !end.Before(today) {
		// 按日历周期推算业务日期。
		month = month.AddDate(0, -1, 0)
		// 确定本周期的账单截止日期。
		closing = statementClosing(month, a.BillingDay)
		end = closing
		if !a.BillDayInclusive {
			// 按日历周期推算业务日期。
			end = end.AddDate(0, 0, -1)
		}
	}
	// 确定本周期的账单截止日期。
	start := statementClosing(month.AddDate(0, -1, 0), a.BillingDay)
	if a.BillDayInclusive {
		// 按日历周期推算业务日期。
		start = start.AddDate(0, 0, 1)
	}
	result.Configured = true
	// 将业务时间转换为约定的存储或展示格式。
	result.Month = month.Format("2006-01")
	// 将业务时间转换为约定的存储或展示格式。
	result.StartDate = start.Format("2006-01-02")
	// 将业务时间转换为约定的存储或展示格式。
	result.EndDate = end.Format("2006-01-02")
	var rows []domain.Transaction
	// 读取符合业务条件的记录集合。
	if err = repository.ReadAccountTransactions(db, owner, id, false, &rows); err != nil {
		return result, err
	}
	byID := map[uint64]domain.Transaction{}
	for _, row := range rows {
		byID[row.ID] = row
	}
	var unbilled, pendingPrincipal domain.Money
	plans := map[uint64]domain.InstallmentPlan{}
	for _, row := range rows {
		if row.Status == "installment" {
			var plan domain.InstallmentPlan
			// 解析已保存的计划，供后续校验与处理。
			if err = json.Unmarshal([]byte(row.InstallmentJSON), &plan); err != nil {
				return result, err
			}
			plans[row.ID] = plan
		}
	}
	for _, row := range rows {
		// 一次性预记欠款中的未入账本金尚未出账，必须剔除，不能据此要求用户提前偿还整笔分期。
		if row.Status == "pending" && row.InstallmentParentID != nil {
			plan := plans[*row.InstallmentParentID]
			if plan.DebtMode == "upfront" {
				for _, period := range plan.Rows {
					if period.Period == row.InstallmentPeriod {
						pendingPrincipal += period.Principal
						break
					}
				}
			}
		}
		if row.Status != "posted" || row.TransactionDate <= result.EndDate {
			continue
		}
		if row.RefundParentID != nil {
			// 未出账消费退款抵减未出账消费；已出账消费退款通过当前余额抵减应还。
			if parent, ok := byID[*row.RefundParentID]; ok && parent.TransactionDate > result.EndDate {
				unbilled += row.Amount
			}
		} else if row.Type == "expense" || row.Type == "transfer" {
			unbilled += row.Amount
		}
		unbilled += row.Fee
	}
	// 当前余额已包含还款、退款和优惠，按先偿还已出账欠款计算；保留开户/校准的历史欠款，剔除本期新消费及未来分期本金。
	result.RemainingAmount = max(0, -a.Balance-max(0, unbilled)-pendingPrincipal)
	return result, nil
}

// statementAmounts 按完整账本重建指定范围的已出账金额；参数：db 为用户锁事务，owner 为身份，id 为账户，filter 含有效起止自然日，now 为当前时间；返回值：以账期结束日为键的非负金额或错误；不含未来账期、不使用分页流水，不写数据库。
func statementAmounts(db *gorm.DB, owner, id uint64, filter Filter, now time.Time) (map[string]domain.Money, error) {
	result := map[string]domain.Money{}
	// 检查日期是否满足业务格式。
	if !validDate(filter.StartDate) || !validDate(filter.EndDate) || filter.StartDate > filter.EndDate {
		// 拒绝本次操作：账单日期范围无效。
		return nil, Invalid("账单日期范围无效")
	}
	// 按所属用户读取账户并检查可用状态。
	a, err := account(db, owner, id, true)
	if err != nil {
		return nil, err
	}
	if a.BillingDay < 1 || a.BillingDay > 31 {
		return result, nil
	}
	// 明确业务时间使用的固定时区。
	zone := time.FixedZone("UTC+8", 28800)
	// 在指定时区中解析业务日期。
	first, _ := time.ParseInLocation("2006-01-02", filter.StartDate, zone)
	// 在指定时区中解析业务日期。
	last, _ := time.ParseInLocation("2006-01-02", filter.EndDate, zone)
	// 按业务周期边界构造日期。
	first = time.Date(first.Year(), first.Month(), 1, 0, 0, 0, 0, zone)
	// 取得日期中的年份，供周期计算。
	if last.Year()-first.Year() > 100 {
		// 拒绝本次操作：账单日期范围过大。
		return nil, Invalid("账单日期范围过大")
	}
	var rows []domain.Transaction
	// 读取符合业务条件的记录集合。
	if err = repository.ReadAccountTransactions(db, owner, id, true, &rows); err != nil {
		return nil, err
	}
	plans := map[uint64]domain.InstallmentPlan{}
	for _, row := range rows {
		if row.Status == "installment" {
			var plan domain.InstallmentPlan
			// 解析已保存的计划，供后续校验与处理。
			if err = json.Unmarshal([]byte(row.InstallmentJSON), &plan); err != nil {
				return nil, err
			}
			plans[row.ID] = plan
		}
	}
	var pendingPrincipal domain.Money
	for _, row := range rows {
		if row.Status != "pending" || row.InstallmentParentID == nil {
			continue
		}
		plan := plans[*row.InstallmentParentID]
		if plan.DebtMode == "upfront" {
			for _, period := range plan.Rows {
				if period.Period == row.InstallmentPeriod {
					pendingPrincipal += period.Principal
					break
				}
			}
		}
	}
	// 将业务时间转换为约定的存储或展示格式。
	today := now.In(zone).Format("2006-01-02")
	// 账单日为 1 且不含当天时，结束日落在上个月，需多枚举一个账单月份。
	lastMonth := time.Date(last.Year(), last.Month()+1, 1, 0, 0, 0, 0, zone)
	// 检查日期是否超过业务边界。
	for month := first; !month.After(lastMonth); month = month.AddDate(0, 1, 0) {
		// 确定本周期的账单截止日期。
		end := statementClosing(month, a.BillingDay)
		if !a.BillDayInclusive {
			// 按日历周期推算业务日期。
			end = end.AddDate(0, 0, -1)
		}
		// 将业务时间转换为约定的存储或展示格式。
		key := end.Format("2006-01-02")
		if key < filter.StartDate || key > filter.EndDate || key >= today {
			continue
		}
		// 从当前欠款剔除尚未入账的预记本金，并逆向还原账期结束后的消费、退款、还款和手续费；还款不会篡改历史账单金额。
		amount := -a.Balance - pendingPrincipal
		for _, row := range rows {
			if row.Status != "posted" || row.TransactionDate <= key {
				continue
			}
			if row.AccountID == id {
				if row.Type == "income" {
					amount += row.Amount
				} else {
					amount -= row.Amount
				}
				amount -= row.Fee
			}
			if row.TargetAccountID != nil && *row.TargetAccountID == id {
				amount += row.Amount
			}
		}
		result[key] = max(0, amount)
	}
	return result, nil
}
