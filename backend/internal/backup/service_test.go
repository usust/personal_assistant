// 文件职责：验证本人完整备份的持久化字段、身份隔离、事务一致性和失败原子性，不依赖普通列表服务。
package backup

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	aiconfigmodel "personal_assistant_server/internal/aiconfig/model"
	financemodel "personal_assistant_server/internal/finance/model"
	healthmodel "personal_assistant_server/internal/health/model"
	taskmodel "personal_assistant_server/internal/task/model"
	usermodel "personal_assistant_server/internal/user/model"
)

// backupServiceFixture 将真实持久化记录与导出集合对应；记录保留原始模型，以发现 DTO 遗漏或查询转换丢值。
type backupServiceFixture struct {
	collection string
	model      any
}

// backupServiceModels 返回备份涉及的业务模型；参数：无；返回值：用于测试迁移及字段覆盖的模型列表；无副作用。
func backupServiceModels() []any {
	return []any{
		&taskmodel.List{}, &taskmodel.Task{}, &taskmodel.Event{},
		&financemodel.Account{}, &financemodel.Category{}, &financemodel.Transaction{},
		&financemodel.Preset{}, &financemodel.Event{}, &financemodel.Snapshot{},
		&healthmodel.Day{}, &healthmodel.Report{}, &healthmodel.Meal{}, &healthmodel.NutritionGoal{},
		&aiconfigmodel.AIProviderConfig{},
	}
}

// newBackupServiceTestDB 创建独立 SQLite 内存库并迁移业务表；参数：t 为非空测试上下文；返回值：可读写测试库；失败立即终止测试，清理时关闭连接。
func newBackupServiceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	pool, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	// 内存库绑定单个连接，避免连接池切换到另一份空库；导出中的每次读取仍必须显式使用同一事务。
	pool.SetMaxOpenConns(1)
	// 清理回调关闭内存库；参数：无；返回值：无；关闭失败使测试失败。
	t.Cleanup(func() {
		if err := pool.Close(); err != nil {
			t.Error(err)
		}
	})
	models := append([]any{&usermodel.User{}, &financemodel.SyncReceipt{}}, backupServiceModels()...)
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatal(err)
	}
	return db
}

// createBackupServiceRecord 保存测试记录；参数：t 为测试上下文，db 为测试库，record 为模型指针或模型切片；返回值：无；写入错误立即终止测试。
func createBackupServiceRecord(t *testing.T, db *gorm.DB, record any) {
	t.Helper()
	if err := db.Create(record).Error; err != nil {
		t.Fatal(err)
	}
}

// createBackupServiceOwner 保存含敏感字段的用户；参数：t 为测试上下文，db 为测试库，id 为非零且未占用的身份；返回值：已保存用户；写入失败终止测试。
func createBackupServiceOwner(t *testing.T, db *gorm.DB, id uint64) usermodel.User {
	t.Helper()
	owner := usermodel.User{ID: id, Account: fmt.Sprintf("backup-account-%d", id), Nickname: fmt.Sprintf("备份用户%d", id), PasswordHash: fmt.Sprintf("private-password-hash-%d", id), Role: usermodel.RoleSysAdmin}
	createBackupServiceRecord(t, db, &owner)
	return owner
}

