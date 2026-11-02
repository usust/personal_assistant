package sync

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// testDB 创建独立 SQLite 逻辑测试库并迁移同步模型；t 为当前测试；返回：测试数据库。
// 无事务前置条件；SQLite 不支持 MySQL FOR UPDATE，本文件不验证生产锁与并发语义。
func testDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	sqlDB.SetMaxOpenConns(1)
	// 清理回调关闭本测试连接；参数：无；返回：无；事务已由各测试结束。
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err = db.AutoMigrate(&AccountWatermark{}, &Entity{}, &Batch{}, &Change{}, &Receipt{}); err != nil {
		t.Fatal(err)
	}
	return db
}

// mutation 生成合法测试投影；id 为正整数并用于 UUID 与服务端 ID，base 为期待版本；返回：待记录变更；无事务前置条件。
func mutation(id int, base uint64) Mutation {
	return Mutation{Module: "task.item", UUID: fmt.Sprintf("00000000-0000-0000-0000-%012d", id), ServerID: fmt.Sprintf("%d", id), BaseRevision: base, Payload: []byte(`{"name":"safe"}`)}
}

// record 在独立调用方事务中记录批；t/db 为测试上下文和库，owner 为账号，op 为操作标识，ms 为完整变更；返回：回执。
// 无事务前置条件；测试辅助函数负责提交，不属于 Repository API。
func record(t *testing.T, db *gorm.DB, owner uint64, op string, ms ...Mutation) Receipt {
	t.Helper()
	var receipt Receipt
	// 事务回调参数 tx 为活动事务；返回错误触发回滚，nil 提交测试数据。
	err := db.Transaction(func(tx *gorm.DB) error {
		var err error
		receipt, _, err = (Repository{}).RecordBatch(tx, owner, op, strings.Repeat("a", 64), ms)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return receipt
}

// TestCompleteBatchesAndIsolation 验证账号隔离、批分页及跨模块完整性；t 为测试上下文；返回：无；事务由测试创建。
func TestCompleteBatchesAndIsolation(t *testing.T) {
	db := testDB(t)
	r := Repository{}
	second := mutation(2, 0)
	second.Module = "finance.account"
	first := record(t, db, 1, "first", mutation(1, 0), second)
	if first.Sequence != 1 {
		t.Fatal(first)
	}
	record(t, db, 1, "second", mutation(1, 1))
	record(t, db, 2, "first", mutation(1, 0))
	tx := db.Begin()
	defer tx.Rollback()
	page, err := r.Pull(tx, 1, 0, 1)
	if err != nil || len(page.Batches) != 1 || len(page.Batches[0].Changes) != 2 || page.Next != 1 || page.Watermark != 2 || !page.HasMore {
		t.Fatalf("page=%+v err=%v", page, err)
	}
	page, err = r.Pull(tx, 1, page.Next, 1)
	if err != nil || page.Next != 2 || page.HasMore || page.Batches[0].Changes[0].Revision != 2 {
		t.Fatalf("page=%+v err=%v", page, err)
	}
	page, err = r.Pull(tx, 2, 0, 10)
	if err != nil || page.Watermark != 1 || len(page.Batches[0].Changes) != 1 {
		t.Fatalf("page=%+v err=%v", page, err)
	}
	entity, err := r.Resolve(tx, 2, "task.item", mutation(1, 0).UUID)
	if err != nil || entity.Revision != 1 {
		t.Fatalf("entity=%+v err=%v", entity, err)
	}
	_, err = r.Resolve(tx, 2, "finance.account", second.UUID)
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		t.Fatal(err)
	}
	page, err = r.Pull(tx, 3, 0, 10)
	if err != nil || page.Next != 0 || len(page.Batches) != 0 {
		t.Fatalf("page=%+v err=%v", page, err)
	}
}

// TestReceipts 验证成功重放不分配新序号、指纹冲突及账号隔离；t 为测试上下文；返回：无；事务由测试创建。
func TestReceipts(t *testing.T) {
	db := testDB(t)
	r := Repository{}
	record(t, db, 1, "op", mutation(1, 0))
	tx := db.Begin()
	defer tx.Rollback()
	receipt, err := r.LookupReceipt(tx, 1, "op", strings.Repeat("a", 64))
	if err != nil || receipt == nil || receipt.Sequence != 1 {
		t.Fatalf("receipt=%+v err=%v", receipt, err)
	}
	replay, replayed, err := r.RecordBatch(tx, 1, "op", strings.Repeat("a", 64), nil)
	if err != nil || !replayed || replay.Sequence != 1 {
		t.Fatalf("%+v %v %v", replay, replayed, err)
	}
	_, err = r.LookupReceipt(tx, 1, "op", strings.Repeat("b", 64))
	var conflict *OperationConflict
	if !errors.As(err, &conflict) {
		t.Fatal(err)
	}
	receipt, err = r.LookupReceipt(tx, 2, "op", strings.Repeat("a", 64))
	if err != nil || receipt != nil {
		t.Fatalf("%+v %v", receipt, err)
	}
	page, err := r.Pull(tx, 1, 0, 10)
	if err != nil || page.Watermark != 1 {
		t.Fatalf("%+v %v", page, err)
	}
}

// TestRevisionAndTombstone 验证类型化版本冲突、删除留档、禁止复活及历史投影；t 为测试上下文；返回：无；事务由测试创建。
func TestRevisionAndTombstone(t *testing.T) {
	db := testDB(t)
	r := Repository{}
	record(t, db, 1, "create", mutation(1, 0))
	tx := db.Begin()
	_, _, err := r.RecordBatch(tx, 1, "conflict", strings.Repeat("a", 64), []Mutation{mutation(2, 0), mutation(1, 0)})
	var conflict *RevisionConflict
	if !errors.As(err, &conflict) || conflict.Actual != 1 || conflict.Expected != 0 {
		t.Fatal(err)
	}
	// 整批预校验失败不能遗留前半批实体。
	_, err = r.Resolve(tx, 1, "task.item", mutation(2, 0).UUID)
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		t.Fatal(err)
	}
	tx.Rollback()
	deleted := mutation(1, 1)
	deleted.Tombstone = true
	deleted.Payload = nil
	record(t, db, 1, "delete", deleted)
	tx = db.Begin()
	defer tx.Rollback()
	entity, err := r.Resolve(tx, 1, "task.item", deleted.UUID)
	if err != nil || !entity.Tombstone || entity.Revision != 2 || entity.ServerID != "1" {
		t.Fatalf("%+v %v", entity, err)
	}
	_, _, err = r.RecordBatch(tx, 1, "revive", strings.Repeat("a", 64), []Mutation{mutation(1, 2)})
	if !errors.Is(err, ErrIdentityConflict) {
		t.Fatal(err)
	}
	page, err := r.Pull(tx, 1, 0, 10)
	if err != nil || string(page.Batches[0].Changes[0].Payload) != `{"name":"safe"}` || string(page.Batches[1].Changes[0].Payload) != "null" {
		t.Fatalf("%+v %v", page, err)
	}
}

