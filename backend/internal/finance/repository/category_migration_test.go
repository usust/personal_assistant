// 文件职责：验证分类名称版本迁移保留历史资料、支持同名多代重建并在失败时返回错误。
package repository

import (
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	domain "personal_assistant_server/internal/finance/model"
)

// TestMigrateCategoryNameVersions 验证旧表迁移、同名重建、活动查询和重复迁移；参数：t 为测试上下文；返回值：无，断言失败终止测试。
func TestMigrateCategoryNameVersions(t *testing.T) {
	legacy := []domain.Category{
		{ID: 11, OwnerID: 7, Name: "餐饮", Type: "expense", Icon: "fork.knife", GroupKey: "food", Color: "#112233", IsDefault: true, Deleted: true},
		{ID: 12, OwnerID: 7, Name: "工资", Type: "income", Icon: "banknote", GroupKey: "income", Color: "#223344", Deleted: true},
		{ID: 13, OwnerID: 7, Name: "通勤", Type: "expense", Icon: "bus", GroupKey: "travel", Color: "#334455", IsDefault: true},
		{ID: 14, OwnerID: 8, Name: "餐饮", Type: "expense", Icon: "cup.and.saucer", Color: "#445566", Deleted: true},
		{ID: 15, OwnerID: 9, Name: "餐饮", Type: "expense", Icon: "takeoutbag.and.cup.and.straw", Color: "#556677"},
		{ID: 16, OwnerID: 7, Name: "餐饮", Type: "income", Icon: "gift", Color: "#667788"},
	}
	db := newLegacyCategoryMigrationDB(t, legacy)
	if err := db.AutoMigrate(&domain.Transaction{}); err != nil {
		t.Fatalf("创建真实流水表失败：%v", err)
	}
	// 为旧墓碑和活动分类都保留真实流水引用；从数据库读取快照，避免时间字段的持久化转换干扰比较。
	for _, category := range legacy {
		categoryID := category.ID
		transaction := domain.Transaction{
			OwnerID: category.OwnerID, RequestID: fmt.Sprintf("legacy-category-%d", category.ID),
			AccountID: 1, Type: category.Type, Amount: 12345, Discount: 100, Fee: 25,
			CategoryID: &categoryID, Counterparty: "历史交易对象", Description: "迁移前已保存的流水",
			TransactionDate: "2025-01-02", TransactionTime: "12:34", Status: "posted", Source: "manual",
		}
		if err := db.Create(&transaction).Error; err != nil {
			t.Fatalf("保存分类 %d 的历史流水失败：%v", category.ID, err)
		}
	}
	history := categoryMigrationTransactions(t, db)
	if len(history) != len(legacy) {
		t.Fatalf("历史流水数量 = %d，期望 %d", len(history), len(legacy))
	}

	if err := db.AutoMigrate(&domain.Category{}); err != nil {
		t.Fatalf("迁移 Category 表结构失败：%v", err)
	}
	assertCategoryMigrationIndexes(t, db, true, true)
	assertCategoryMigrationState(t, db, legacy, history)

	// AutoMigrate 通常已创建新索引；主动移除一次，覆盖迁移自行补建约束的成功路径。
	if err := db.Migrator().DropIndex(&domain.Category{}, "finance_category_name_version"); err != nil {
		t.Fatalf("移除新索引以验证补建失败：%v", err)
	}
	assertCategoryMigrationIndexes(t, db, true, false)
	if err := MigrateCategoryNameVersions(db); err != nil {
		t.Fatalf("迁移分类名称版本失败：%v", err)
	}
	assertCategoryMigrationIndexes(t, db, false, true)
	want := append([]domain.Category(nil), legacy...)
	for i := range want {
		if want[i].Deleted {
			want[i].NameVersion = want[i].ID
		}
	}
	// 完整结构比较同时保护名称、图标、主键、默认标记等资料，流水比较保护所有历史引用及内容。
	assertCategoryMigrationState(t, db, want, history)
	assertCategoryMigrationLookup(t, db, 7, "餐饮", "expense", 0)
	assertCategoryMigrationLookup(t, db, 7, "工资", "income", 0)
	assertCategoryMigrationLookup(t, db, 7, "通勤", "expense", 13)

	var indexColumns []string
	if err := db.Raw("SELECT name FROM pragma_index_info('finance_category_name_version') ORDER BY seqno").Scan(&indexColumns).Error; err != nil {
		t.Fatalf("读取新索引列失败：%v", err)
	}
	if !reflect.DeepEqual(indexColumns, []string{"owner_id", "name", "type", "name_version"}) {
		t.Fatalf("新索引列及顺序不符：%v", indexColumns)
	}
	var unique int
	if err := db.Raw(`SELECT "unique" FROM pragma_index_list('finance_categories_v2') WHERE name = ?`, "finance_category_name_version").Scan(&unique).Error; err != nil {
		t.Fatalf("读取新索引唯一性失败：%v", err)
	}
	if unique != 1 {
		t.Fatal("新名称版本索引不是唯一索引")
	}

	second := domain.Category{OwnerID: 7, Name: "餐饮", Type: "expense", Icon: "carrot", Color: "#778899"}
	if err := db.Create(&second).Error; err != nil {
		t.Fatalf("创建同名第二代活动分类失败：%v", err)
	}
	if second.NameVersion != 0 || second.Deleted {
		t.Fatalf("第二代应为 version 0 的活动分类：%+v", second)
	}
	want = append(want, second)
	assertCategoryMigrationLookup(t, db, 7, "餐饮", "expense", second.ID)
	assertCategoryMigrationState(t, db, want, history)

	// 绕过服务直接写库，确保拒绝第二个同名活动分类的是数据库唯一约束。
	duplicate := domain.Category{OwnerID: 7, Name: "餐饮", Type: "expense", Icon: "leaf"}
	if err := db.Create(&duplicate).Error; !errors.Is(err, gorm.ErrDuplicatedKey) {
		t.Fatalf("重复活动分类应触发唯一约束，实际错误：%v", err)
	}
	assertCategoryMigrationState(t, db, want, history)

	// 删除标记和墓碑版本必须在同一条 UPDATE 中修改，避免已删除行继续占用活动版本。
	// 事务回调原子删除第二代；参数：tx 为当前事务；返回值：更新错误或行数异常，nil 时提交。
	if err := db.Transaction(func(tx *gorm.DB) error {
		result := tx.Model(&domain.Category{}).
			Where("owner_id = ? AND id = ? AND deleted = ?", second.OwnerID, second.ID, false).
			Updates(map[string]any{"deleted": true, "name_version": gorm.Expr("id")})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return fmt.Errorf("原子删除影响 %d 行，期望 1 行", result.RowsAffected)
		}
		return nil
	}); err != nil {
		t.Fatalf("原子删除第二代分类失败：%v", err)
	}
	second.Deleted = true
	second.NameVersion = second.ID
	want[len(want)-1] = second
	assertCategoryMigrationLookup(t, db, 7, "餐饮", "expense", 0)
	assertCategoryMigrationState(t, db, want, history)

	third := domain.Category{OwnerID: 7, Name: "餐饮", Type: "expense", Icon: "birthday.cake", Color: "#8899AA"}
	if err := db.Create(&third).Error; err != nil {
		t.Fatalf("存在多个同名墓碑时创建第三代失败：%v", err)
	}
	if third.NameVersion != 0 || third.Deleted || third.ID == second.ID || third.ID == legacy[0].ID {
		t.Fatalf("第三代应使用新主键且为 version 0 的活动分类：%+v", third)
	}
	want = append(want, third)
	assertCategoryMigrationLookup(t, db, 7, "餐饮", "expense", third.ID)
	assertCategoryMigrationState(t, db, want, history)

	// 重复完整启动迁移，验证多代墓碑、当前活动分类及历史流水均保持不变。
	for pass := 1; pass <= 2; pass++ {
		if err := db.AutoMigrate(&domain.Category{}); err != nil {
			t.Fatalf("第 %d 次重复 AutoMigrate 失败：%v", pass, err)
		}
		if err := MigrateCategoryNameVersions(db); err != nil {
			t.Fatalf("第 %d 次重复名称版本迁移失败：%v", pass, err)
		}
		assertCategoryMigrationIndexes(t, db, false, true)
		assertCategoryMigrationState(t, db, want, history)
		assertCategoryMigrationLookup(t, db, 7, "餐饮", "expense", third.ID)
	}
}