// backupServiceFixtures 构造所有持久化业务字段均有辨识值的记录；参数：owner 为非零归属，ID 按归属分段保证不同用户不冲突；返回值：14 个集合的模型与集合路径；无数据库副作用。
func backupServiceFixtures(owner uint64) []backupServiceFixture {
	id := owner * 100
	parent, target, category, rebate, refund := id+1, id+2, id+3, id+4, id+5
	created := time.Date(2026, 2, 3, 4, 5, 6, 0, time.UTC)
	updated := created.Add(time.Hour)
	return []backupServiceFixture{
		{"task.lists", &taskmodel.List{ID: id, OwnerID: owner, Name: "历史清单", Remark: "保留换行\n和中文", Color: "#123456", Icon: "Calendar", CreatedAt: created, UpdatedAt: updated}},
		{"task.tasks", &taskmodel.Task{ID: id, OwnerID: owner, Icon: "Flag", Title: "已归档子任务", Remark: "完成后仍保留", ListID: id, ParentID: &parent, TaskType: "progress", Priority: "high", StartDate: "2025-01-02", StartTime: "08:30", EndDate: "2025-02-03", EndTime: "19:45", AutoArchive: true, Archived: true, SortOrder: -9, ProgressTotal: 120.25, ProgressCompleted: 99.75, ProgressStep: 0.25, ProgressUnit: "页", CreatedAt: created, UpdatedAt: updated}},
		{"task.events", &taskmodel.Event{ID: id, OwnerID: owner, Operation: "task.archive", EntityID: id, Source: "ios", CreatedAt: created}},
		{"finance.accounts", &financemodel.Account{
			LoanTerms: financemodel.LoanTerms{LoanPrincipal: 123456789, LoanAnnualRate: "3.1250", LoanMethod: "equal_principal", LoanPeriods: 36, LoanPaidPeriods: 4, LoanFirstPaymentDate: "2025-01-15", LoanLender: "贷款银行", LoanReceivingAccountID: target},
			ID:        id, OwnerID: owner, Name: "已归档贷款", AccountType: "loan", Institution: "测试银行", MaskedAccountNumber: "****1234", Cards: []financemodel.AccountCard{{ID: "card-1", Name: "附属卡", MaskedAccountNumber: "****5678"}},
			LoanScheduleJSON: `[{"period":1,"principal":"1234.56","interest":"7.89","customPayment":true}]`, LoanRevision: 7,
			ReminderDays: 3, ReminderTime: "09:05", CreditLimit: 99999999999999, BillingDay: 18, RepaymentDay: 28, BillDayInclusive: true, Selectable: true,
			Balance: -99999999999999, Currency: "CNY", IncludeInNetWorth: true, SortOrder: -3, Notes: "历史贷款原始计划", Archived: true, CreatedAt: created, UpdatedAt: updated,
		}},
		{"finance.categories", &financemodel.Category{ID: category, OwnerID: owner, Name: "已删除分类", Type: "expense", GroupKey: "food", Icon: "ForkKnife", NameVersion: category, Color: "#abcdef", IsDefault: true, Deleted: true}},
		{"finance.transactions", &financemodel.Transaction{
			ID: id, OwnerID: owner, RequestID: "request-original", Fingerprint: "business-idempotency-fingerprint", AccountID: id, TargetAccountID: &target, Type: "transfer", Amount: 99999999999999,
			CategoryID: &category, Counterparty: "历史商户", TransactionTime: "21:34", TransactionDate: "2025-02-03", Description: "仍关联分类墓碑", Status: "void", Source: "web",
			Discount: 101, RefundParentID: &refund, ReimbursementStatus: "pending", Rebate: 203, RebateAccountID: &rebate, RebatePending: true, RebateParentID: &parent, Fee: 17,
			InstallmentJSON: `{"periods":12,"amount":"1234.57","schedule":[{"period":2,"fee":"0.01"}]}`, InstallmentParentID: &target, InstallmentPeriod: 2, InstallmentEditRemoved: true, CreatedAt: created, UpdatedAt: updated,
		}},
		{"finance.presets", &financemodel.Preset{ID: id, OwnerID: owner, Key: "disabled-recurring", Name: "已停用周期计划", Transaction: financemodel.TransactionInput{ReimbursementStatus: "pending", Discount: 101, Rebate: 203, RebateAccountID: &rebate, RebatePending: true, Fee: 17, RequestID: "preset-request", AccountID: id, TargetAccountID: &target, TargetCreditCardID: &parent, Type: "transfer", Amount: 123457, CategoryID: &category, Counterparty: "付款方", TransactionTime: "11:12", TransactionDate: "2025-02-03", Description: "嵌套 JSON 完整字段"}, Frequency: "monthly", StartDate: "2025-01-01", EndDate: "2025-12-31", NextDate: "2025-03-01", Enabled: false, LastError: "历史执行错误"}},
		{"finance.events", &financemodel.Event{ID: id, OwnerID: owner, EntityID: id, Operation: "transaction.delete", Source: "sync", CreatedAt: created}},
		{"finance.snapshots", &financemodel.Snapshot{ID: id, OwnerID: owner, AccountID: id, Balance: -123457, CreatedAt: created}},
		{"health.days", &healthmodel.Day{ID: uint(id), UserID: owner, Date: "2025-02-03", Steps: backupServicePointer(12345.0), ActiveEnergy: backupServicePointer(456.75), Distance: backupServicePointer(8.125), RestingHeartRate: backupServicePointer(61.5), Weight: backupServicePointer(63.25), Timezone: "Asia/Shanghai", UpdatedAt: updated}},
		{"health.reports", &healthmodel.Report{ID: uint(id), UserID: owner, Content: "# 报告原文\n不截断", Snapshot: `{"steps":12345,"source":"HealthKit"}`, ConfigID: uint(id), CreatedAt: created}},
		{"health.meals", &healthmodel.Meal{UserID: owner, ID: "same-id-in-each-user", Date: "2025-02-03", MealType: "dinner", Items: []healthmodel.MealItem{{Name: "米饭", Grams: 123.25, Calories: 160.75}}, Note: "用户确认的备注", CreatedAt: created}},
		{"health.nutritionGoals", &healthmodel.NutritionGoal{UserID: owner, DailyGoal: 1876.5}},
		{"modelConfigs", &aiconfigmodel.AIProviderConfig{ID: uint(id), OwnerType: aiconfigmodel.OwnerTypeUser, OwnerID: &owner, Visibility: aiconfigmodel.VisibilityPrivate, CreatedBy: &owner, IsSelected: true, Name: "本人模型", ProviderName: "custom", BaseURL: "https://model.example.test/v1", ModelName: "vision-test", APIKey: fmt.Sprintf("private-model-api-key-%d", owner), UpdatedAt: updated}},
	}
}

// backupServicePointer 为测试值建立指针；类型参数 T 为任意值类型；参数：value 为待引用值；返回值：独立副本的非 nil 指针；无副作用。
func backupServicePointer[T any](value T) *T { return &value }

// backupServiceCollections 列举备份协议的全部集合；参数：snapshot 为非 nil 完整快照；返回值：路径到实际 DTO 切片的映射；无副作用。
func backupServiceCollections(snapshot *Snapshot) map[string]any {
	return map[string]any{
		"task.lists": snapshot.Task.Lists, "task.tasks": snapshot.Task.Tasks, "task.events": snapshot.Task.Events,
		"finance.accounts": snapshot.Finance.Accounts, "finance.categories": snapshot.Finance.Categories, "finance.transactions": snapshot.Finance.Transactions,
		"finance.presets": snapshot.Finance.Presets, "finance.events": snapshot.Finance.Events, "finance.snapshots": snapshot.Finance.Snapshots,
		"health.days": snapshot.Health.Days, "health.reports": snapshot.Health.Reports, "health.meals": snapshot.Health.Meals, "health.nutritionGoals": snapshot.Health.NutritionGoals,
		"modelConfigs": snapshot.ModelConfigs,
	}
}

// backupServiceJSON 将值转为可比较的无损 JSON 值；参数：t 为测试上下文，value 为可编码值；返回值：数字保留 json.Number 的解码树；编码错误终止测试。
func backupServiceJSON(t *testing.T, value any) any {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.UseNumber()
	var decoded any
	if err := decoder.Decode(&decoded); err != nil {
		t.Fatal(err)
	}
	return decoded
}

