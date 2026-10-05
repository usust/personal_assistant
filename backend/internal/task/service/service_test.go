// 文件职责：执行任务业务规则与事务编排。

package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"personal_assistant_server/internal/capability"
	domain "personal_assistant_server/internal/task/model"
	"personal_assistant_server/internal/user/model"
)

// fixture 创建隔离数据库和两名用户；参数：t 为测试上下文；返回值：业务服务，测试结束关闭连接，不访问生产数据。
func fixture(t *testing.T) *Service {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "tasks.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&model.User{}, &domain.List{}, &domain.Task{}, &domain.Event{}); err != nil {
		t.Fatal(err)
	}
	for _, u := range []model.User{{ID: 1, Account: "one"}, {ID: 2, Account: "two"}} {
		if err = db.Create(&u).Error; err != nil {
			t.Fatal(err)
		}
	}
	// 清理回调关闭测试连接；参数：无；返回值：无，关闭错误令测试失败。
	t.Cleanup(func() {
		conn, err := db.DB()
		if err == nil {
			err = conn.Close()
		}
		if err != nil {
			t.Error(err)
		}
	})
	return NewService(db)
}

// run 执行测试命令；参数：t、s 为测试与服务，op 为操作，id 为目标，changes 为字段；返回值：结果，失败终止测试。
func run(t *testing.T, s *Service, op string, id uint64, changes any) any {
	t.Helper()
	raw, err := json.Marshal(changes)
	if err != nil {
		t.Fatal(err)
	}
	out, err := s.Execute(context.Background(), capability.Actor{UserID: 1}, op, Input{ID: id, Changes: raw}, "http")
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// TestTaskRules 验证隔离、精度、零值更新、循环校验、事务回滚及级联；参数：t 为测试上下文；返回值：无。
func TestTaskRules(t *testing.T) {
	s := fixture(t)
	ctx := context.Background()
	actor := capability.Actor{UserID: 1}
	list := run(t, s, "task_list.create", 0, map[string]any{"name": "工作"}).(domain.List)
	root := run(t, s, "task.create", 0, map[string]any{"title": "项目", "listId": list.ID}).(domain.Task)
	child := run(t, s, "task.create", 0, map[string]any{"title": "阅读", "remark": "原文", "listId": list.ID, "parentId": root.ID, "taskType": "subtask", "progressTotal": "1", "progressStep": "0.1"}).(domain.Task)
	for range 3 {
		if _, err := s.Execute(ctx, actor, "task.progress", Input{ID: child.ID, Operation: "increment"}, "http"); err != nil {
			t.Fatal(err)
		}
	}
	rows := run(t, s, "task.list", 0, nil).([]domain.Task)
	if rows[1].ProgressCompleted != 0.3 {
		t.Fatalf("精度丢失: %+v", rows[1])
	}
	run(t, s, "task.update", child.ID, map[string]any{"archived": true})
	updated := run(t, s, "task.update", child.ID, map[string]any{"archived": false, "remark": "", "progressCompleted": "0", "parentId": nil}).(domain.Task)
	if updated.Archived || updated.Remark != "" || updated.ProgressCompleted != 0 || updated.ParentID != nil || updated.Title != "阅读" {
		t.Fatalf("PATCH 错误: %+v", updated)
	}
	run(t, s, "task.update", child.ID, map[string]any{"parentId": root.ID})
	cases := []struct {
		actor uint64
		op    string
		input Input
		want  error
	}{
		{2, "task.update", Input{ID: child.ID, Changes: json.RawMessage(`{"title":"窃取"}`)}, ErrNotFound},
		{1, "task.update", Input{ID: root.ID, Changes: json.RawMessage(`{"parentId":2}`)}, ErrInvalid},
		{1, "task.update", Input{ID: child.ID, Changes: json.RawMessage(`{"owner_id":2}`)}, ErrInvalid},
		{1, "task.update", Input{ID: child.ID, Changes: json.RawMessage(`{"progressCompleted":"0.001"}`)}, ErrInvalid},
		{1, "task.update", Input{ID: child.ID, Changes: json.RawMessage(`{"title":null}`)}, ErrInvalid},
		{1, "task.delete", Input{ID: root.ID}, ErrConflict},
		{1, "task.reorder", Input{TaskIDs: []uint64{child.ID, 999}}, ErrNotFound},
	}
	before := run(t, s, "task.events", 0, nil).([]domain.Event)
	for _, tc := range cases {
		if _, err := s.Execute(ctx, capability.Actor{UserID: tc.actor}, tc.op, tc.input, "ai"); !errors.Is(err, tc.want) {
			t.Fatalf("%s: %v", tc.op, err)
		}
	}
	after := run(t, s, "task.events", 0, nil).([]domain.Event)
	if len(after) != len(before) {
		t.Fatal("失败写入了事件")
	}
	rows = run(t, s, "task.list", 0, nil).([]domain.Task)
	if rows[1].SortOrder != 1 {
		t.Fatal("排序未回滚")
	}
	if _, err := s.Execute(ctx, actor, "task.delete", Input{ID: root.ID, Cascade: true}, "http"); err != nil {
		t.Fatal(err)
	}
	if len(run(t, s, "task.list", 0, nil).([]domain.Task)) != 0 {
		t.Fatal("后代未级联删除")
	}
}

// TestTaskTreeAssignment 验证图标兼容、整树清单迁移、非法父关系和写中回滚；参数：t为测试上下文；返回值：无；仅写隔离SQLite数据库。
func TestTaskTreeAssignment(t *testing.T) {
	s := fixture(t)
	actor := capability.Actor{UserID: 1}
	source := run(t, s, "task_list.create", 0, map[string]any{"name": "源"}).(domain.List)
	target := run(t, s, "task_list.create", 0, map[string]any{"name": "目标"}).(domain.List)
	root := run(t, s, "task.create", 0, map[string]any{"title": "根", "listId": source.ID, "icon": "custom-preserved"}).(domain.Task)
	child := run(t, s, "task.create", 0, map[string]any{"title": "子容器", "listId": source.ID, "parentId": root.ID}).(domain.Task)
	leaf := run(t, s, "task.create", 0, map[string]any{"title": "归档叶", "listId": source.ID, "parentId": child.ID, "taskType": "subtask", "archived": true}).(domain.Task)
	run(t, s, "task.update", root.ID, map[string]any{"remark": "仅备注"})
	rows := run(t, s, "task.list", 0, nil).([]domain.Task)
	if rows[0].Icon != "custom-preserved" || rows[1].Icon != "Folder" {
		t.Fatal("图标默认或未知键被覆盖")
	}
	// 无效目标和后代父级均应在写前拒绝，原始树不能部分移动。
	for _, changes := range []map[string]any{{"listId": 999, "parentId": nil}, {"listId": target.ID, "parentId": child.ID}, {"taskType": "subtask"}} {
		raw, _ := json.Marshal(changes)
		if _, err := s.Execute(context.Background(), actor, "task.update", Input{ID: root.ID, Changes: raw}, "http"); err == nil {
			t.Fatalf("非法更新未拒绝: %v", changes)
		}
	}
	// SQLite触发器在后代更新时失败，证明根已经写入也会由服务事务全部回滚。
	if err := s.db.Exec(fmt.Sprintf("CREATE TRIGGER fail_descendant_move BEFORE UPDATE OF list_id ON tasks_v2 WHEN OLD.id = %d BEGIN SELECT RAISE(ABORT, 'injected descendant failure'); END", leaf.ID)).Error; err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(map[string]any{"listId": target.ID, "parentId": nil, "title": "不应保留"})
	if _, err := s.Execute(context.Background(), actor, "task.update", Input{ID: root.ID, Changes: raw}, "http"); err == nil {
		t.Fatal("注入失败未传播")
	}
	rows = run(t, s, "task.list", 0, nil).([]domain.Task)
	for _, row := range rows {
		if row.ListID != source.ID {
			t.Fatal("失败未回滚全树")
		}
	}
	if rows[0].Title != "根" {
		t.Fatal("根标题未回滚")
	}
	if err := s.db.Exec("DROP TRIGGER fail_descendant_move").Error; err != nil {
		t.Fatal(err)
	}
	moved := run(t, s, "task.update", root.ID, map[string]any{"listId": target.ID, "parentId": nil}).(domain.Task)
	if moved.ListID != target.ID || moved.ParentID != nil {
		t.Fatal("根归属未更新")
	}
	rows = run(t, s, "task.list", 0, nil).([]domain.Task)
	for _, row := range rows {
		if row.ListID != target.ID {
			t.Fatal("后代未整体移动")
		}
	}
	if !rows[2].Archived || *rows[2].ParentID != child.ID {
		t.Fatal("移动改变归档或层级")
	}
	// 模拟真实历史具体任务容器，不迁移；未变父关系的PATCH仍可写，新增下级和直接步进被拒绝。
	if err := s.db.Model(&domain.Task{}).Where("id = ?", root.ID).Update("task_type", "subtask").Error; err != nil {
		t.Fatal(err)
	}
	run(t, s, "task.update", child.ID, map[string]any{"title": "保留历史父关系"})
	run(t, s, "task.update", root.ID, map[string]any{"remark": "兼容容器"})
	raw, _ = json.Marshal(map[string]any{"title": "非法新叶", "listId": target.ID, "parentId": root.ID, "taskType": "subtask"})
	if _, err := s.Execute(context.Background(), actor, "task.create", Input{Changes: raw}, "http"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("允许具体任务新增下级: %v", err)
	}
	if _, err := s.Execute(context.Background(), actor, "task.progress", Input{ID: root.ID, Operation: "increment"}, "http"); !errors.Is(err, ErrConflict) {
		t.Fatalf("历史容器被直接步进: %v", err)
	}
	run(t, s, "task.update", root.ID, map[string]any{"taskType": "main"})
}