// TestMigrateCategoryNameVersionsBackfillFailure 验证回填失败保留旧约束及墓碑；参数：t 为测试上下文；返回值：无，断言失败终止测试。
func TestMigrateCategoryNameVersionsBackfillFailure(t *testing.T) {
	db := newLegacyCategoryMigrationDB(t, []domain.Category{
		{ID: 21, OwnerID: 7, Name: "餐饮", Type: "expense", Icon: "fork.knife", Color: "#112233", Deleted: true},
		{ID: 22, OwnerID: 7, Name: "通勤", Type: "expense", Icon: "bus"},
	})
	if err := db.AutoMigrate(&domain.Category{}); err != nil {
		t.Fatalf("迁移 Category 表结构失败：%v", err)
	}
	before := categoryMigrationCategories(t, db)
	assertCategoryMigrationIndexes(t, db, true, true)
	// 由 SQLite 在真正执行回填时拒绝 UPDATE，验证错误传播发生在移除旧约束之前。
	if err := db.Exec(`CREATE TRIGGER fail_category_name_version_backfill
		BEFORE UPDATE ON finance_categories_v2
		WHEN OLD.deleted = 1
		BEGIN
			SELECT RAISE(ABORT, 'category backfill blocked');
		END`).Error; err != nil {
		t.Fatalf("创建回填失败触发器失败：%v", err)
	}
	if err := MigrateCategoryNameVersions(db); err == nil ||
		!strings.Contains(err.Error(), "回填分类墓碑名称版本失败") ||
		!strings.Contains(err.Error(), "category backfill blocked") {
		t.Fatalf("期望返回包含触发器原因的回填错误，实际：%v", err)
	}
	assertCategoryMigrationIndexes(t, db, true, true)
	if after := categoryMigrationCategories(t, db); !reflect.DeepEqual(after, before) {
		t.Fatalf("回填失败后分类发生改变：\nbefore=%+v\nafter=%+v", before, after)
	}
}