// TestCallerRollback 验证业务写入、元数据、水位及回执共用调用方事务；t 为测试上下文；返回：无；无事务前置条件。
func TestCallerRollback(t *testing.T) {
	db := testDB(t)
	r := Repository{}
	if err := db.Exec("CREATE TABLE test_business (id integer primary key, value text)").Error; err != nil {
		t.Fatal(err)
	}
	tx := db.Begin()
	if _, err := r.LookupReceipt(tx, 1, "op", strings.Repeat("a", 64)); err != nil {
		t.Fatal(err)
	}
	if err := tx.Exec("INSERT INTO test_business VALUES (1, 'domain')").Error; err != nil {
		t.Fatal(err)
	}
	if _, _, err := r.RecordBatch(tx, 1, "op", strings.Repeat("a", 64), []Mutation{mutation(1, 0)}); err != nil {
		t.Fatal(err)
	}
	if err := tx.Rollback().Error; err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"test_business", "sync_account_watermarks", "sync_entities", "sync_batches", "sync_changes", "sync_receipts"} {
		var count int64
		if err := db.Table(table).Count(&count).Error; err != nil || count != 0 {
			t.Fatalf("%s count=%d err=%v", table, count, err)
		}
	}
	if receipt := record(t, db, 1, "op", mutation(1, 0)); receipt.Sequence != 1 {
		t.Fatal(receipt)
	}
}

