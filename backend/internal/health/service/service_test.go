// 文件职责：验证健康同步的归属隔离、完整快照更新和分析同意边界。
package service

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	domain "personal_assistant_server/internal/health/model"
)

// healthFixture 创建隔离健康数据库；参数：t 为测试上下文；返回值：健康服务，测试结束关闭连接，不调用模型服务。
func healthFixture(t *testing.T) *Service {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "health.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&domain.Day{}, &domain.Report{}); err != nil {
		t.Fatal(err)
	}
	// 清理回调关闭独立数据库；参数：无；返回值：无，关闭错误令测试失败。
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
	return NewService(db, nil, nil)
}

// TestSyncSnapshotIsolation 验证快照覆盖与归属隔离；参数：t 为测试上下文；返回值：无；显式零值、nil、其他用户与其他日期都必须正确处理。
func TestSyncSnapshotIsolation(t *testing.T) {
	s := healthFixture(t)
	ctx := context.Background()
	date := time.Now().UTC().AddDate(0, 0, -1).Format("2006-01-02")
	otherDate := time.Now().UTC().AddDate(0, 0, -2).Format("2006-01-02")
	steps, weight := 100.0, 60.0
	input := SyncInput{Days: []domain.Day{{ID: 999, UserID: 99, Date: date, Timezone: "UTC", Steps: &steps, Weight: &weight}, {Date: otherDate, Timezone: "UTC", Steps: &steps}}}
	if n, err := s.Sync(ctx, 1, input); err != nil || n != 2 {
		t.Fatalf("sync %d %v", n, err)
	}
	if _, err := s.Sync(ctx, 2, SyncInput{Days: []domain.Day{{Date: date, Timezone: "UTC", Steps: &steps}}}); err != nil {
		t.Fatal(err)
	}
	zero := 0.0
	if _, err := s.Sync(ctx, 1, SyncInput{Days: []domain.Day{{Date: date, Timezone: "UTC", Steps: &zero}}}); err != nil {
		t.Fatal(err)
	}
	result, err := s.Read(ctx, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Days) != 2 || result.Days[0].ID == 999 || result.Days[0].UserID != 1 || result.Days[0].Steps == nil || *result.Days[0].Steps != 0 || result.Days[0].Weight != nil {
		t.Fatalf("snapshot %#v", result.Days)
	}
	foreign, err := s.Read(ctx, 2)
	if err != nil || len(foreign.Days) != 1 || *foreign.Days[0].Steps != 100 {
		t.Fatalf("foreign %#v %v", foreign, err)
	}
	// 整批校验先于写入，任何无效日期不能覆盖已有有效快照。
	if _, err = s.Sync(ctx, 1, SyncInput{Days: []domain.Day{{Date: date, Timezone: "UTC", Steps: &steps}, {Date: "invalid", Timezone: "UTC"}}}); err == nil {
		t.Fatal("invalid accepted")
	}
	result, err = s.Read(ctx, 1)
	if err != nil || *result.Days[0].Steps != 0 {
		t.Fatal("partial invalid batch changed snapshot")
	}
	if err = s.Clear(ctx, 1); err != nil {
		t.Fatal(err)
	}
	foreign, err = s.Read(ctx, 2)
	if err != nil || len(foreign.Days) != 1 {
		t.Fatal("clear changed foreign rows")
	}
}

// TestAnalyzeRequiresConsent 验证拒绝外发发生在模型依赖调用前；参数：t 为测试上下文；返回值：无；未同意或配置为空必须返回 400。
func TestAnalyzeRequiresConsent(t *testing.T) {
	s := healthFixture(t)
	for _, in := range []AnalyzeInput{{ConfigID: 1, Consent: false}, {ConfigID: 0, Consent: true}} {
		_, err := s.Analyze(context.Background(), 1, in)
		var public *OperationError
		if !errors.As(err, &public) || public.Status != 400 {
			t.Fatalf("consent %v", err)
		}
	}
}