// assertBackupServiceFields 核对所有持久化白名单字段及其值；参数：t 为测试上下文，db 为测试库，expected 为真实模型，actual 为导出 DTO；返回值：无；遗漏、额外派生列或值不一致时报告失败。
func assertBackupServiceFields(t *testing.T, db *gorm.DB, expected, actual any) {
	t.Helper()
	modelStatement, dtoStatement := &gorm.Statement{DB: db}, &gorm.Statement{DB: db}
	if err := modelStatement.Parse(expected); err != nil {
		t.Fatal(err)
	}
	if err := dtoStatement.Parse(actual); err != nil {
		t.Fatal(err)
	}
	modelValue, dtoValue := reflect.ValueOf(expected), reflect.ValueOf(actual)
	columns := map[string]bool{}
	for _, field := range modelStatement.Schema.Fields {
		// 密钥唯一允许从完整持久化模型中省略；gorm:- 派生字段没有 DBName，必须排除。
		if field.DBName == "" || field.DBName == "api_key" {
			continue
		}
		columns[field.DBName] = true
		dtoField := dtoStatement.Schema.FieldsByDBName[field.DBName]
		if dtoField == nil {
			t.Errorf("%T 缺少持久化字段 %s", actual, field.DBName)
			continue
		}
		// 直接读取模型字段，避开 GORM 将 serializer 字段包装为带 Schema 指针的数据库值。
		want := field.ReflectValueOf(context.Background(), reflect.Indirect(modelValue))
		got := dtoField.ReflectValueOf(context.Background(), reflect.Indirect(dtoValue))
		if !reflect.DeepEqual(backupServiceComparable(t, want), backupServiceComparable(t, got)) {
			t.Errorf("%T.%s 未完整保留：得到 %#v，期望 %#v", actual, field.DBName, got.Interface(), want.Interface())
		}
	}
	for _, field := range dtoStatement.Schema.Fields {
		if field.DBName != "" && !columns[field.DBName] {
			t.Errorf("%T 意外导出非白名单字段 %s", actual, field.DBName)
		}
	}
}

// backupServiceComparable 按业务值比较不同模型和 DTO 的嵌套结构；参数：t 为测试上下文，value 为有效反射值；返回值：结构字段、切片及无损叶子组成的树；忽略普通 API 的 omitempty，保留 nil 与零值差异。
func backupServiceComparable(t *testing.T, value reflect.Value) any {
	t.Helper()
	if value.Kind() == reflect.Pointer {
		if value.IsNil() {
			return nil
		}
		return backupServiceComparable(t, value.Elem())
	}
	if value.Kind() == reflect.Struct && value.Type() != reflect.TypeOf(time.Time{}) {
		fields := map[string]any{}
		for i := 0; i < value.NumField(); i++ {
			fields[value.Type().Field(i).Name] = backupServiceComparable(t, value.Field(i))
		}
		return fields
	}
	if value.Kind() == reflect.Slice {
		if value.IsNil() {
			return nil
		}
		items := make([]any, value.Len())
		for i := 0; i < value.Len(); i++ {
			items[i] = backupServiceComparable(t, value.Index(i))
		}
		return items
	}
	return backupServiceJSON(t, value.Interface())
}

// TestServiceExportPreservesAllBusinessFields 验证全部集合、关联、历史状态、金额和双用户隔离；参数：t 为非空测试上下文；返回值：无；只写入并读取独立内存库。
func TestServiceExportPreservesAllBusinessFields(t *testing.T) {
	db := newBackupServiceTestDB(t)
	owners := []usermodel.User{createBackupServiceOwner(t, db, 11), createBackupServiceOwner(t, db, 22)}
	fixtures := map[uint64][]backupServiceFixture{}
	for _, owner := range owners {
		fixtures[owner.ID] = backupServiceFixtures(owner.ID)
		for _, fixture := range fixtures[owner.ID] {
			createBackupServiceRecord(t, db, fixture.model)
		}
		createBackupServiceRecord(t, db, &financemodel.SyncReceipt{OwnerID: owner.ID, OperationID: "private-sync-operation", Fingerprint: "private-sync-fingerprint", Result: "private-sync-result-token"})
	}
	// 公共默认分类不属于任何用户；不能因为可见性或默认标记混入本人备份。
	createBackupServiceRecord(t, db, &financemodel.Category{ID: 99999, Name: "全局默认分类", IsDefault: true})
	for _, owner := range owners {
		// 子测试分别导出两位用户；参数：t 为子测试上下文；返回值：无；任何跨用户记录或字段丢失均失败。
		t.Run(owner.Account, func(t *testing.T) {
			before := time.Now().UTC()
			snapshot, err := NewService(db).Export(context.Background(), owner.ID)
			after := time.Now().UTC()
			if err != nil || snapshot == nil {
				t.Fatalf("导出失败：snapshot=%v err=%v", snapshot, err)
			}
			if snapshot.Format != "personal-assistant-backup" || snapshot.SchemaVersion != 1 {
				t.Fatalf("备份协议标识错误：%q v%d", snapshot.Format, snapshot.SchemaVersion)
			}
			if snapshot.Source.Owner != (Owner{ID: owner.ID, Account: owner.Account, Nickname: owner.Nickname}) {
				t.Errorf("来源必须保留准确身份：%+v", snapshot.Source.Owner)
			}
			if snapshot.ExportedAt.Location() != time.UTC || snapshot.ExportedAt.Before(before) || snapshot.ExportedAt.After(after) {
				t.Errorf("导出时间不是当前 UTC：%v", snapshot.ExportedAt)
			}
			collections := backupServiceCollections(snapshot)
			for _, fixture := range fixtures[owner.ID] {
				rows := reflect.ValueOf(collections[fixture.collection])
				if rows.Len() != 1 {
					t.Errorf("%s 应只含本人完整记录，得到 %d 条", fixture.collection, rows.Len())
					continue
				}
				assertBackupServiceFields(t, db, fixture.model, rows.Index(0).Interface())
			}
			// 验证实际传输协议中的精确字符串金额；不能先经浮点数或普通 API 派生值重算。
			encoded := backupServiceJSON(t, snapshot).(map[string]any)
			finance := encoded["finance"].(map[string]any)
			account := finance["accounts"].([]any)[0].(map[string]any)
			transaction := finance["transactions"].([]any)[0].(map[string]any)
			if account["balance"] != "-999999999999.99" || transaction["amount"] != "999999999999.99" || transaction["fee"] != "0.17" {
				t.Errorf("金额精度或 JSON 类型丢失：balance=%v amount=%v fee=%v", account["balance"], transaction["amount"], transaction["fee"])
			}
			assertBackupServiceNoSecrets(t, encoded)
			raw, err := json.Marshal(snapshot)
			if err != nil {
				t.Fatal(err)
			}
			for _, secret := range []string{"private-password-hash-", "private-model-api-key-", "private-sync-"} {
				if strings.Contains(string(raw), secret) {
					t.Errorf("导出包含敏感字段值 %s", secret)
				}
			}
		})
	}
}

