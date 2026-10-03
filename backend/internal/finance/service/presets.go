// 文件职责：执行记账业务规则与事务编排。

package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/repository"
)

// presets 管理用户模板及周期计划；参数：db 为持有用户锁的事务，owner 为用户，op 为操作，in 为输入；返回值：记录或错误；删除不影响已生成流水。
func (s *Service) presets(db *gorm.DB, owner uint64, op string, in Input) (any, error) {
	if op == "finance.preset.list" {
		rows := []domain.Preset{}
		// 读取符合业务条件的记录集合。
		err := repository.ReadPresets(db, owner, &rows)
		return rows, err
	}
	if op == "finance.preset.create" {
		var body struct {
			Key         string                  `json:"key"`
			Name        string                  `json:"name"`
			Transaction domain.TransactionInput `json:"transaction"`
			Frequency   string                  `json:"frequency"`
			StartDate   string                  `json:"startDate"`
			EndDate     string                  `json:"endDate"`
		}
		// 严格解析业务输入，避免无效字段进入操作流程。
		if err := Decode(in.Changes, &body); err != nil {
			return nil, err
		}
		body.Transaction.RequestID = body.Key
		if body.Transaction.TransactionDate == "" {
			body.Transaction.TransactionDate = "2000-01-01"
		}
		// 确认输入满足当前业务约束。
		if err := validateTransactionInput(body.Transaction); err != nil {
			return nil, err
		}
		// 检查文本长度与必填约束。
		if !validText(body.Name, 128, true) {
			// 拒绝本次操作：模板名称必填且不超过 128 字节。
			return nil, Invalid("模板名称必填且不超过 128 字节")
		}
		switch body.Frequency {
		case "", "daily", "weekly", "monthly", "yearly":
		default:
			// 拒绝本次操作：周期无效。
			return nil, Invalid("周期无效")
		}
		// 检查日期是否满足业务格式。
		if body.Frequency != "" && (!validDate(body.StartDate) || (body.EndDate != "" && (!validDate(body.EndDate) || body.EndDate < body.StartDate))) {
			// 拒绝本次操作：开始或截止日期无效。
			return nil, Invalid("开始或截止日期无效")
		}
		row := domain.Preset{OwnerID: owner, Key: body.Key, Name: body.Name, Transaction: body.Transaction, Frequency: body.Frequency, StartDate: body.StartDate, EndDate: body.EndDate, NextDate: body.StartDate, Enabled: true}
		var old domain.Preset
		// 读取满足条件的目标记录。
		if err := repository.FindPresetByKey(db, owner, body.Key, &old); err == nil {
			// 序列化业务数据，供存储或响应使用。
			a, _ := json.Marshal(old.Transaction)
			// 序列化业务数据，供存储或响应使用。
			b, _ := json.Marshal(row.Transaction)
			if string(a) != string(b) || old.Name != row.Name || old.Frequency != row.Frequency || old.StartDate != row.StartDate || old.EndDate != row.EndDate {
				return nil, ErrConflict
			}
			return old, nil
		} else if err != gorm.ErrRecordNotFound {
			return nil, err
		}
		// 确认交易引用的账户与分类属于当前用户。
		if err := validateReferences(db, owner, body.Transaction); err != nil {
			return nil, err
		}
		// 保存新建的业务记录。
		err := repository.CreatePreset(db, &row)
		return row, err
	}
	var row domain.Preset
	// 读取满足条件的目标记录。
	var err error
	row, err = repository.ReadPreset(db, owner, in.ID)
	if err != nil {
		// 将数据库查询失败转换为业务错误。
		return nil, missing(err)
	}
	if op == "finance.preset.delete" {
		// 删除满足业务范围约束的记录。
		return row, repository.DeletePreset(db, owner, row.ID)
	}
	var body struct {
		Name        *string                  `json:"name"`
		Enabled     *bool                    `json:"enabled"`
		Transaction *domain.TransactionInput `json:"transaction"`
	}
	// 严格解析业务输入，避免无效字段进入操作流程。
	if err := Decode(in.Changes, &body); err != nil {
		return nil, err
	}
	fields := map[string]any{}
	if body.Name != nil {
		// 检查文本长度与必填约束。
		if !validText(*body.Name, 128, true) {
			// 拒绝本次操作：名称无效。
			return nil, Invalid("名称无效")
		}
		fields["name"] = *body.Name
	}
	if body.Enabled != nil {
		fields["enabled"] = *body.Enabled
	}
	// 交易配置作为显式提交的字段更新；复用创建校验和归属校验，不触碰历史流水或周期调度字段。
	if body.Transaction != nil {
		body.Transaction.RequestID = row.Key
		if body.Transaction.TransactionDate == "" {
			body.Transaction.TransactionDate = "2000-01-01"
		}
		// 确认输入满足当前业务约束。
		if err := validateTransactionInput(*body.Transaction); err != nil {
			return nil, err
		}
		// 确认交易引用的账户与分类属于当前用户。
		if err := validateReferences(db, owner, *body.Transaction); err != nil {
			return nil, err
		}
		// map 更新不经过结构体的 JSON 序列化器，显式编码后写入已知数据库字段。
		encoded, err := json.Marshal(body.Transaction)
		if err != nil {
			return nil, err
		}
		fields["transaction"] = string(encoded)
	}
	if len(fields) == 0 {
		// 拒绝本次操作：至少提交一个字段。
		return nil, Invalid("至少提交一个字段")
	}
	// 仅写入本次经过校验的变更字段。
	if err := repository.UpdatePreset(db, owner, row.ID, fields); err != nil {
		return nil, err
	}
	// 读取满足条件的目标记录。
	err = repository.FindPreset(db, owner, row.ID, &row)
	return row, err
}

