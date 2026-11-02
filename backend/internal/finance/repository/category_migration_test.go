package repository

import (
	"errors"
	"path/filepath"
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	domain "personal_assistant_server/internal/finance/model"
)

// TestCategoryCurrentSchema 验证当前分类结构的唯一约束与同名重建；参数：t 为测试上下文；返回值：无，仅写临时数据库，失败终止测试。
func TestCategoryCurrentSchema(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "categories.db")), &gorm.Config{TranslateError: true})
	if err != nil {
		t.Fatal(err)
	}
	connection, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	// 释放测试连接；参数：无；返回值：无，关闭失败记录测试错误。
	t.Cleanup(func() {
		if err := connection.Close(); err != nil {
			t.Error(err)
		}
	})
	if err := db.AutoMigrate(&domain.Category{}); err != nil {
		t.Fatal(err)
	}
	if !db.Migrator().HasIndex(&domain.Category{}, "finance_category_name_version") {
		t.Fatal("缺少当前名称唯一索引")
	}
	if db.Migrator().HasIndex(&domain.Category{}, "finance_category_name") {
		t.Fatal("不应创建旧名称索引")
	}
	for generation := 0; generation < 3; generation++ {
		row := domain.Category{OwnerID: 1, Name: "餐饮", Type: "expense"}
		if err := db.Create(&row).Error; err != nil {
			t.Fatal(err)
		}
		duplicate := domain.Category{OwnerID: 1, Name: "餐饮", Type: "expense"}
		if err := db.Create(&duplicate).Error; !errors.Is(err, gorm.ErrDuplicatedKey) {
			t.Fatalf("重复活动分类未被拒绝：%v", err)
		}
		// 删除和版本写入保持原子性，使下一代同名分类可直接创建，无需启动回填。
		if err := db.Model(&row).Updates(map[string]any{"deleted": true, "name_version": row.ID}).Error; err != nil {
			t.Fatal(err)
		}
	}
	var count int64
	if err := db.Model(&domain.Category{}).Where("deleted = ? AND name_version = id", true).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("墓碑数量错误：%d", count)
	}
}