// assertBackupServiceNoSecrets 递归验证传输键不含凭证、权限或同步回执；参数：t 为测试上下文，value 为 JSON 解码树；返回值：无；发现禁用字段时报告失败。
func assertBackupServiceNoSecrets(t *testing.T, value any) {
	t.Helper()
	switch node := value.(type) {
	case map[string]any:
		for key, child := range node {
			normalized := strings.ToLower(strings.ReplaceAll(key, "_", ""))
			switch normalized {
			case "apikey", "passwordhash", "password", "token", "accesstoken", "refreshtoken", "syncreceipts", "syncreceipt", "role":
				t.Errorf("备份包含禁用字段 %q", key)
			}
			assertBackupServiceNoSecrets(t, child)
		}
	case []any:
		for _, child := range node {
			assertBackupServiceNoSecrets(t, child)
		}
	}
}

// TestServiceExportModelConfigUsesCreator 验证配置归属与可见范围不取代创建者条件；参数：t 为测试上下文；返回值：无；只导出 created_by 等于本人的配置元数据。
func TestServiceExportModelConfigUsesCreator(t *testing.T) {
	db := newBackupServiceTestDB(t)
	owner, other, group := uint64(11), uint64(22), uint64(333)
	createBackupServiceOwner(t, db, owner)
	createBackupServiceOwner(t, db, other)
	configs := []aiconfigmodel.AIProviderConfig{
		{ID: 7, OwnerType: aiconfigmodel.OwnerTypeUser, OwnerID: &owner, Visibility: aiconfigmodel.VisibilityPrivate, CreatedBy: &owner, Name: "本人私有"},
		{ID: 3, OwnerType: aiconfigmodel.OwnerTypeGroup, OwnerID: &group, Visibility: aiconfigmodel.VisibilityShared, CreatedBy: &owner, Name: "本人创建的群组共享"},
		{ID: 5, OwnerType: aiconfigmodel.OwnerTypeSystem, Visibility: aiconfigmodel.VisibilityPrivate, CreatedBy: &owner, Name: "本人创建的系统配置"},
		{ID: 2, OwnerType: aiconfigmodel.OwnerTypeUser, OwnerID: &owner, Visibility: aiconfigmodel.VisibilityPrivate, CreatedBy: &other, Name: "本人所有但他人创建"},
		{ID: 4, OwnerType: aiconfigmodel.OwnerTypeSystem, Visibility: aiconfigmodel.VisibilityShared, CreatedBy: &other, Name: "他人共享"},
		{ID: 6, OwnerType: aiconfigmodel.OwnerTypeSystem, Visibility: aiconfigmodel.VisibilityShared, Name: "系统初始化"},
	}
	for i := range configs {
		configs[i].APIKey = "private-model-api-key-config"
		configs[i].ProviderName = "custom"
		configs[i].ModelName = "test"
		configs[i].BaseURL = "https://model.example.test"
		createBackupServiceRecord(t, db, &configs[i])
	}
	snapshot, err := NewService(db).Export(context.Background(), owner)
	if err != nil || snapshot == nil {
		t.Fatalf("导出失败：%v", err)
	}
	ids := []uint{}
	for _, config := range snapshot.ModelConfigs {
		ids = append(ids, config.ID)
		if config.CreatedBy == nil || *config.CreatedBy != owner {
			t.Errorf("导出非本人创建的配置：%+v", config)
		}
	}
	if !reflect.DeepEqual(ids, []uint{3, 5, 7}) {
		t.Errorf("创建者筛选或主键排序错误：%v", ids)
	}
	assertBackupServiceFields(t, db, &configs[1], snapshot.ModelConfigs[0])
	assertBackupServiceFields(t, db, &configs[2], snapshot.ModelConfigs[1])
}