// TestValidationAndIdentity 验证事务要求、白名单格式及不可变身份；t 为测试上下文；返回：无；事务由测试创建。
func TestValidationAndIdentity(t *testing.T) {
	db := testDB(t)
	r := Repository{}
	if _, err := r.Pull(db, 1, 0, 1); !errors.Is(err, ErrTransactionRequired) {
		t.Fatal(err)
	}
	if _, err := r.LookupReceipt(nil, 1, "op", strings.Repeat("a", 64)); !errors.Is(err, ErrTransactionRequired) {
		t.Fatal(err)
	}
	record(t, db, 1, "create", mutation(1, 0))
	tx := db.Begin()
	defer tx.Rollback()
	if _, err := r.Pull(tx, 0, 0, 1); !errors.Is(err, ErrInvalidArgument) {
		t.Fatal(err)
	}
	for _, limit := range []int{0, 101} {
		if _, err := r.Pull(tx, 1, 0, limit); !errors.Is(err, ErrInvalidArgument) {
			t.Fatal(err)
		}
	}
	if _, err := r.Pull(tx, 1, 2, 1); !errors.Is(err, ErrInvalidArgument) {
		t.Fatal(err)
	}
	if _, err := r.LookupReceipt(tx, 1, "op", "bad"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatal(err)
	}
	invalid := mutation(2, 0)
	invalid.Payload = []byte("invalid")
	duplicate := mutation(2, 0)
	for _, ms := range [][]Mutation{nil, {invalid}, {duplicate, duplicate}} {
		if _, _, err := r.RecordBatch(tx, 1, "bad", strings.Repeat("a", 64), ms); !errors.Is(err, ErrInvalidArgument) {
			t.Fatal(err)
		}
	}
	changedID := mutation(1, 1)
	changedID.ServerID = "2"
	reusedID := mutation(2, 0)
	reusedID.ServerID = "1"
	for _, m := range []Mutation{changedID, reusedID} {
		if _, _, err := r.RecordBatch(tx, 1, "bad", strings.Repeat("a", 64), []Mutation{m}); !errors.Is(err, ErrIdentityConflict) {
			t.Fatal(err)
		}
	}
}

// TestOpaqueServerIDs 验证餐食 UUID、大整数文本、身份隔离及墓碑映射永久保留；t 为测试上下文；返回：无；事务由测试创建。
func TestOpaqueServerIDs(t *testing.T) {
	db := testDB(t)
	r := Repository{}
	meal := mutation(1, 0)
	meal.Module = "health.meal"
	meal.ServerID = "f3d6c0b4-c155-4445-9ee9-8fd983f7ad61"
	large := mutation(2, 0)
	large.ServerID = "18446744073709551615"
	record(t, db, 1, "create", meal, large)
	otherOwner := meal
	otherOwner.UUID = mutation(3, 0).UUID
	record(t, db, 2, "create", otherOwner)
	deleted := meal
	deleted.BaseRevision = 1
	deleted.Tombstone = true
	deleted.Payload = nil
	record(t, db, 1, "delete", deleted)
	tx := db.Begin()
	defer tx.Rollback()
	for _, m := range []Mutation{meal, large} {
		entity, err := r.Resolve(tx, 1, m.Module, m.UUID)
		if err != nil || string(entity.ServerID) != m.ServerID || (m.Module == meal.Module && !entity.Tombstone) {
			t.Fatalf("entity=%+v err=%v", entity, err)
		}
	}
	page, err := r.Pull(tx, 1, 0, 10)
	if err != nil || page.Batches[0].Changes[0].ServerID != ServerID(meal.ServerID) || page.Batches[0].Changes[1].ServerID != ServerID(large.ServerID) || page.Batches[1].Changes[0].ServerID != ServerID(meal.ServerID) {
		t.Fatalf("page=%+v err=%v", page, err)
	}
	// 即使原实体已删除，同 owner/module 的新 UUID 仍不得复用其服务端身份。
	collision := meal
	collision.UUID = mutation(4, 0).UUID
	if _, _, err := r.RecordBatch(tx, 1, "collision", strings.Repeat("a", 64), []Mutation{collision}); !errors.Is(err, ErrIdentityConflict) {
		t.Fatal(err)
	}
	// 同一未落库批的两个不同 UUID 也不能映射到同一个不透明 ID。
	fresh := mutation(5, 0)
	fresh.ServerID = "fresh-server-id"
	duplicate := fresh
	duplicate.UUID = mutation(6, 0).UUID
	if _, _, err := r.RecordBatch(tx, 1, "batch-collision", strings.Repeat("a", 64), []Mutation{fresh, duplicate}); !errors.Is(err, ErrIdentityConflict) {
		t.Fatal(err)
	}
	for _, id := range []string{"", strings.Repeat("x", 129), "tab\tid", "line\nid", "nul\x00id", "del\x7fid", "c1\u0085id", string([]byte{0xff})} {
		invalid := mutation(7, 0)
		invalid.ServerID = id
		if _, _, err := r.RecordBatch(tx, 1, "invalid-id", strings.Repeat("a", 64), []Mutation{invalid}); !errors.Is(err, ErrInvalidArgument) {
			t.Fatalf("id=%q err=%v", id, err)
		}
	}
	boundary := mutation(8, 0)
	boundary.ServerID = strings.Repeat("x", 128)
	if _, _, err := r.RecordBatch(tx, 1, "boundary-id", strings.Repeat("a", 64), []Mutation{boundary}); err != nil {
		t.Fatal(err)
	}
}

