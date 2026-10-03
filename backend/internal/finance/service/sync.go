// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"gorm.io/gorm"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// SyncCommand 只接收白名单业务操作，身份完全来自认证上下文。
type SyncCommand struct {
	OperationID string          `json:"operationId"`
	Operation   string          `json:"operation"`
	ID          uint64          `json:"id"`
	Body        json.RawMessage `json:"body"`
}

// SyncExecute 原子执行操作并保存幂等回执；参数：ctx 为取消上下文，owner 为认证用户，command 为稳定操作标识和业务参数；返回值：原始业务 JSON 或校验/事务错误，同键异内容拒绝，失败不保留半成品。
func (s *Service) SyncExecute(ctx context.Context, owner uint64, command SyncCommand) (json.RawMessage, error) {
	// 检查字段是否符合约定格式。
	if owner == 0 || !regexp.MustCompile(`^[A-Za-z0-9_-]{8,96}$`).MatchString(command.OperationID) {
		// 拒绝本次操作：同步标识无效。
		return nil, Invalid("同步标识无效")
	}
	switch command.Operation {
	case "finance.account.create", "finance.account.update", "finance.account.archive", "finance.category.create", "finance.transaction.create", "finance.transaction.update", "finance.transaction.confirm", "finance.transaction.void", "finance.transaction.delete", "finance.transaction.refund", "finance.preset.create", "finance.preset.update", "finance.preset.delete", "finance.installment.create", "finance.installment.update", "finance.installment.delete", "finance.installment.finish", "finance.loan.adjustment.save":
	default:
		// 拒绝本次操作：不支持的同步操作。
		return nil, Invalid("不支持的同步操作")
	}
	// 规范化 JSON 对象键顺序，客户端重新编码同一正文不应被视为另一笔操作。
	var body any
	// 解析请求字段集合，供后续校验与处理。
	if err := json.Unmarshal(command.Body, &body); err != nil {
		// 拒绝本次操作：同步正文无效。
		return nil, Invalid("同步正文无效")
	}
	// 序列化业务数据，供存储或响应使用。
	canonical, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	// 生成当前操作需要的展示或协议文本。
	fingerprint := fmt.Sprintf("%x", sha256.Sum256(append([]byte(fmt.Sprintf("%s:%d:", command.Operation, command.ID)), canonical...)))
	var result json.RawMessage
	// 事务回调输入 tx 为当前连接；返回错误时业务和回执共同回滚，用户行锁串行化并发重试。
	err = repository.Transaction(ctx, s.db, func(tx *gorm.DB) error {

		// 读取满足条件的目标记录。
		if err := repository.LockOwner(tx, owner); err != nil {
			// 将数据库查询失败转换为业务错误。
			return missing(err)
		}

		// 读取满足条件的目标记录。
		receipt, err := repository.ReadReceipt(tx, owner, command.OperationID)
		if err == nil {
			if receipt.Fingerprint != fingerprint {
				return ErrConflict
			}
			result = json.RawMessage(receipt.Result)
			return nil
		}
		// 区分预期错误与需要继续上报的异常。
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		nested := &Service{db: tx, now: s.now}
		var out any
		// 分类目录以用户、名称和收支类型唯一；游客分类遇到已存在目录时引用现有项，账户绝不按名称合并。
		var categoryInput struct {
			Name string `json:"name"`
			Type string `json:"type"`
		}
		if command.Operation == "finance.category.create" {
			// 解析业务数据，供后续校验与处理。
			_ = json.Unmarshal(canonical, &categoryInput)
			var category domain.Category
			// 读取满足条件的目标记录。
			err = repository.FindCategoryByName(tx, owner, strings.TrimSpace(categoryInput.Name), categoryInput.Type, &category)
			if err == nil {
				out = category
				// 区分预期错误与需要继续上报的异常。
			} else if !errors.Is(err, gorm.ErrRecordNotFound) {
				return err
			}
		}
		if out == nil {
			// 将业务操作交给共享服务执行。
			out, err = nested.Execute(ctx, capability.Actor{UserID: owner}, command.Operation, Input{ID: command.ID, Changes: canonical}, "http")
		} else {
			err = nil
		}
		if err != nil {
			return err
		}
		// 序列化业务数据，供存储或响应使用。
		result, err = json.Marshal(out)
		if err != nil {
			return err
		}
		// 保存新建的业务记录。
		return repository.CreateReceipt(tx, &domain.SyncReceipt{OwnerID: owner, OperationID: command.OperationID, Fingerprint: fingerprint, Result: string(result)})
	})
	return result, err
}