// TestServiceExportModelConfigStripsURLCredentials 验证端点元数据不会夹带登录信息、查询或片段凭证；参数：t 为测试上下文；返回值：无；合法无凭证端点保持不变，非法端点置空。
func TestServiceExportModelConfigStripsURLCredentials(t *testing.T) {
	db := newBackupServiceTestDB(t)
	owner := createBackupServiceOwner(t, db, 11)
	cases := []struct{ input, want string }{
		{"https://private-user:private-pass@model.example.test:8443/v1/vision?api_key=private-query-key&region=cn#private-fragment-token", "https://model.example.test:8443/v1/vision"},
		{"http://private-user@model.example.test/v1?unexpected=private-query-value", "http://model.example.test/v1"},
		{"https://model.example.test/v1", "https://model.example.test/v1"},
		{"https://model.example.test/v1?", "https://model.example.test/v1"},
		{"ftp://private-user:private-pass@model.example.test/v1", ""},
		{"relative/path?token=private-query-key", ""},
		{"https://%broken", ""},
		{"", ""},
	}
	for i, testCase := range cases {
		createBackupServiceRecord(t, db, &aiconfigmodel.AIProviderConfig{ID: uint(i + 1), CreatedBy: &owner.ID, Name: fmt.Sprintf("endpoint-%d", i), ProviderName: "custom", ModelName: "test", APIKey: "private-api-key", BaseURL: testCase.input})
	}
	snapshot, err := NewService(db).Export(context.Background(), owner.ID)
	if err != nil || snapshot == nil {
		t.Fatalf("端点备份失败：%v", err)
	}
	if len(snapshot.ModelConfigs) != len(cases) {
		t.Fatalf("端点测试配置数量错误：%d/%d", len(snapshot.ModelConfigs), len(cases))
	}
	for i, config := range snapshot.ModelConfigs {
		if config.BaseURL != cases[i].want {
			t.Errorf("配置 %d 端点泄密或元数据损坏：得到 %q，期望 %q", config.ID, config.BaseURL, cases[i].want)
		}
	}
	raw, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"private-user", "private-pass", "private-query-", "private-fragment-", "private-api-key"} {
		if strings.Contains(string(raw), secret) {
			t.Errorf("端点元数据包含凭证 %q", secret)
		}
	}
}

// TestServiceExportEmptyCollectionsRemainArrays 验证空集合、未设置营养目标且无默认补写；参数：t 为测试上下文；返回值：无；JSON 必须输出 [] 且数据库仍为空。
func TestServiceExportEmptyCollectionsRemainArrays(t *testing.T) {
	db := newBackupServiceTestDB(t)
	owner := createBackupServiceOwner(t, db, 11)
	snapshot, err := NewService(db).Export(context.Background(), owner.ID)
	if err != nil || snapshot == nil {
		t.Fatalf("空备份失败：%v", err)
	}
	for name, collection := range backupServiceCollections(snapshot) {
		raw, err := json.Marshal(collection)
		if err != nil || string(raw) != "[]" {
			t.Errorf("%s 必须为 []：得到 %s，错误 %v", name, raw, err)
		}
	}
	for _, model := range backupServiceModels() {
		var count int64
		if err := db.Model(model).Count(&count).Error; err != nil || count != 0 {
			t.Errorf("%T 导出时不应补写默认记录：count=%d err=%v", model, count, err)
		}
	}
}

// TestServiceExportPreservesZeroNullAndCategoryHistory 验证显式零值、不可用指标与同名分类墓碑独立保留；参数：t 为测试上下文；返回值：无；不允许把零值当缺省值或仅导出活动分类。
func TestServiceExportPreservesZeroNullAndCategoryHistory(t *testing.T) {
	db := newBackupServiceTestDB(t)
	owner := createBackupServiceOwner(t, db, 11)
	createBackupServiceRecord(t, db, &taskmodel.Task{ID: 1, OwnerID: owner.ID, Title: "零进度", ProgressTotal: 0, ProgressCompleted: 0, AutoArchive: false, Archived: false})
	createBackupServiceRecord(t, db, &financemodel.Account{ID: 1, OwnerID: owner.ID, Name: "禁选零余额账户"})
	// GORM 创建时有 true 默认值；显式写入 false 后再验证备份不会把数据库零值替换为默认值。
	if err := db.Model(&financemodel.Account{}).Where("id = ?", 1).Updates(map[string]any{"selectable": false, "bill_day_inclusive": false, "include_in_net_worth": false, "balance": 0}).Error; err != nil {
		t.Fatal(err)
	}
	createBackupServiceRecord(t, db, &healthmodel.Day{ID: 1, UserID: owner.ID, Date: "2025-02-03", Steps: backupServicePointer(0.0), ActiveEnergy: nil, Distance: backupServicePointer(0.0), RestingHeartRate: nil, Weight: nil})
	createBackupServiceRecord(t, db, &healthmodel.NutritionGoal{UserID: owner.ID, DailyGoal: 0})
	createBackupServiceRecord(t, db, &financemodel.Category{ID: 2, OwnerID: owner.ID, Name: "同名分类", Type: "expense", NameVersion: 2, Deleted: true})
	createBackupServiceRecord(t, db, &financemodel.Category{ID: 3, OwnerID: owner.ID, Name: "同名分类", Type: "expense", NameVersion: 0, Deleted: false})
	snapshot, err := NewService(db).Export(context.Background(), owner.ID)
	if err != nil || snapshot == nil {
		t.Fatalf("零值及分类历史导出失败：%v", err)
	}
	encoded := backupServiceJSON(t, snapshot).(map[string]any)
	task := encoded["task"].(map[string]any)["tasks"].([]any)[0].(map[string]any)
	account := encoded["finance"].(map[string]any)["accounts"].([]any)[0].(map[string]any)
	day := encoded["health"].(map[string]any)["days"].([]any)[0].(map[string]any)
	for _, field := range []string{"autoArchive", "archived"} {
		if value, exists := task[field]; !exists || value != false {
			t.Errorf("任务零值 %s 必须显式保留：%v", field, task)
		}
	}
	if value, exists := task["progressTotal"]; !exists || value != json.Number("0") {
		t.Errorf("任务零进度必须显式保留：%v", task)
	}
	if value, exists := task["parentId"]; !exists || value != nil {
		t.Errorf("任务空父节点必须显式保留：%v", task)
	}
	for _, field := range []string{"selectable", "billDayInclusive", "includeInNetWorth"} {
		if value, exists := account[field]; !exists || value != false {
			t.Errorf("账户 false 字段 %s 不应改为缺省 true：%v", field, account)
		}
	}
	if account["balance"] != "0.00" {
		t.Errorf("零余额应保留精确金额协议：%v", account["balance"])
	}
	if day["steps"] != json.Number("0") || day["distance"] != json.Number("0") {
		t.Errorf("健康已测零值不能转成 null：%v", day)
	}
	for _, field := range []string{"active_energy", "resting_heart_rate", "weight"} {
		if value, exists := day[field]; !exists || value != nil {
			t.Errorf("不可用健康指标 %s 必须为 null：%v", field, day)
		}
	}
	if len(snapshot.Health.NutritionGoals) != 1 || snapshot.Health.NutritionGoals[0].DailyGoal != 0 {
		t.Errorf("已保存零目标不得当作未设置：%+v", snapshot.Health.NutritionGoals)
	}
	if len(snapshot.Finance.Categories) != 2 || !snapshot.Finance.Categories[0].Deleted || snapshot.Finance.Categories[0].NameVersion != 2 || snapshot.Finance.Categories[1].Deleted || snapshot.Finance.Categories[1].NameVersion != 0 {
		t.Errorf("同名活动分类与历史墓碑必须独立保留：%+v", snapshot.Finance.Categories)
	}
}

