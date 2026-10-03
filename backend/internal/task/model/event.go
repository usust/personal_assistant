// 文件职责：定义任务模块的变更事件模型，保持数据库表和 JSON 字段契约。
package model

import (
	"time"
)

// Event 在业务事务内记录变更来源，不保存描述或其他敏感正文。
type Event struct {
	ID        uint64    `json:"id" gorm:"primaryKey"`
	OwnerID   uint64    `json:"-" gorm:"index"`
	Operation string    `json:"operation" gorm:"size:64"`
	EntityID  uint64    `json:"entityId"`
	Source    string    `json:"source" gorm:"size:16"`
	CreatedAt time.Time `json:"createdAt"`
}
