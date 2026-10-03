// 文件职责：定义记账模块的事件与余额快照模型，保持数据库表和 JSON 字段契约。
package model

import (
	"time"
)

// Event 与写入操作在同一事务内保存，不保存商户、备注等正文。
type Event struct {
	ID        uint64    `json:"id" gorm:"primaryKey"`
	OwnerID   uint64    `json:"-" gorm:"index"`
	EntityID  uint64    `json:"entityId"`
	Operation string    `json:"operation" gorm:"size:64"`
	Source    string    `json:"source" gorm:"size:16"`
	CreatedAt time.Time `json:"createdAt"`
}

// Snapshot 记录账户余额变更后的状态，便于审计；不将历史点伪装为历史净资产。
type Snapshot struct {
	ID        uint64    `json:"id" gorm:"primaryKey"`
	OwnerID   uint64    `json:"-" gorm:"index"`
	AccountID uint64    `json:"accountId" gorm:"index"`
	Balance   Money     `json:"balance" gorm:"type:bigint"`
	CreatedAt time.Time `json:"createdAt"`
}

// TableName 隔离财务审计记录，避免与任务模块默认 events 表混用；参数：无；返回值：财务审计表名。
func (Event) TableName() string { return "finance_events_v2" }

// TableName 隔离账户快照；参数：无；返回值：财务快照表名。
func (Snapshot) TableName() string { return "finance_account_snapshots_v2" }