// TestServiceExportDoesNotApplyListLimits 验证记录数量超过业务列表上限时不截断；参数：t 为测试上下文；返回值：无；历史及停用记录都必须完整输出并按主键排序。
func TestServiceExportDoesNotApplyListLimits(t *testing.T) {
	db := newBackupServiceTestDB(t)
	owner := createBackupServiceOwner(t, db, 11)
	const total = 1105
	tasks, transactions, days, reports, meals := []taskmodel.Task{}, []financemodel.Transaction{}, []healthmodel.Day{}, []healthmodel.Report{}, []healthmodel.Meal{}
	// 倒序写入超过 1000 条，覆盖任务/流水默认 100 条、健康 30 天及报告 20 条等列表限制。
	for i := total; i > 0; i-- {
		tasks = append(tasks, taskmodel.Task{ID: uint64(i), OwnerID: owner.ID, Title: fmt.Sprintf("历史任务%d", i), Archived: i%2 == 0})
		transactions = append(transactions, financemodel.Transaction{ID: uint64(i), OwnerID: owner.ID, RequestID: fmt.Sprintf("historical-%d", i), Status: "void", Amount: financemodel.Money(i), InstallmentEditRemoved: true})
		days = append(days, healthmodel.Day{ID: uint(i), UserID: owner.ID, Date: time.Date(2010, 1, i, 0, 0, 0, 0, time.UTC).Format("2006-01-02")})
		reports = append(reports, healthmodel.Report{ID: uint(i), UserID: owner.ID, Content: fmt.Sprintf("旧报告%d", i)})
		meals = append(meals, healthmodel.Meal{UserID: owner.ID, ID: fmt.Sprintf("meal-%04d", i), Date: "2010-01-01", Items: []healthmodel.MealItem{}})
	}
	for _, records := range []any{&tasks, &transactions, &days, &reports, &meals} {
		if err := db.CreateInBatches(records, 50).Error; err != nil {
			t.Fatal(err)
		}
	}
	snapshot, err := NewService(db).Export(context.Background(), owner.ID)
	if err != nil || snapshot == nil {
		t.Fatalf("大量数据导出失败：%v", err)
	}
	for name, rows := range map[string]any{"tasks": snapshot.Task.Tasks, "transactions": snapshot.Finance.Transactions, "days": snapshot.Health.Days, "reports": snapshot.Health.Reports, "meals": snapshot.Health.Meals} {
		values := reflect.ValueOf(rows)
		if values.Len() != total {
			t.Errorf("%s 被列表阈值截断：%d/%d", name, values.Len(), total)
			continue
		}
		for i := 0; i < total; i++ {
			id := values.Index(i).FieldByName("ID")
			if id.Kind() == reflect.String {
				if id.String() != fmt.Sprintf("meal-%04d", i+1) {
					t.Errorf("%s 顺序或记录不完整，位置 %d 得到 %v", name, i, id)
					break
				}
			} else if id.Uint() != uint64(i+1) {
				t.Errorf("%s 顺序或记录不完整，位置 %d 得到 %v", name, i, id)
				break
			}
		}
	}
}

// TestBackupDTOCoversPersistentSchema 验证 DTO 白名单覆盖全部持久化列并排除展示字段，且所有业务 JSON 字段都保留零值；参数：t 为测试上下文；返回值：无；模型新增字段未纳入备份时失败。
func TestBackupDTOCoversPersistentSchema(t *testing.T) {
	db := newBackupServiceTestDB(t)
	collections := backupServiceCollections(&Snapshot{})
	for _, fixture := range backupServiceFixtures(11) {
		dtoType := reflect.TypeOf(collections[fixture.collection]).Elem()
		assertBackupServiceFields(t, db, reflect.New(reflect.TypeOf(fixture.model).Elem()).Interface(), reflect.New(dtoType).Interface())
	}
	// 嵌套 serializer 也属于恢复所需的业务字段，不能只校验顶层数据库列名。
	pairs := [][2]any{{financemodel.AccountCard{}, AccountCard{}}, {financemodel.TransactionInput{}, PresetTransaction{}}, {healthmodel.MealItem{}, MealItem{}}}
	for _, pair := range pairs {
		modelType, dtoType := reflect.TypeOf(pair[0]), reflect.TypeOf(pair[1])
		if modelType.NumField() != dtoType.NumField() {
			t.Errorf("%v 嵌套字段数不完整：%d/%d", dtoType, dtoType.NumField(), modelType.NumField())
		}
		for i := 0; i < modelType.NumField(); i++ {
			field := modelType.Field(i)
			dtoField, ok := dtoType.FieldByName(field.Name)
			if !ok || strings.Split(field.Tag.Get("json"), ",")[0] != dtoField.Tag.Get("json") || field.Type != dtoField.Type {
				t.Errorf("%v.%s 嵌套字段类型或 JSON 键不完整", dtoType, field.Name)
			}
		}
	}
	assertBackupServiceJSONTags(t, reflect.TypeOf(Snapshot{}))
}

