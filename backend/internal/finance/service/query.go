// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"time"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// 预编译业务字段校验规则。
var colorPattern = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

type Filter struct {
	StartDate  string `json:"startDate"`
	EndDate    string `json:"endDate"`
	Type       string `json:"type"`
	AccountID  uint64 `json:"accountId"`
	CategoryID uint64 `json:"categoryId"`
	MinAmount  string `json:"minAmount"`
	MaxAmount  string `json:"maxAmount"`
	Keyword    string `json:"keyword"`
	Status     string `json:"status"`
	Limit      int    `json:"limit"`
	Offset     int    `json:"offset"`
}

// listTransactions 查询用户流水；参数：db 为数据库，owner 为认证身份，f 为筛选（包含目标账户）；返回值：按交易日期、时分及 ID 倒序的数组或校验错误，默认每页 100 条，最多 500 条。
func listTransactions(db *gorm.DB, owner uint64, f Filter) ([]domain.Transaction, error) {
	rows := []domain.Transaction{}
	// 检查日期是否满足业务格式。
	if (f.StartDate != "" && !validDate(f.StartDate)) || (f.EndDate != "" && !validDate(f.EndDate)) || (f.StartDate != "" && f.EndDate != "" && f.StartDate > f.EndDate) {
		// 拒绝本次操作：日期筛选无效。
		return nil, Invalid("日期筛选无效")
	}
	if f.Type != "" && f.Type != "income" && f.Type != "expense" && f.Type != "transfer" {
		// 拒绝本次操作：类型筛选无效。
		return nil, Invalid("类型筛选无效")
	}
	if f.Status != "" && f.Status != "pending" && f.Status != "posted" && f.Status != "voided" && f.Status != "installment" {
		// 拒绝本次操作：状态筛选无效。
		return nil, Invalid("状态筛选无效")
	}
	if f.Limit < 0 || f.Limit > 500 || f.Offset < 0 || f.Offset > 1000000 || len(f.Keyword) > 128 {
		// 拒绝本次操作：分页或关键词无效。
		return nil, Invalid("分页或关键词无效")
	}
	if f.Limit == 0 {
		f.Limit = 100
	}
	var min, max domain.Money
	if f.MinAmount != "" {
		var e error
		// 按精确金额格式解析输入。
		min, e = domain.ParseMoney(f.MinAmount)
		if e != nil || min < 0 {
			// 拒绝本次操作：最低金额无效。
			return nil, Invalid("最低金额无效")
		}
	}
	if f.MaxAmount != "" {
		var e error
		// 按精确金额格式解析输入。
		max, e = domain.ParseMoney(f.MaxAmount)
		if e != nil || max < 0 {
			// 拒绝本次操作：最高金额无效。
			return nil, Invalid("最高金额无效")
		}
	}
	if f.MinAmount != "" && f.MaxAmount != "" && min > max {
		// 拒绝本次操作：最低金额不得大于最高金额。
		return nil, Invalid("最低金额不得大于最高金额")
	}
	// 仓储只接收已校验筛选；分页与关键词转义属于持久化职责。
	e := repository.QueryTransactions(db, owner, repository.TransactionFilter{StartDate: f.StartDate, EndDate: f.EndDate, Type: f.Type, Status: f.Status, Keyword: f.Keyword, AccountID: f.AccountID, CategoryID: f.CategoryID, Min: min, Max: max, HasMin: f.MinAmount != "", HasMax: f.MaxAmount != "", Limit: f.Limit, Offset: f.Offset}, &rows)
	if e != nil {
		return nil, e
	}
	// 一次批量查询关联计划，兼容旧子流水，避免逐行请求及在备注中猜测期数。
	ids := []uint64{}
	for _, row := range rows {
		if row.InstallmentParentID != nil {
			ids = append(ids, *row.InstallmentParentID)
		}
	}
	if len(ids) > 0 {
		var parents []domain.Transaction
		// 读取符合业务条件的记录集合。
		if err := repository.ReadTransactionsByIDs(db, owner, ids, &parents); err != nil {
			return nil, err
		}
		plans := map[uint64]domain.InstallmentPlan{}
		for _, parent := range parents {
			var plan domain.InstallmentPlan
			// 解析已保存的计划，供后续校验与处理。
			if err := json.Unmarshal([]byte(parent.InstallmentJSON), &plan); err != nil {
				return nil, err
			}
			plans[parent.ID] = plan
		}
		for i := range rows {
			if rows[i].InstallmentParentID != nil {
				plan := plans[*rows[i].InstallmentParentID]
				rows[i].InstallmentPeriods = plan.Periods
				rows[i].InstallmentName = plan.Name
			}
		}
	}
	return rows, nil
}

