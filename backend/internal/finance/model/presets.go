// 文件职责：定义记账领域模型与协议契约。

package model

// Preset 保存模板或周期计划；流水字段独立保存，历史流水不随模板变化。
type Preset struct {
	ID          uint64           `json:"id" gorm:"primaryKey"`
	OwnerID     uint64           `json:"-" gorm:"uniqueIndex:finance_preset_key;not null"`
	Key         string           `json:"key" gorm:"size:96;uniqueIndex:finance_preset_key"`
	Name        string           `json:"name" gorm:"size:128"`
	Transaction TransactionInput `json:"transaction" gorm:"serializer:json;type:longtext"`
	Frequency   string           `json:"frequency" gorm:"size:16"`
	StartDate   string           `json:"startDate" gorm:"size:10"`
	EndDate     string           `json:"endDate" gorm:"size:10"`
	NextDate    string           `json:"nextDate" gorm:"size:10"`
	Enabled     bool             `json:"enabled"`
	LastError   string           `json:"lastError" gorm:"size:256"`
}

// TableName 返回独立模板表；参数：无；返回值：表名。
func (Preset) TableName() string { return "finance_presets_v2" }
