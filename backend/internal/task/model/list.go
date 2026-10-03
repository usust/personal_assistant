// 文件职责：定义任务模块的清单模型，保持数据库表和 JSON 字段契约。
package model

import (
	"time"
)

// List 是按用户隔离的任务清单。
type List struct {
	ID        uint64    `json:"id" gorm:"primaryKey"`
	OwnerID   uint64    `json:"-" gorm:"index;not null"`
	Name      string    `json:"name" gorm:"size:128"`
	Remark    string    `json:"remark" gorm:"type:text"`
	Color     string    `json:"color" gorm:"size:32"`
	Icon      string    `json:"icon" gorm:"size:64"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// TableName 指定新表，避免未经归属审核接管历史数据；参数：无；返回值：表名。
func (List) TableName() string { return "task_lists_v2" }
