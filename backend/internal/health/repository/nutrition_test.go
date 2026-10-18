// 文件职责：验证数据库唯一幂等键、并发重试以及健康清空事务的回滚边界。
package repository

import (
	"path/filepath"
	"sync"
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	domain "personal_assistant_server/internal/health/model"
)

// mealRepositoryFixture 创建独立数据库；参数：t 为测试上下文；返回值：迁移后的数据库；启用忙等待以验证并发唯一键，测试结束关闭连接。
func mealRepositoryFixture(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "nutrition.db")+"?_busy_timeout=5000&_journal_mode=WAL"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&domain.Day{}, &domain.Report{}, &domain.Meal{}, &domain.NutritionGoal{}); err != nil {
		t.Fatal(err)
	}
	// 清理回调无参数和返回值；关闭测试连接，失败报告到测试上下文。
	t.Cleanup(func() {
		conn, err := db.DB()
		if err != nil {
			t.Error(err)
			return
		}
		if err = conn.Close(); err != nil {
			t.Error(err)
		}
	})
	return db
}

// TestMealConcurrentIdempotency 验证数据库唯一键原子去重；参数：t 为测试上下文；返回值：无；并发重试均返回同一结构化记录。
func TestMealConcurrentIdempotency(t *testing.T) {
	db := mealRepositoryFixture(t)
	meal := domain.Meal{UserID: 1, ID: "11111111-2222-4333-8444-555555555555", Date: "2026-10-17", MealType: "lunch", Items: []domain.MealItem{{Name: "米饭", Grams: 150, Calories: 174}}}
	var wg sync.WaitGroup
	errors := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		// 并发回调无参数和返回值；提交同一幂等键并将结果错误传到缓冲通道，不共享可变餐食字段。
		go func() { defer wg.Done(); _, err := CreateMeal(db, meal); errors <- err }()
	}
	wg.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	var count int64
	if err := db.Model(&domain.Meal{}).Where("user_id = ?", 1).Count(&count).Error; err != nil || count != 1 {
		t.Fatalf("count %d %v", count, err)
	}
}

// TestClearNutritionRollback 验证清空四类数据共用事务；参数：t 为测试上下文；返回值：无；人为阻止最后一步删除，餐食、目标与报告必须回滚，解除后仅删除本人数据。
func TestClearNutritionRollback(t *testing.T) {
	db := mealRepositoryFixture(t)
	for _, uid := range []uint64{1, 2} {
		if err := db.Create(&domain.Day{UserID: uid, Date: "2026-10-17", Timezone: "UTC"}).Error; err != nil {
			t.Fatal(err)
		}
		if err := db.Create(&domain.Report{UserID: uid, Content: "report"}).Error; err != nil {
			t.Fatal(err)
		}
		if err := PutNutritionGoal(db, uid, 2200); err != nil {
			t.Fatal(err)
		}
		if _, err := CreateMeal(db, domain.Meal{UserID: uid, ID: "11111111-2222-4333-8444-555555555555", Date: "2026-10-17", MealType: "lunch", Items: []domain.MealItem{{Name: "米饭", Grams: 150, Calories: 174}}}); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Exec(`CREATE TRIGGER block_health_clear BEFORE DELETE ON health_days BEGIN SELECT RAISE(ABORT, 'test rollback'); END;`).Error; err != nil {
		t.Fatal(err)
	}
	if err := Clear(db, 1); err == nil {
		t.Fatal("expected failed transaction")
	}
	for _, row := range []any{&domain.Day{}, &domain.Report{}, &domain.Meal{}, &domain.NutritionGoal{}} {
		var count int64
		if err := db.Model(row).Where("user_id = ?", 1).Count(&count).Error; err != nil || count != 1 {
			t.Fatalf("rollback %T count %d %v", row, count, err)
		}
	}
	if err := db.Exec("DROP TRIGGER block_health_clear").Error; err != nil {
		t.Fatal(err)
	}
	if err := Clear(db, 1); err != nil {
		t.Fatal(err)
	}
	for _, row := range []any{&domain.Day{}, &domain.Report{}, &domain.Meal{}, &domain.NutritionGoal{}} {
		var count int64
		if err := db.Model(row).Where("user_id = ?", 1).Count(&count).Error; err != nil || count != 0 {
			t.Fatalf("clear %T count %d %v", row, count, err)
		}
		if err := db.Model(row).Where("user_id = ?", 2).Count(&count).Error; err != nil || count != 1 {
			t.Fatalf("foreign %T count %d %v", row, count, err)
		}
	}
}