// assertBackupServiceJSONTags 递归检查 DTO 字段无省略或隐藏；参数：t 为测试上下文，valueType 为 DTO 结构、指针或切片类型；返回值：无；time.Time 和原始类型作为叶子处理，无副作用。
func assertBackupServiceJSONTags(t *testing.T, valueType reflect.Type) {
	t.Helper()
	if valueType.Kind() == reflect.Pointer || valueType.Kind() == reflect.Slice {
		assertBackupServiceJSONTags(t, valueType.Elem())
		return
	}
	if valueType.Kind() != reflect.Struct || valueType == reflect.TypeOf(time.Time{}) {
		return
	}
	for i := 0; i < valueType.NumField(); i++ {
		field := valueType.Field(i)
		tag := field.Tag.Get("json")
		if tag == "" || tag == "-" || strings.Contains(tag, "omitempty") || strings.Contains(tag, "omitzero") {
			t.Errorf("%v.%s 不应隐藏或省略恢复字段：%q", valueType, field.Name, tag)
		}
		assertBackupServiceJSONTags(t, field.Type)
	}
}

// TestServiceExportRejectsPartialSnapshots 验证晚期缺表、损坏 serializer 和取消上下文均丢弃整个备份；参数：t 为测试上下文；返回值：无；每个子测试使用独立内存库。
func TestServiceExportRejectsPartialSnapshots(t *testing.T) {
	cases := []struct{ name, table, column string }{
		{"missing-final-table", "setting_ai_configurations", ""},
		{"invalid-account-cards", "finance_accounts_v2", "cards"},
		{"invalid-preset-transaction", "finance_presets_v2", "transaction"},
		{"invalid-meal-items", "health_meals", "items"},
	}
	for _, testCase := range cases {
		// 子测试先写入完整快照再损坏单个较晚的读取；参数：t 为子测试上下文；返回值：无；不能将前面成功读取的集合返回为部分成功。
		t.Run(testCase.name, func(t *testing.T) {
			db := newBackupServiceTestDB(t)
			owner := createBackupServiceOwner(t, db, 11)
			for _, fixture := range backupServiceFixtures(owner.ID) {
				createBackupServiceRecord(t, db, fixture.model)
			}
			if testCase.column == "" {
				if err := db.Migrator().DropTable(testCase.table); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := db.Table(testCase.table).Where("1 = 1").UpdateColumn(testCase.column, "{invalid-json").Error; err != nil {
					t.Fatal(err)
				}
			}
			snapshot, err := NewService(db).Export(context.Background(), owner.ID)
			if err == nil || snapshot != nil {
				t.Errorf("读取失败必须返回 nil 快照和错误：snapshot=%v err=%v", snapshot, err)
			}
		})
	}
	// 已取消的上下文不允许开始读取，即使业务库和身份均有效也不得返回空的成功快照。
	db := newBackupServiceTestDB(t)
	owner := createBackupServiceOwner(t, db, 11)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	snapshot, err := NewService(db).Export(ctx, owner.ID)
	if snapshot != nil || !errors.Is(err, context.Canceled) {
		t.Errorf("取消请求必须失败且保留错误链：snapshot=%v err=%v", snapshot, err)
	}
}

// TestServiceExportRejectsInvalidIdentityAndDatabase 验证身份、数据库及来源记录前置条件；参数：t 为测试上下文；返回值：无；所有失败都返回 nil 快照。
func TestServiceExportRejectsInvalidIdentityAndDatabase(t *testing.T) {
	db := newBackupServiceTestDB(t)
	createBackupServiceOwner(t, db, 11)
	cases := []struct {
		name    string
		service *Service
		owner   uint64
	}{
		{"zero-owner", NewService(db), 0},
		{"unknown-owner", NewService(db), 999},
		{"nil-service", nil, 11},
		{"nil-database", NewService(nil), 11},
	}
	for _, testCase := range cases {
		// 子测试调用非法前置条件；参数：t 为子测试上下文；返回值：无；必须得到明确错误而不是 panic 或空成功。
		t.Run(testCase.name, func(t *testing.T) {
			snapshot, err := testCase.service.Export(context.Background(), testCase.owner)
			if err == nil || snapshot != nil {
				t.Errorf("前置条件错误必须返回 nil 快照：snapshot=%v err=%v", snapshot, err)
			}
		})
	}
}

// backupServiceSQLObserver 在真实 SQLite 连接外记录事务和 SQL；不模拟查询结果，以证明每个导出集合确实在同一 *sql.Tx 中读取。
type backupServiceSQLObserver struct {
	*sql.DB
	options      []sql.TxOptions
	transactions []*sql.Tx
	queries      []string
	queryTxs     []*sql.Tx
	commits      int
	rollbacks    int
	cancelAt     int
	cancel       context.CancelFunc
	commitError  error
}

// BeginTx 记录选项并建立真实事务；参数：ctx 为请求上下文，options 为只读隔离选项且不得为 nil；返回值：带观测的事务连接或建事务错误；副作用为开启 SQLite 事务。
func (observer *backupServiceSQLObserver) BeginTx(ctx context.Context, options *sql.TxOptions) (gorm.ConnPool, error) {
	if options == nil {
		return nil, errors.New("备份事务必须显式指定选项")
	}
	observer.options = append(observer.options, *options)
	tx, err := observer.DB.BeginTx(ctx, options)
	if err != nil {
		return nil, err
	}
	observer.transactions = append(observer.transactions, tx)
	return &backupServiceObservedTx{Tx: tx, observer: observer}, nil
}

// QueryContext 记录错误地绕过事务的直接查询；参数：ctx 为请求上下文，query 为 SQL，args 为绑定值；返回值：真实查询结果和错误；副作用为增加观测记录。
func (observer *backupServiceSQLObserver) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	observer.queries = append(observer.queries, query)
	observer.queryTxs = append(observer.queryTxs, nil)
	return observer.DB.QueryContext(ctx, query, args...)
}

