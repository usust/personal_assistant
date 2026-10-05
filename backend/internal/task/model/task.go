// 文件职责：定义任务模块的任务模型，保持数据库表和 JSON 字段契约。
package model

import (
	"time"
)

// Task 保留前端字段；进度使用数据库定点小数，输入精确到百分之一。
type Task struct {
	ID                uint64    `json:"id" gorm:"primaryKey"`
	OwnerID           uint64    `json:"-" gorm:"index;not null"`
	Icon              string    `json:"icon" gorm:"size:64;not null;default:Folder"`
	Title             string    `json:"title" gorm:"size:256"`
	Remark            string    `json:"remark" gorm:"type:text"`
	ListID            uint64    `json:"listId" gorm:"index;not null"`
	ParentID          *uint64   `json:"parentId" gorm:"index"`
	TaskType          string    `json:"taskType" gorm:"size:16"`
	Priority          string    `json:"priority" gorm:"size:16"`
	StartDate         string    `json:"startDate" gorm:"size:10"`
	StartTime         string    `json:"startTime" gorm:"size:5"`
	EndDate           string    `json:"endDate" gorm:"size:10"`
	EndTime           string    `json:"endTime" gorm:"size:5"`
	Archived          bool      `json:"archived"`
	SortOrder         int       `json:"sortOrder"`
	ProgressTotal     float64   `json:"progressTotal" gorm:"type:decimal(14,2)"`
	ProgressCompleted float64   `json:"progressCompleted" gorm:"type:decimal(14,2)"`
	ProgressStep      float64   `json:"progressStep" gorm:"type:decimal(14,2)"`
	ProgressUnit      string    `json:"progressUnit" gorm:"size:20"`
	CreatedAt         time.Time `json:"createdAt"`
	UpdatedAt         time.Time `json:"updatedAt"`
}

// TableName 指定任务新表；参数：无；返回值：表名。
func (Task) TableName() string { return "tasks_v2" }
