// 文件职责：执行健康汇总同步、授权分析或清理业务。
package service

import (
	"context"
	"errors"
	"math"
	"time"

	domain "personal_assistant_server/internal/health/model"
	"personal_assistant_server/internal/health/repository"
)

// validate 验证日期、时区和固定单位的有限数值；参数：days 为最多 31 天的日汇总；返回值：校验错误或 nil，无副作用。
func validate(days []domain.Day) error {
	if len(days) == 0 || len(days) > 31 {
		// 拒绝本次操作：每次需提交 1–31 天数据。
		return errors.New("每次需提交 1–31 天数据")
	}
	seen := map[string]bool{}
	for _, d := range days {
		// 加载业务所需的时区。
		loc, e := time.LoadLocation(d.Timezone)
		if e != nil || d.Timezone == "" {
			// 拒绝本次操作：时区无效。
			return errors.New("时区无效")
		}
		// 在指定时区中解析业务日期。
		date, e := time.ParseInLocation("2006-01-02", d.Date, loc)
		// 检查日期是否超过业务边界。
		if e != nil || date.After(time.Now().In(loc)) || date.Before(time.Now().AddDate(-2, 0, 0)) || seen[d.Date] {
			// 拒绝本次操作：日期无效、重复或超出两年范围。
			return errors.New("日期无效、重复或超出两年范围")
		}
		seen[d.Date] = true
		for _, v := range []struct {
			p   *float64
			max float64
		}{{d.Steps, 200000}, {d.ActiveEnergy, 20000}, {d.Distance, 300000}, {d.RestingHeartRate, 300}, {d.Weight, 1000}} {
			// 拒绝无法用于业务计算的数值。
			if v.p != nil && (math.IsNaN(*v.p) || math.IsInf(*v.p, 0) || *v.p < 0 || *v.p > v.max) {
				// 拒绝本次操作：健康数值超出允许范围。
				return errors.New("健康数值超出允许范围")
			}
		}
	}
	return nil
}

// SyncInput 接收按日期完整提交的健康快照。
type SyncInput struct {
	Days []domain.Day `json:"days"`
}

// Sync 校验日汇总后原子保存；接收者：s 已初始化；参数：ctx 为上下文，uid 为可信身份，input 为日快照；返回值：成功数量及公开错误。
func (s *Service) Sync(ctx context.Context, uid uint64, input SyncInput) (int, error) {
	// 校验必须先于仓储写入，防止部分无效快照入库。
	if err := validate(input.Days); err != nil {
		return 0, &OperationError{400, err.Error()}
	}
	if err := repository.Sync(s.db.WithContext(ctx), uid, input.Days); err != nil {
		return 0, &OperationError{500, "同步失败，请重试"}
	}
	return len(input.Days), nil
}
