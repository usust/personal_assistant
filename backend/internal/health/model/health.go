// 文件职责：定义健康日汇总和报告持久化结构。
package model

import (
	"time"
)

// Day 是 HealthKit 按设备当地自然日汇总的数据；nil 表示不可用，不能当作零。
type Day struct {
	ID               uint      `json:"id" gorm:"primaryKey"`
	UserID           uint64    `json:"-" gorm:"uniqueIndex:health_day"`
	Date             string    `json:"date" gorm:"size:10;uniqueIndex:health_day"`
	Steps            *float64  `json:"steps"`
	ActiveEnergy     *float64  `json:"active_energy"`
	Distance         *float64  `json:"distance"`
	RestingHeartRate *float64  `json:"resting_heart_rate"`
	Weight           *float64  `json:"weight"`
	Timezone         string    `json:"timezone" gorm:"size:80"`
	UpdatedAt        time.Time `json:"updated_at"`
}

// TableName 指定业务表；参数：无；返回值：表名，无副作用。
func (Day) TableName() string { return "health_days" }

type Report struct {
	ID        uint      `json:"id" gorm:"primaryKey"`
	UserID    uint64    `json:"-" gorm:"index"`
	Content   string    `json:"content" gorm:"type:text"`
	Snapshot  string    `json:"snapshot" gorm:"type:text"`
	ConfigID  uint      `json:"config_id"`
	CreatedAt time.Time `json:"created_at"`
}

// TableName 指定报告表；参数：无；返回值：表名，无副作用。
func (Report) TableName() string { return "health_reports" }
