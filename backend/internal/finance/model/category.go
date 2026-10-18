// 文件职责：定义记账模块的分类模型，保持数据库表和 JSON 字段契约。
package model

type Category struct {
	GroupKey    string `json:"groupKey" gorm:"size:24"`
	Icon        string `json:"icon" gorm:"size:64"`
	ID          uint64 `json:"id" gorm:"primaryKey"`
	OwnerID     uint64 `json:"-" gorm:"uniqueIndex:finance_category_name_version,priority:1;not null"`
	Name        string `json:"name" gorm:"size:64;uniqueIndex:finance_category_name_version,priority:2"`
	Type        string `json:"type" gorm:"size:16;uniqueIndex:finance_category_name_version,priority:3"`
	// 活动分类使用 0，墓碑使用自身 ID，释放名称且保留历史分类资料。
	NameVersion uint64 `json:"-" gorm:"not null;default:0;uniqueIndex:finance_category_name_version,priority:4"`
	Color       string `json:"color" gorm:"size:7"`
	IsDefault   bool   `json:"isDefault"`
	Deleted     bool   `json:"deleted" gorm:"not null;default:false"`
}

// TableName 返回独立分类表；参数：无；返回值：表名。
func (Category) TableName() string { return "finance_categories_v2" }
