// 文件职责：迁移分类名称唯一约束，保留旧墓碑与历史引用并允许同名重建。
package repository

import (
	"fmt"

	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// MigrateCategoryNameVersions 回填墓碑版本并移除旧名称索引；参数：db 为已绑定上下文且已完成 Category AutoMigrate 的数据库，启动期间应停止业务写入；返回值：索引创建、回填或旧索引删除错误，成功为 nil。可重复执行，只更新墓碑内部版本，不修改活动分类、展示资料或历史引用；失败必须阻止应用启动。
func MigrateCategoryNameVersions(db *gorm.DB) error {
	migrator := db.Migrator()
	// 始终先确认新约束存在；DDL 在部分数据库隐式提交，不依赖事务保证顺序。
	if !migrator.HasIndex(&domain.Category{}, "finance_category_name_version") {
		if err := migrator.CreateIndex(&domain.Category{}, "finance_category_name_version"); err != nil {
			return fmt.Errorf("创建分类名称版本唯一索引失败: %w", err)
		}
	}
	// 使用全局唯一主键区分每一代墓碑；重跑可修复旧版本，且不触碰名称、图标及流水。
	if err := db.Model(&domain.Category{}).Where("deleted = ? AND name_version <> id", true).
		Updates(map[string]any{"name_version": gorm.Expr("id")}).Error; err != nil {
		return fmt.Errorf("回填分类墓碑名称版本失败: %w", err)
	}
	// 只有新约束和回填均成功后才释放旧约束，失败时保留旧索引并交由启动流程报错。
	if migrator.HasIndex(&domain.Category{}, "finance_category_name") {
		if err := migrator.DropIndex(&domain.Category{}, "finance_category_name"); err != nil {
			return fmt.Errorf("删除分类旧名称唯一索引失败: %w", err)
		}
	}
	return nil
}
