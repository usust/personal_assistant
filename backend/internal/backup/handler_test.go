// 文件职责：验证备份 HTTP 的认证边界、稳定信封、禁止缓存及失败不返回成功数据。
package backup

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
)

// handlerExporterStub 将测试函数适配为导出依赖，仅用于检查 HTTP 层输入与失败行为。
type handlerExporterStub func(context.Context, uint64) (*Snapshot, error)

// Export 执行测试替身；参数：ctx 为请求上下文，ownerID 为认证身份；返回值：测试指定的快照或错误，无数据库副作用。
func (stub handlerExporterStub) Export(ctx context.Context, ownerID uint64) (*Snapshot, error) {
	return stub(ctx, ownerID)
}

// handlerSnapshot 创建完整空集合快照；参数：无；返回值：有效版本 1 数据，供 HTTP 编码测试使用，无外部副作用。
func handlerSnapshot() *Snapshot {
	return &Snapshot{
		Format: Format, SchemaVersion: SchemaVersion,
		ExportedAt:   time.Date(2026, 10, 18, 1, 2, 3, 0, time.UTC),
		Source:       Source{Owner: Owner{ID: 7, Account: "my-account", Nickname: "本人"}},
		Task:         TaskData{Lists: []TaskList{}, Tasks: []Task{}, Events: []TaskEvent{}},
		Finance:      FinanceData{Accounts: []FinanceAccount{}, Categories: []FinanceCategory{}, Transactions: []FinanceTransaction{}, Presets: []FinancePreset{}, Events: []FinanceEvent{}, Snapshots: []FinanceSnapshot{}},
		Health:       HealthData{Days: []HealthDay{}, Reports: []HealthReport{}, Meals: []HealthMeal{}, NutritionGoals: []NutritionGoal{}},
		ModelConfigs: []ModelConfig{},
	}
}

// TestHandlerRejectsMissingIdentity 验证直接调用 handler 也要求可信非零 uint64 身份；参数：t 为测试上下文；返回值：无，认证绕过或调用业务依赖时失败。
func TestHandlerRejectsMissingIdentity(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, identity := range []any{nil, uint64(0), "7", 7} {
		// 子测试参数：t 为当前身份用例；返回值：无，检查未认证错误且确保依赖未调用。
		t.Run(strings.TrimSpace(strings.ReplaceAll(toIdentityName(identity), " ", "_")), func(t *testing.T) {
			// 替身参数：ctx 为上下文，ownerID 为身份；返回值：无有效快照；本用例不允许调用。
			handler := &Handler{service: handlerExporterStub(func(ctx context.Context, ownerID uint64) (*Snapshot, error) {
				t.Fatal("未认证请求不得触发导出")
				return nil, errors.New("unexpected export")
			})}
			r := gin.New()
			// 测试中间件参数：c 为上下文；返回值：无，仅设置待验证的不可信身份值。
			r.Use(func(c *gin.Context) {
				if identity != nil {
					c.Set("auth.user_id", identity)
				}
				c.Next()
			})
			r.GET("/export", handler.Export)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/export?ownerId=7", nil))
			assertHandlerError(t, w, http.StatusUnauthorized)
		})
	}
}

// toIdentityName 为身份用例返回唯一名称；参数：identity 为待验证值；返回值：类型标识，无副作用。
func toIdentityName(identity any) string {
	switch identity.(type) {
	case nil:
		return "missing"
	case uint64:
		return "zero-uint64"
	case string:
		return "string"
	default:
		return "wrong-integer-type"
	}
}

// TestRegisteredRouteRequiresAuthentication 验证路由真实认证中间件在缺凭证时拒绝并保留 no-store；参数：t 为测试上下文；返回值：无，不连接数据库。
func TestRegisteredRouteRequiresAuthentication(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	// 缺少 Bearer 头时真实中间件在调用认证服务前就必须终止，因此允许 nil 服务用于此边界测试。
	RegisterRoutes(r.Group("/api"), &Handler{}, auth.RequireLogin(nil))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/backup/export", nil))
	assertHandlerError(t, w, http.StatusUnauthorized)
}