// backupServiceObservedTx 保留真实 SQL 事务并记录其使用；嵌入的 Tx 提供其余数据库连接方法。
type backupServiceObservedTx struct {
	*sql.Tx
	observer *backupServiceSQLObserver
}

// QueryContext 记录事务查询并可在指定查询前取消请求；参数：ctx 为请求上下文，query 为 SQL，args 为绑定值；返回值：同一真实事务的查询结果及错误；不替换数据。
func (tx *backupServiceObservedTx) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	tx.observer.queries = append(tx.observer.queries, query)
	tx.observer.queryTxs = append(tx.observer.queryTxs, tx.Tx)
	if tx.observer.cancel != nil && len(tx.observer.queries) == tx.observer.cancelAt {
		tx.observer.cancel()
	}
	return tx.Tx.QueryContext(ctx, query, args...)
}

// Commit 记录提交且可注入提交失败；参数：无；返回值：提交错误或注入错误；注入失败时回滚真实事务以释放内存库连接。
func (tx *backupServiceObservedTx) Commit() error {
	tx.observer.commits++
	if tx.observer.commitError != nil {
		_ = tx.Tx.Rollback()
		return tx.observer.commitError
	}
	return tx.Tx.Commit()
}

// Rollback 记录回滚并释放真实事务；参数：无；返回值：SQLite 回滚错误或 nil；重复回滚可返回 sql.ErrTxDone。
func (tx *backupServiceObservedTx) Rollback() error {
	tx.observer.rollbacks++
	return tx.Tx.Rollback()
}

// observeBackupServiceSQL 为服务创建连接观测副本；参数：t 为测试上下文，db 为已完成迁移及写入的测试库；返回值：独立 GORM 会话及观测器；不修改原会话的 ConnPool。
func observeBackupServiceSQL(t *testing.T, db *gorm.DB) (*gorm.DB, *backupServiceSQLObserver) {
	t.Helper()
	pool, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	observer := &backupServiceSQLObserver{DB: pool}
	observed := db.Session(&gorm.Session{NewDB: true, Initialized: true})
	observed.ConnPool = observer
	observed.Statement.ConnPool = observer
	return observed, observer
}

// TestServiceExportUsesOneReadOnlyRepeatableReadTransaction 验证身份与所有集合共用一个真实事务；参数：t 为测试上下文；返回值：无；也验证查询不读取密码、APIKey 或回执表。
func TestServiceExportUsesOneReadOnlyRepeatableReadTransaction(t *testing.T) {
	db := newBackupServiceTestDB(t)
	owner := createBackupServiceOwner(t, db, 11)
	observed, observer := observeBackupServiceSQL(t, db)
	snapshot, err := NewService(observed).Export(context.Background(), owner.ID)
	if err != nil || snapshot == nil {
		t.Fatalf("观测导出失败：%v", err)
	}
	if len(observer.options) != 1 || observer.options[0] != (sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true}) {
		t.Fatalf("必须开启一次只读可重复读事务：%+v", observer.options)
	}
	if len(observer.transactions) != 1 || len(observer.queries) != 15 || observer.commits != 1 || observer.rollbacks != 0 {
		t.Fatalf("身份及 14 集合必须在一次成功提交内读取：tx=%d queries=%d commit=%d rollback=%d", len(observer.transactions), len(observer.queries), observer.commits, observer.rollbacks)
	}
	for i, query := range observer.queries {
		if observer.queryTxs[i] != observer.transactions[0] {
			t.Errorf("第 %d 次读取绕过一致事务：%s", i+1, query)
		}
		for _, secret := range []string{"password_hash", "api_key", "sync_receipts", "SELECT *"} {
			if strings.Contains(query, secret) {
				t.Errorf("第 %d 次读取不应读取敏感或无限字段 %q：%s", i+1, secret, query)
			}
		}
	}
}

// TestServiceExportDropsSnapshotOnMidReadCancelOrCommitFailure 验证读到部分数据后取消及最终提交失败仍无成功快照；参数：t 为测试上下文；返回值：无；使用真实事务并检查错误链。
func TestServiceExportDropsSnapshotOnMidReadCancelOrCommitFailure(t *testing.T) {
	for _, name := range []string{"cancel-during-read", "commit-failure"} {
		// 子测试分别注入读取中取消和提交失败；参数：t 为测试上下文；返回值：无；两者都必须丢弃已读取的数据。
		t.Run(name, func(t *testing.T) {
			db := newBackupServiceTestDB(t)
			owner := createBackupServiceOwner(t, db, 11)
			for _, fixture := range backupServiceFixtures(owner.ID) {
				createBackupServiceRecord(t, db, fixture.model)
			}
			observed, observer := observeBackupServiceSQL(t, db)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			wantError := context.Canceled
			if name == "cancel-during-read" {
				observer.cancelAt, observer.cancel = 12, cancel
			} else {
				wantError = errors.New("injected-commit-failure")
				observer.commitError = wantError
			}
			snapshot, err := NewService(observed).Export(ctx, owner.ID)
			if snapshot != nil || !errors.Is(err, wantError) {
				t.Errorf("晚期错误必须丢弃完整快照且保留错误链：snapshot=%v err=%v", snapshot, err)
			}
			if name == "cancel-during-read" && (len(observer.queries) != 12 || observer.commits != 0 || observer.rollbacks != 1) {
				t.Errorf("取消后应停止后续查询并回滚：query=%d commit=%d rollback=%d", len(observer.queries), observer.commits, observer.rollbacks)
			}
			if name == "commit-failure" && (len(observer.queries) != 15 || observer.commits != 1) {
				t.Errorf("提交错误测试必须先完成全部读取：query=%d commit=%d", len(observer.queries), observer.commits)
			}
		})
	}
}
