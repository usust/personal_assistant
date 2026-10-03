// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"gorm.io/gorm"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

type Service struct {
	db  *gorm.DB
	now func() time.Time
}

type Input struct {
	ID      uint64          `json:"id"`
	Changes json.RawMessage `json:"changes"`
	Filter  Filter          `json:"filter"`
}

// NewService 注入业务数据库；参数：db 必须非 nil 且已经迁移；返回值：服务，无数据库副作用。
func NewService(db *gorm.DB) *Service { return &Service{db: db, now: time.Now} }

// Execute 为 HTTP 与 AI 提供统一授权和事务入口；参数：ctx 控制取消，actor 为可信身份，op 为固定操作，in 为输入，source 为 http 或 ai；返回值：结果或业务/数据库错误，写操作原子提交。
func (s *Service) Execute(ctx context.Context, actor capability.Actor, op string, in Input, source string) (any, error) {
	if actor.UserID == 0 {
		return nil, ErrNotFound
	}
	if source != "http" && source != "ai" {
		// 拒绝本次操作：来源无效。
		return nil, Invalid("来源无效")
	}
	// AI 来源在业务层也采用最小权限白名单，防止未来新增适配器绕过草稿边界。
	if source == "ai" {
		switch op {
		case "finance.account.list", "finance.category.list", "finance.transaction.list", "finance.transaction.create", "finance.overview":
		default:
			// 拒绝本次操作：AI 仅可查询账本和创建待确认草稿。
			return nil, Invalid("AI 仅可查询账本和创建待确认草稿")
		}
	}
	// 让数据库操作遵循当前请求的生命周期。
	db := s.db
	var out any
	// 锁定操作者记录，串行化同一用户的余额、幂等键和状态变更；不同用户互不影响。
	// 事务回调参数 tx 为事务数据库；返回值：任意错误触发完整回滚，不会留下半笔转账。
	err := repository.Transaction(ctx, db, func(tx *gorm.DB) error {

		// 读取满足条件的目标记录。
		if e := repository.LockOwner(tx, actor.UserID); e != nil {
			// 将数据库查询失败转换为业务错误。
			return missing(e)
		}
		// 查询前补记到期分期，与用户锁、余额和响应保持同一事务；后台暂停或刚创建计划时也不会读到过期待入账状态。
		switch op {
		case "finance.account.list", "finance.account.statement", "finance.account.statements", "finance.transaction.list", "finance.transaction.get", "finance.transaction.summary", "finance.overview", "finance.installment.list", "finance.installment.plan":
			// 补记已到期的分期流水。
			if err := s.postDueInstallments(tx, actor.UserID, s.now()); err != nil {
				return err
			}
		}
		var e error
		switch op {
		case "finance.preset.list", "finance.preset.create", "finance.preset.update", "finance.preset.delete":
			// 执行预设业务操作。
			out, e = s.presets(tx, actor.UserID, op, in)
		case "finance.installment.list":
			// 读取账户关联的分期计划。
			out, e = listInstallments(tx, actor.UserID, in.Filter.AccountID)
		case "finance.installment.update", "finance.installment.delete", "finance.installment.finish":
			// 执行分期管理并协调关联流水。
			out, e = s.manageInstallment(tx, actor.UserID, op, in)
		case "finance.installment.post-due":
			// 补记已到期的分期流水。
			e = s.postDueInstallments(tx, actor.UserID, s.now())
		case "finance.recurring.materialize":
			// 将已到期的周期预设生成流水。
			e = s.materialize(tx, actor.UserID, time.Now())
		case "finance.installment.plan", "finance.installment.preview", "finance.installment.create":
			// 执行分期业务操作并维护计划。
			out, e = installment(tx, actor.UserID, op, in)
			// 创建历史分期时立即补记已到期项，保留原入账日期；必须在主计划快照落库后计算预记本金抵扣。
			if e == nil && op == "finance.installment.create" {
				// 补记已到期的分期流水。
				e = s.postDueInstallments(tx, actor.UserID, s.now())
				if e == nil {
					// 执行分期业务操作并维护计划。
					out, e = installment(tx, actor.UserID, "finance.installment.plan", Input{ID: in.ID})
				}
			}
		case "finance.loan.preview":
			// 仅计算贷款预览，不写入账户。
			out, e = loanPreview(in.Changes)
		case "finance.loan.plan", "finance.loan.adjustment.preview", "finance.loan.adjustment.save":
			// 执行贷款调整并保存计划变化。
			out, e = loanAdjustment(tx, actor.UserID, op, in)
		case "finance.account.statements":
			// 汇总各账户对应的账单金额。
			out, e = statementAmounts(tx, actor.UserID, in.ID, in.Filter, time.Now())
		case "finance.account.statement":
			// 按信用账户账单周期计算债务信息。
			out, e = creditStatement(tx, actor.UserID, in.ID, time.Now())
		case "finance.account.list":
			rows, queryErr := repository.ReadAccounts(tx, actor.UserID)
			e = queryErr
			for i := range rows {
				rows[i].AvailableBalance = rows[i].Balance
				// 为账户补充贷款计划展示数据。
				attachLoanPlan(&rows[i])
			}
			if e == nil {
				// 将未结分期纳入信用账户展示。
				e = attachInstallmentCredit(tx, actor.UserID, rows)
			}
			out = rows
		case "finance.account.create", "finance.account.update":
			// 执行账户创建或部分更新。
			out, e = s.saveAccount(tx, actor.UserID, op, in)
		case "finance.account.impact", "finance.account.archive":
			// 执行资源归档并处理业务约束。
			out, e = s.archive(tx, actor.UserID, op, in.ID)
		case "finance.category.list":
			// 确保用户拥有业务所需的分类目录。
			if e = ensureCategories(tx, actor.UserID); e != nil {
				return e
			}
			rows, queryErr := repository.ReadCategories(tx, actor.UserID)
			e = queryErr
			out = rows
		case "finance.category.create":
			// 校验并创建用户分类。
			out, e = s.createCategory(tx, actor.UserID, in.Changes)
		case "finance.transaction.get":
			// 读取当前用户可访问的目标流水。
			out, e = getTransaction(tx, actor.UserID, in.ID)
		case "finance.transaction.list":
			// 按当前用户和筛选条件读取流水。
			out, e = listTransactions(tx, actor.UserID, in.Filter)
		case "finance.transaction.create":
			// 创建流水并协调关联记账影响。
			out, e = s.createTransaction(tx, actor.UserID, in.Changes, source)
		case "finance.transaction.confirm", "finance.transaction.void":
			if source == "ai" {
				// 拒绝本次操作：确认和作废只能由用户在财务页面执行。
				return Invalid("确认和作废只能由用户在财务页面执行")
			}
			// 执行流水状态迁移并协调余额变化。
			out, e = s.transition(tx, actor.UserID, op, in.ID)
		case "finance.transaction.refund":
			// 按业务规则创建退款并调整关联金额。
			out, e = s.refundTransaction(tx, actor.UserID, in)
		case "finance.transaction.delete":
			// 删除流水并撤销相关记账影响。
			out, e = s.deleteTransaction(tx, actor.UserID, in.ID)
		case "finance.transaction.update":
			// 执行流水编辑并同步相关记账数据。
			out, e = s.updateTransaction(tx, actor.UserID, in)
		case "finance.transaction.summary":
			// 汇总筛选范围内的流水金额。
			out, e = transactionSummary(tx, actor.UserID, in.Filter)
		case "finance.overview":
			// 计算当前用户的财务概览。
			out, e = overview(tx, actor.UserID)
		case "finance.events":
			rows, queryErr := repository.ReadEvents(tx, actor.UserID)
			e = queryErr
			out = rows
		default:
			// 拒绝本次操作：不支持的财务操作。
			return Invalid("不支持的财务操作")
		}
		if e != nil {
			return e
		}
		// 检查输入是否符合预期后缀。
		if op == "finance.transaction.summary" || op == "finance.account.statements" || op == "finance.account.statement" || op == "finance.transaction.get" || op == "finance.installment.post-due" || op == "finance.recurring.materialize" || strings.HasSuffix(op, ".preview") || op == "finance.loan.plan" || op == "finance.installment.plan" || strings.HasSuffix(op, ".list") || op == "finance.overview" || op == "finance.events" || strings.HasSuffix(op, ".impact") {
			return nil
		}
		id := in.ID
		switch row := out.(type) {
		case domain.Account:
			id = row.ID
		case domain.Transaction:
			id = row.ID
		case domain.Category:
			id = row.ID
		case domain.Preset:
			id = row.ID
		}
		// 保存新建的业务记录。
		return repository.CreateEvent(tx, &domain.Event{OwnerID: actor.UserID, EntityID: id, Operation: op, Source: source})
	})
	return out, err
}