// TestMigrateCategoryNameVersionsCreateIndexFailure 验证新索引建立失败立即返回且不回填；参数：t 为测试上下文；返回值：无，断言失败终止测试。
func TestMigrateCategoryNameVersionsCreateIndexFailure(t *testing.T) {
	db := newLegacyCategoryMigrationDB(t, []domain.Category{
		{ID: 31, OwnerID: 7, Name: "餐饮", Type: "expense", Icon: "fork.knife", Deleted: true},
	})
	if err := db.AutoMigrate(&domain.Category{}); err != nil {
		t.Fatalf("迁移 Category 表结构失败：%v", err)
	}
	for _, index := range []string{"finance_category_name_version", "finance_category_name"} {
		if err := db.Migrator().DropIndex(&domain.Category{}, index); err != nil {
			t.Fatalf("移除索引 %s 失败：%v", index, err)
		}
	}
	// 无约束时直接插入相同四元组；若迁移错误地先回填墓碑，该冲突会消失并导致测试失败。
	if err := db.Exec(`INSERT INTO finance_categories_v2
		(id, owner_id, name, type, icon, deleted, name_version)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, 32, 7, "餐饮", "expense", "carrot", false, 0).Error; err != nil {
		t.Fatalf("构造重复 version 0 数据失败：%v", err)
	}
	before := categoryMigrationCategories(t, db)
	assertCategoryMigrationIndexes(t, db, false, false)
	if err := MigrateCategoryNameVersions(db); err == nil || !strings.Contains(err.Error(), "创建分类名称版本唯一索引失败") {
		t.Fatalf("期望返回新索引创建错误，实际：%v", err)
	}
	assertCategoryMigrationIndexes(t, db, false, false)
	if after := categoryMigrationCategories(t, db); !reflect.DeepEqual(after, before) {
		t.Fatalf("新索引创建失败后不应回填或改动分类：\nbefore=%+v\nafter=%+v", before, after)
	}
}

// newLegacyCategoryMigrationDB 创建独立临时旧版数据库并插入分类；参数：t 为测试上下文，categories 为主键及旧三元组均不重复且 NameVersion 为 0 的旧分类；返回值：尚未 AutoMigrate Category 的数据库，测试清理时关闭连接，任何初始化错误终止测试。
func newLegacyCategoryMigrationDB(t *testing.T, categories []domain.Category) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "category-migration.db")), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent), TranslateError: true,
	})
	if err != nil {
		t.Fatalf("打开临时 SQLite 数据库失败：%v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("获取 SQLite 连接失败：%v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	// 清理数据库连接；参数：无；返回值：无，关闭错误报告为测试失败；先于临时目录清理执行。
	t.Cleanup(func() {
		if err := sqlDB.Close(); err != nil {
			t.Errorf("关闭临时 SQLite 数据库失败：%v", err)
		}
	})

	// 显式还原无 name_version 的旧结构；末列紧接右括号以匹配 GORM 建表格式，避免 SQLite DDL 解析器遗漏后续新增列。
	if err := db.Exec(`CREATE TABLE finance_categories_v2 (
		id integer PRIMARY KEY AUTOINCREMENT,
		owner_id integer NOT NULL,
		name text,
		type text,
		group_key text,
		icon text,
		color text,
		is_default numeric,
		deleted numeric NOT NULL DEFAULT false)`).Error; err != nil {
		t.Fatalf("创建旧版分类表失败：%v", err)
	}
	if err := db.Exec(`CREATE UNIQUE INDEX finance_category_name
		ON finance_categories_v2(owner_id, name, type)`).Error; err != nil {
		t.Fatalf("创建旧版名称唯一索引失败：%v", err)
	}
	for _, category := range categories {
		if err := db.Exec(`INSERT INTO finance_categories_v2
			(id, owner_id, name, type, group_key, icon, color, is_default, deleted)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			category.ID, category.OwnerID, category.Name, category.Type, category.GroupKey,
			category.Icon, category.Color, category.IsDefault, category.Deleted).Error; err != nil {
			t.Fatalf("插入旧分类 %d 失败：%v", category.ID, err)
		}
	}
	assertCategoryMigrationIndexes(t, db, true, false)
	return db
}