// nextOccurrence 推算下一期并保留原始月日锚点；参数：date 为本期日期，start 为开始日期，frequency 为有效周期；返回值：下一期日期，月底不足日取当月末日，闰年后恢复原日。
func nextOccurrence(date, start, frequency string) string {
	// 按业务格式解析日期或时间。
	d, _ := time.Parse("2006-01-02", date)
	// 按业务格式解析日期或时间。
	anchor, _ := time.Parse("2006-01-02", start)
	if frequency == "daily" {
		// 将业务时间转换为约定的存储或展示格式。
		return d.AddDate(0, 0, 1).Format("2006-01-02")
	}
	if frequency == "weekly" {
		// 将业务时间转换为约定的存储或展示格式。
		return d.AddDate(0, 0, 7).Format("2006-01-02")
	}
	// 取得日期中的年份，供周期计算。
	year, month := d.Year(), d.Month()+1
	if frequency == "yearly" {
		year++
		// 取得日期中的月份，供周期计算。
		month = anchor.Month()
	}
	// 按业务周期边界构造日期。
	first := time.Date(year, month, 1, 0, 0, 0, 0, time.UTC)
	// 取得日期中的日，供周期边界计算。
	day := anchor.Day()
	// 取得日期中的日，供周期边界计算。
	last := first.AddDate(0, 1, -1).Day()
	if day > last {
		day = last
	}
	// 将业务时间转换为约定的存储或展示格式。
	return first.AddDate(0, 0, day-1).Format("2006-01-02")
}