// SyncSnapshot 返回同一用户锁事务中的完整账本；参数：ctx 为请求上下文，owner 为认证用户；返回值：包含隐藏账户和删除状态的快照或错误，无跨用户数据。首版全量替换避免时间戳分页遗漏，派生分期先补记。
func (s *Service) SyncSnapshot(ctx context.Context, owner uint64) (map[string]any, error) {
	result := map[string]any{}
	// 快照回调输入 tx 为锁定用户的事务；输出错误回滚到期入账，所有集合来自同一账本时点。
	err := repository.Transaction(ctx, s.db, func(tx *gorm.DB) error {

		if owner == 0 {
			return ErrNotFound
		}
		// 读取满足条件的目标记录。
		if err := repository.LockOwner(tx, owner); err != nil {
			// 将数据库查询失败转换为业务错误。
			return missing(err)
		}
		// 确保用户拥有业务所需的分类目录。
		if err := ensureCategories(tx, owner); err != nil {
			return err
		}
		// 补记已到期的分期流水。
		if err := s.postDueInstallments(tx, owner, s.now()); err != nil {
			return err
		}
		// 将已到期的周期预设生成流水。
		if err := s.materialize(tx, owner, s.now()); err != nil {
			return err
		}
		accounts := []domain.Account{}
		categories := []domain.Category{}
		transactions := []domain.Transaction{}
		// 读取符合业务条件的记录集合。
		if err := repository.ReadSnapshotAccounts(tx, owner, &accounts); err != nil {
			return err
		}
		for i := range accounts {
			accounts[i].AvailableBalance = accounts[i].Balance
			// 为账户补充贷款计划展示数据。
			attachLoanPlan(&accounts[i])
		}
		// 将未结分期纳入信用账户展示。
		if err := attachInstallmentCredit(tx, owner, accounts); err != nil {
			return err
		}
		// 读取符合业务条件的记录集合。
		if err := repository.ReadSnapshotCategorys(tx, owner, &categories); err != nil {
			return err
		}
		// 读取符合业务条件的记录集合。
		if err := repository.ReadSnapshotTransactions(tx, owner, &transactions); err != nil {
			return err
		}
		// 执行预设业务操作。
		presets, err := s.presets(tx, owner, "finance.preset.list", Input{})
		if err != nil {
			return err
		}
		result["accounts"] = accounts
		result["categories"] = categories
		result["transactions"] = transactions
		result["presets"] = presets
		plans := map[string]any{}
		for i := range transactions {
			if transactions[i].Status == "installment" {
				// 执行分期业务操作并维护计划。
				plan, e := installment(tx, owner, "finance.installment.plan", Input{ID: transactions[i].ID})
				if e != nil {
					return e
				}
				// 将字段值转换为文本表示。
				plans[fmt.Sprint(transactions[i].ID)] = plan
			}
		}
		for i := range transactions {
			if parent := transactions[i].InstallmentParentID; parent != nil {
				// 将字段值转换为文本表示。
				if raw, ok := plans[fmt.Sprint(*parent)]; ok {
					// 序列化业务数据，供存储或响应使用。
					encoded, e := json.Marshal(raw)
					if e != nil {
						return e
					}
					var plan domain.InstallmentPlan
					// 解析已保存的计划，供后续校验与处理。
					if e = json.Unmarshal(encoded, &plan); e != nil {
						return e
					}
					transactions[i].InstallmentName = plan.Name
					transactions[i].InstallmentPeriods = plan.Periods
				}
			}
		}
		// 读取账户关联的分期计划。
		installments, e := listInstallments(tx, owner, 0)
		if e != nil {
			return e
		}
		result["plans"] = plans
		result["installments"] = installments
		result["schemaVersion"] = 1
		return nil
	})
	return result, err
}
