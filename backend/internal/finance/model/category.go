// 文件职责：定义记账模块的分类模型，保持数据库表和 JSON 字段契约。
package model

type Category struct {
	GroupKey  string `json:"groupKey" gorm:"size:24"`
	Icon      string `json:"icon" gorm:"size:64"`
	ID        uint64 `json:"id" gorm:"primaryKey"`
	OwnerID   uint64 `json:"-" gorm:"uniqueIndex:finance_category_name;not null"`
	Name      string `json:"name" gorm:"size:64;uniqueIndex:finance_category_name"`
	Type      string `json:"type" gorm:"size:16;uniqueIndex:finance_category_name"`
	Color     string `json:"color" gorm:"size:7"`
	IsDefault bool   `json:"isDefault"`
}

// TableName 返回独立分类表；参数：无；返回值：表名。
func (Category) TableName() string { return "finance_categories_v2" }