// materialize 补齐到期草稿；参数：db 为持用户锁事务，owner 为用户，now 为当前时间；返回值：数据库错误；每计划每批最多 120 期，确定性幂等键防重，停用账户阻止生成并显示错误。
func (s *Service) materialize(db *gorm.DB, owner uint64, now time.Time) error {
	// 将业务时间转换为约定的存储或展示格式。
	today := now.In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02")
	var rows []domain.Preset
	// 读取符合业务条件的记录集合。
	if err := repository.ReadDuePresets(db, owner, today, &rows); err != nil {
		return err
	}
	for _, row := range rows {
		// 确认交易引用的账户与分类属于当前用户。
		if err := validateReferences(db, owner, row.Transaction); err != nil {
			// 区分预期错误与需要继续上报的异常。
			if !errors.Is(err, ErrNotFound) && !errors.Is(err, ErrInvalid) {
				return err
			}
			// 仅写入本次经过校验的变更字段。
			if err := repository.UpdatePreset(db, owner, row.ID, map[string]any{"last_error": "账户或分类不可用，请删除计划后重新设置"}); err != nil {
				return err
			}
			continue
		}
		for count := 0; count < 120 && row.NextDate <= today && (row.EndDate == "" || row.NextDate <= row.EndDate); count++ {
			in := row.Transaction
			in.TransactionDate = row.NextDate
			// 生成当前操作需要的展示或协议文本。
			in.RequestID = fmt.Sprintf("recurring_%d_%s", row.ID, row.NextDate)
			// 序列化业务数据，供存储或响应使用。
			raw, _ := json.Marshal(in)
			// 创建流水并协调关联记账影响。
			transaction, err := s.createTransaction(db, owner, raw, "recurring")
			if err != nil {
				return err
			}
			// 保存新建的业务记录。
			if err := repository.CreateEvent(db, &domain.Event{OwnerID: owner, EntityID: transaction.ID, Operation: "finance.recurring.generate", Source: "recurring"}); err != nil {
				return err
			}
			// 计算下一次周期记账日期。
			row.NextDate = nextOccurrence(row.NextDate, row.StartDate, row.Frequency)
		}
		fields := map[string]any{"next_date": row.NextDate, "last_error": ""}
		if row.EndDate != "" && row.NextDate > row.EndDate {
			fields["enabled"] = false
		}
		// 仅写入本次经过校验的变更字段。
		if err := repository.UpdatePreset(db, owner, row.ID, fields); err != nil {
			return err
		}
	}
	return nil
}

// RunRecurring 周期生成草稿并自动入账到期分期；参数：ctx 控制生命周期，report 接收错误且不得阻塞；返回值：无；启动立即补齐，此后每分钟执行，停机取消，多个进程由用户锁及唯一键保护。
func (s *Service) RunRecurring(ctx context.Context, report func(error)) {
	// 建立后台任务的周期触发器。
	ticker := time.NewTicker(time.Minute)
	// 退出时释放周期计时器。
	defer ticker.Stop()
	for {
		var owners []uint64
		// 读取后续处理需要的单列数据。
		err := repository.ReadRecurringOwners(s.db.WithContext(ctx), &owners)
		if err != nil {
			// 将后台任务失败交给错误回调。
			report(err)
		} else {
			for _, owner := range owners {
				// 将业务操作交给共享服务执行。
				if _, err := s.Execute(ctx, capability.Actor{UserID: owner}, "finance.recurring.materialize", Input{}, "http"); err != nil {
					// 将后台任务失败交给错误回调。
					report(err)
				}
			}
		}
		// 分期独立查询，未配置周期模板的用户也会入账；与草稿生成隔离错误和事务。
		owners = nil
		// 将业务时间转换为约定的存储或展示格式。
		today := s.now().In(time.FixedZone("UTC+8", 28800)).Format("2006-01-02")
		// 读取后续处理需要的单列数据。
		err = repository.ReadDueInstallmentOwners(s.db.WithContext(ctx), today, &owners)
		if err != nil {
			// 将后台任务失败交给错误回调。
			report(err)
		} else {
			for _, owner := range owners {
				// 将业务操作交给共享服务执行。
				if _, err := s.Execute(ctx, capability.Actor{UserID: owner}, "finance.installment.post-due", Input{}, "http"); err != nil {
					// 将后台任务失败交给错误回调。
					report(err)
				}
			}
		}
		select {
		// 等待应用取消通知。
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