// TestMissingBatchesRejected 验证页首、页中、页尾缺批均不能返回残缺成功页；t 为测试上下文；返回：无；事务由测试创建。
func TestMissingBatchesRejected(t *testing.T) {
	for _, missing := range []uint64{1, 2, 3} {
		db := testDB(t)
		for i := 1; i <= 3; i++ {
			record(t, db, 1, fmt.Sprintf("op-%d", i), mutation(i, 0))
		}
		tx := db.Begin()
		if err := tx.Where("owner_id = ? AND sequence = ?", 1, missing).Delete(&Batch{}).Error; err != nil {
			t.Fatal(err)
		}
		page, err := (Repository{}).Pull(tx, 1, 0, 10)
		if !errors.Is(err, ErrCorruptBatch) || page.Next != 0 {
			t.Fatalf("missing=%d page=%+v err=%v", missing, page, err)
		}
		tx.Rollback()
	}
}

// TestTransactionPreconditions 验证每个公开 API 拒绝非事务句柄，并让已结束事务返回数据库错误；t 为测试上下文；返回：无；无事务前置条件。
func TestTransactionPreconditions(t *testing.T) {
	db := testDB(t)
	r := Repository{}
	if _, err := r.LookupReceipt(db, 1, "op", strings.Repeat("a", 64)); !errors.Is(err, ErrTransactionRequired) {
		t.Fatal(err)
	}
	if _, err := r.Resolve(db, 1, "task.item", mutation(1, 0).UUID); !errors.Is(err, ErrTransactionRequired) {
		t.Fatal(err)
	}
	if _, _, err := r.RecordBatch(db, 1, "op", strings.Repeat("a", 64), []Mutation{mutation(1, 0)}); !errors.Is(err, ErrTransactionRequired) {
		t.Fatal(err)
	}
	if _, err := r.Pull(db, 1, 0, 1); !errors.Is(err, ErrTransactionRequired) {
		t.Fatal(err)
	}
	tx := db.Begin()
	if err := tx.Rollback().Error; err != nil {
		t.Fatal(err)
	}
	if _, err := r.Pull(tx, 1, 0, 1); err == nil {
		t.Fatal("closed transaction must fail")
	}
	if _, err := r.LookupReceipt(tx, 1, "op", strings.Repeat("a", 64)); err == nil {
		t.Fatal("closed transaction must fail")
	}
}

// TestWriteFailureRollback 验证写入中途失败后调用方回滚清除半批，且不会消耗水位；t 为测试上下文；返回：无；事务由测试创建。
func TestWriteFailureRollback(t *testing.T) {
	db := testDB(t)
	// 用 SQLite 触发器模拟第二条快照写入失败，覆盖已写入第一条的错误路径。
	if err := db.Exec(`CREATE TRIGGER fail_second_change BEFORE INSERT ON sync_changes WHEN NEW.position = 1 BEGIN SELECT RAISE(ABORT, 'injected failure'); END`).Error; err != nil {
		t.Fatal(err)
	}
	tx := db.Begin()
	if _, _, err := (Repository{}).RecordBatch(tx, 1, "failed", strings.Repeat("a", 64), []Mutation{mutation(1, 0), mutation(2, 0)}); err == nil {
		t.Fatal("expected injected database error")
	}
	if err := tx.Rollback().Error; err != nil {
		t.Fatal(err)
	}
	for _, model := range []any{&AccountWatermark{}, &Entity{}, &Batch{}, &Change{}, &Receipt{}} {
		var count int64
		if err := db.Model(model).Count(&count).Error; err != nil || count != 0 {
			t.Fatalf("%T count=%d err=%v", model, count, err)
		}
	}
	if receipt := record(t, db, 1, "retry", mutation(1, 0)); receipt.Sequence != 1 {
		t.Fatal(receipt)
	}
}

// TestIncompleteBatchRejected 验证损坏批不能推进游标；t 为测试上下文；返回：无；事务由测试创建。
func TestIncompleteBatchRejected(t *testing.T) {
	db := testDB(t)
	record(t, db, 1, "op", mutation(1, 0), mutation(2, 0))
	tx := db.Begin()
	defer tx.Rollback()
	if err := tx.Where("owner_id = ? AND position = ?", 1, 1).Delete(&Change{}).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := (Repository{}).Pull(tx, 1, 0, 1); !errors.Is(err, ErrCorruptBatch) {
		t.Fatal(err)
	}
}