// categoryMigrationCategories 读取全部分类供完整比较；参数：t 为测试上下文，db 为已完成 Category AutoMigrate 的数据库；返回值：按主键排序且包含墓碑的分类，查询失败终止测试。
func categoryMigrationCategories(t *testing.T, db *gorm.DB) []domain.Category {
	t.Helper()
	var rows []domain.Category
	if err := db.Order("id").Find(&rows).Error; err != nil {
		t.Fatalf("读取分类快照失败：%v", err)
	}
	return rows
}

// categoryMigrationTransactions 读取历史流水快照；参数：t 为测试上下文，db 为已创建真实 Transaction 表的数据库；返回值：按主键排序的全部流水，查询失败终止测试。
func categoryMigrationTransactions(t *testing.T, db *gorm.DB) []domain.Transaction {
	t.Helper()
	var rows []domain.Transaction
	if err := db.Order("id").Find(&rows).Error; err != nil {
		t.Fatalf("读取历史流水快照失败：%v", err)
	}
	return rows
}

// assertCategoryMigrationState 断言分类及流水全部持久化字段不变；参数：t 为测试上下文，db 为测试数据库，categories 为按主键排序的期望分类，history 为迁移前保存的流水快照；返回值：无，差异使测试失败。
func assertCategoryMigrationState(t *testing.T, db *gorm.DB, categories []domain.Category, history []domain.Transaction) {
	t.Helper()
	if actual := categoryMigrationCategories(t, db); !reflect.DeepEqual(actual, categories) {
		t.Fatalf("分类快照不符：\nwant=%+v\ngot=%+v", categories, actual)
	}
	if actual := categoryMigrationTransactions(t, db); !reflect.DeepEqual(actual, history) {
		t.Fatalf("历史流水内容或分类引用改变：\nbefore=%+v\nafter=%+v", history, actual)
	}
}

// assertCategoryMigrationIndexes 断言两代名称索引的存在状态；参数：t 为测试上下文，db 为测试数据库，wantOld 和 wantNew 分别表示旧索引及版本索引是否应存在；返回值：无，差异使测试失败。
func assertCategoryMigrationIndexes(t *testing.T, db *gorm.DB, wantOld, wantNew bool) {
	t.Helper()
	if actual := db.Migrator().HasIndex(&domain.Category{}, "finance_category_name"); actual != wantOld {
		t.Fatalf("旧名称索引存在 = %v，期望 %v", actual, wantOld)
	}
	if actual := db.Migrator().HasIndex(&domain.Category{}, "finance_category_name_version"); actual != wantNew {
		t.Fatalf("新名称版本索引存在 = %v，期望 %v", actual, wantNew)
	}
}

// assertCategoryMigrationLookup 验证名称查找和计数只匹配指定归属及类型的活动分类；参数：t 为测试上下文，db 为测试数据库，owner 为归属，name 为名称，kind 为收支类型，wantID 为期望活动主键且 0 表示不存在；返回值：无，差异使测试失败。
func assertCategoryMigrationLookup(t *testing.T, db *gorm.DB, owner uint64, name, kind string, wantID uint64) {
	t.Helper()
	var row domain.Category
	err := FindCategoryByName(db, owner, name, kind, &row)
	wantCount := int64(0)
	if wantID == 0 {
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			t.Fatalf("仅有墓碑时应返回 ErrRecordNotFound（%d/%s/%s），实际：%v，记录：%+v", owner, name, kind, err, row)
		}
	} else {
		wantCount = 1
		if err != nil {
			t.Fatalf("读取活动分类 %d 失败：%v", wantID, err)
		}
		if row.ID != wantID || row.OwnerID != owner || row.Name != name || row.Type != kind || row.Deleted || row.NameVersion != 0 {
			t.Fatalf("期望活动分类 %d，实际返回：%+v", wantID, row)
		}
	}
	count := int64(-1)
	if err := CountCategoryByName(db, owner, name, kind, &count); err != nil {
		t.Fatalf("统计活动分类失败：%v", err)
	}
	if count != wantCount {
		t.Fatalf("活动分类数量（%d/%s/%s）= %d，期望 %d", owner, name, kind, count, wantCount)
	}
}