// overview 汇总全部已入账流水而非列表分页；参数：db 为数据库，owner 为身份；返回值：CNY 总览或数据库错误，月份使用 UTC+8，转账与草稿/作废排除收支。
func overview(db *gorm.DB, owner uint64) (domain.Overview, error) {
	out := domain.Overview{Currency: "CNY", Timezone: "Asia/Shanghai", AssetStructure: []domain.Metric{}, CashFlow: []domain.CashFlow{}, ExpenseCategories: []domain.Metric{}, NetWorthTrend: []any{}, Upcoming: []any{}}
	accounts := []domain.Account{}
	// 读取符合业务条件的记录集合。
	if e := repository.ReadActiveAccounts(db, owner, &accounts); e != nil {
		return out, e
	}
	out.AccountCount = len(accounts)
	for _, a := range accounts {
		if !a.IncludeInNetWorth {
			continue
		}
		// 贷款采用未还期次的本息欠款，与账户列表保持一致；只替换局部统计值，不回写流水余额。
		if a.Institution == "贷款" && a.LoanPrincipal > 0 {
			// 读取账户保存的贷款计划。
			plan, err := accountLoanPlan(a)
			if err != nil {
				return out, err
			}
			a.Balance = -plan.RemainingTotal
		}
		if a.Balance >= 0 {
			if out.TotalAssets > domain.Money(math.MaxInt64)-a.Balance {
				// 拒绝本次操作：汇总金额超出范围。
				return out, Invalid("汇总金额超出范围")
			}
			out.TotalAssets += a.Balance
			if a.Balance > 0 {
				out.AssetStructure = append(out.AssetStructure, domain.Metric{Name: a.Name, Amount: a.Balance})
			}
		} else {
			if out.TotalLiabilities > domain.Money(math.MaxInt64)+a.Balance {
				// 拒绝本次操作：汇总金额超出范围。
				return out, Invalid("汇总金额超出范围")
			}
			out.TotalLiabilities -= a.Balance
		}
	}
	out.NetWorth = out.TotalAssets - out.TotalLiabilities
	// 将时间转换到业务使用的时区。
	now := time.Now().In(time.FixedZone("UTC+8", 8*3600))
	// 按业务周期边界构造日期。
	month := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, now.Location())
	for offset := -5; offset <= 0; offset++ {
		// 按日历周期推算业务日期。
		start := month.AddDate(0, offset, 0)
		// 按日历周期推算业务日期。
		end := start.AddDate(0, 1, 0)
		var sums []struct {
			Type  string
			Total domain.Money
		}
		// 将查询结果映射为业务展示结构。
		e := repository.SumTypes(db, owner, start.Format("2006-01-02"), end.Format("2006-01-02"), &sums)
		if e != nil {
			return out, e
		}
		// 将业务时间转换为约定的存储或展示格式。
		point := domain.CashFlow{Month: start.Format("2006-01")}
		for _, sum := range sums {
			if sum.Type == "income" {
				point.Income = sum.Total
			} else {
				point.Expense = sum.Total
			}
		}
		var fees domain.Money
		// 将查询结果映射为业务展示结构。
		if e := repository.SumFees(db, owner, start.Format("2006-01-02"), end.Format("2006-01-02"), &fees); e != nil {
			return out, e
		}
		point.Expense += fees
		point.Net = point.Income - point.Expense
		out.CashFlow = append(out.CashFlow, point)
		if offset == 0 {
			out.MonthIncome = point.Income
			out.MonthExpense = point.Expense
			out.MonthBalance = point.Net
		}
	}
	var categories []domain.Category
	// 读取符合业务条件的记录集合。
	if e := repository.FindCategories(db, owner, &categories); e != nil {
		return out, e
	}
	byID := map[uint64]domain.Category{}
	for _, c := range categories {
		byID[c.ID] = c
	}
	var sums []struct {
		CategoryID *uint64
		Total      domain.Money
	}
	// 将查询结果映射为业务展示结构。
	if e := repository.SumCategories(db, owner, month.Format("2006-01-02"), month.AddDate(0, 1, 0).Format("2006-01-02"), &sums); e != nil {
		return out, e
	}
	for _, sum := range sums {
		m := domain.Metric{Name: "未分类", Amount: sum.Total, Color: "#94a3b8"}
		if sum.CategoryID != nil {
			if c, ok := byID[*sum.CategoryID]; ok {
				m.Name = c.Name
				m.Color = c.Color
			}
		}
		out.ExpenseCategories = append(out.ExpenseCategories, m)
	}
	var fees domain.Money
	// 将查询结果映射为业务展示结构。
	if e := repository.SumFees(db, owner, month.Format("2006-01-02"), month.AddDate(0, 1, 0).Format("2006-01-02"), &fees); e != nil {
		return out, e
	}
	if fees > 0 {
		out.ExpenseCategories = append(out.ExpenseCategories, domain.Metric{Name: "转账手续费", Amount: fees, Color: "#94a3b8"})
	}
	if out.MonthIncome > 0 {
		// 生成当前操作需要的展示或协议文本。
		rate := fmt.Sprintf("%.2f", float64(out.MonthBalance)*100/float64(out.MonthIncome))
		out.SavingsRate = &rate
	}
	if out.TotalAssets > 0 {
		// 生成当前操作需要的展示或协议文本。
		ratio := fmt.Sprintf("%.2f", float64(out.TotalLiabilities)*100/float64(out.TotalAssets))
		out.DebtRatio = &ratio
	}
	return out, nil
}

// getTransaction 读取单笔可见流水及分期展示信息；参数：db 为数据库，owner 为可信用户身份，id 为流水 ID；返回值：流水或错误，跨用户及已删除记录均返回不存在，无写入。
func getTransaction(db *gorm.DB, owner, id uint64) (domain.Transaction, error) {
	var row domain.Transaction
	// 读取满足条件的目标记录。
	if err := repository.FindVisibleTransaction(db, owner, id, &row); err != nil {
		// 将数据库查询失败转换为业务错误。
		return row, missing(err)
	}
	if row.InstallmentParentID != nil {
		var parent domain.Transaction
		// 读取满足条件的目标记录。
		var err error
		parent, err = repository.ReadTransaction(db, owner, *row.InstallmentParentID)
		if err != nil {
			// 将数据库查询失败转换为业务错误。
			return row, missing(err)
		}
		var plan domain.InstallmentPlan
		// 解析已保存的计划，供后续校验与处理。
		if err := json.Unmarshal([]byte(parent.InstallmentJSON), &plan); err != nil {
			return row, err
		}
		row.InstallmentName = plan.Name
		row.InstallmentPeriods = plan.Periods
	}
	return row, nil
}