// TestHandlerEnvelopeAndTrustedOwner 验证版本化成功信封及可信身份传递；参数：t 为测试上下文；返回值：无，查询参数不得覆盖本人 ID。
func TestHandlerEnvelopeAndTrustedOwner(t *testing.T) {
	gin.SetMode(gin.TestMode)
	request := httptest.NewRequest(http.MethodGet, "/api/backup/export?ownerId=999&user_id=999&limit=1", nil)
	// 替身参数：ctx 必须沿用请求上下文，ownerID 必须来自认证；返回值：完整快照，无数据库副作用。
	handler := &Handler{service: handlerExporterStub(func(ctx context.Context, ownerID uint64) (*Snapshot, error) {
		if ctx != request.Context() || ownerID != 7 {
			t.Fatalf("身份或上下文未正确传递：%d", ownerID)
		}
		return handlerSnapshot(), nil
	})}
	r := gin.New()
	// 测试认证参数：c 为请求；返回值：无，模拟真实中间件写入已验证身份。
	login := func(c *gin.Context) { c.Set("auth.user_id", uint64(7)); c.Next() }
	RegisterRoutes(r.Group("/api"), handler, login)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, request)
	if w.Code != http.StatusOK || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("状态或缓存头错误：%d %v", w.Code, w.Header())
	}
	var envelope struct {
		Code    int      `json:"code"`
		Message string   `json:"message"`
		Data    Snapshot `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.Code != 200 || envelope.Message != "ok" || envelope.Data.Format != Format || envelope.Data.SchemaVersion != 1 || envelope.Data.Source.Owner.ID != 7 {
		t.Fatalf("信封错误：%s", w.Body.String())
	}
	// 即使数据为空，集合仍是数组，客户端不需要把 null 猜成完整空备份。
	for _, key := range []string{"lists", "tasks", "events", "accounts", "categories", "transactions", "presets", "snapshots", "days", "reports", "meals", "nutritionGoals", "modelConfigs"} {
		if !strings.Contains(w.Body.String(), `"`+key+`":[]`) {
			t.Errorf("集合 %s 不是空数组：%s", key, w.Body.String())
		}
	}
}

// TestHandlerFailureNeverProducesSuccess 验证读取失败、空结果和编码失败都在发送 200 前转为错误；参数：t 为测试上下文；返回值：无，错误正文不得暴露内部秘密。
func TestHandlerFailureNeverProducesSuccess(t *testing.T) {
	invalid := handlerSnapshot()
	invalid.Health.NutritionGoals = []NutritionGoal{{UserID: 7, DailyGoal: math.NaN()}}
	for _, test := range []struct {
		name     string
		snapshot *Snapshot
		err      error
	}{
		{"query-error", handlerSnapshot(), errors.New("SQL secret-api-key internal details")},
		{"nil-result", nil, nil},
		{"encoding-error", invalid, nil},
	} {
		// 子测试参数：t 为当前错误用例；返回值：无，确保失败无部分数据或内部错误泄露。
		t.Run(test.name, func(t *testing.T) {
			// 替身参数：ctx 为请求上下文，ownerID 为本人 ID；返回值：指定错误或无法编码的快照。
			handler := &Handler{service: handlerExporterStub(func(ctx context.Context, ownerID uint64) (*Snapshot, error) { return test.snapshot, test.err })}
			r := gin.New()
			// 测试认证参数：c 为上下文；返回值：无，注入可信身份以触发业务错误路径。
			login := func(c *gin.Context) { c.Set("auth.user_id", uint64(7)); c.Next() }
			RegisterRoutes(r.Group("/api"), handler, login)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/backup/export", nil))
			assertHandlerError(t, w, http.StatusInternalServerError)
			if strings.Contains(w.Body.String(), "secret-api-key") || strings.Contains(w.Body.String(), "SQL") {
				t.Fatalf("内部错误泄露：%s", w.Body.String())
			}
		})
	}
}

// assertHandlerError 检查错误信封；参数：t 为测试上下文，w 为响应记录器，status 为预期错误 HTTP 状态；返回值：无，错误必须 no-store 且 data:null。
func assertHandlerError(t *testing.T, w *httptest.ResponseRecorder, status int) {
	t.Helper()
	var envelope struct {
		Code int             `json:"code"`
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if w.Code != status || envelope.Code != status || string(envelope.Data) != "null" || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("错误信封不符合契约：HTTP %d %s %v", w.Code, w.Body.String(), w.Header())
	}
}
