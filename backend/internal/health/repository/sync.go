// 文件职责：按用户隔离读写健康数据。
package repository

import (
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	domain "personal_assistant_server/internal/health/model"
)

// Sync 原子更新提交日期的健康快照，其他日期保持不变。
// 参数：db 为绑定上下文数据库，uid 为可信身份，days 为已校验日汇总；返回值：写入错误，失败整批回滚；零值和 nil 覆盖旧快照。
func Sync(db *gorm.DB, uid uint64, days []domain.Day) error {
	// 以用户和日期唯一键执行白名单 map 更新；零值和缺失值都必须覆盖旧快照。
	// 事务回调参数 tx 为当前事务；返回值为首个写入错误，失败整批回滚。
	return db.Transaction(func(tx *gorm.DB) error {
		for _, d := range days {
			d.ID = 0
			d.UserID = uid
			// 取得当前时间，作为本次操作的时间基准。
			d.UpdatedAt = time.Now()
			fields := map[string]any{"steps": d.Steps, "active_energy": d.ActiveEnergy, "distance": d.Distance, "resting_heart_rate": d.RestingHeartRate, "weight": d.Weight, "timezone": d.Timezone, "updated_at": d.UpdatedAt}
			// 保存新建的业务记录。
			if e := tx.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "user_id"}, {Name: "date"}}, DoUpdates: clause.Assignments(fields)}).Create(&d).Error; e != nil {
				return e
			}
		}
		return nil
	})
}
