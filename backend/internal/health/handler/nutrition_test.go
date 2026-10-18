// 文件职责：验证餐食HTTP契约、严格JSON与统一信封，模型与身份采用本地测试替身。
package handler_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	"image/jpeg"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	aimodel "personal_assistant_server/internal/ai/model"
	aiconfigmodel "personal_assistant_server/internal/aiconfig/model"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
	"personal_assistant_server/internal/health"
	"personal_assistant_server/internal/health/handler"
	domain "personal_assistant_server/internal/health/model"
	"personal_assistant_server/internal/health/service"
	"personal_assistant_server/internal/response"
	usermodel "personal_assistant_server/internal/user/model"
	userservice "personal_assistant_server/internal/user/service"
)

// httpMealVision 返回预设餐食结果，不访问网络。
type httpMealVision struct{ err error }

// Complete 禁止调用普通聊天；参数：上下文、连接、消息、工具均不使用；返回值：空消息和错误；无副作用。
func (*httpMealVision) Complete(context.Context, aiconfigservice.Connection, []aimodel.Message, []any) (aimodel.Message, error) {
	return aimodel.Message{}, errors.New("unexpected chat")
}

// AnalyzeMeal 返回不可辨认的照片结果或预设错误；参数：上下文、连接、输入均不使用；返回值：非nil空项目和错误；无持久化或网络调用。
func (v *httpMealVision) AnalyzeMeal(context.Context, aiconfigservice.Connection, domain.MealAnalysisInput) (domain.MealAnalysis, error) {
	return domain.MealAnalysis{Recognized: false, Items: []domain.MealItem{}, Note: "无法辨认食物"}, v.err
}

// mealHTTPFixture 创建真实路由和隔离数据库；参数：t 为测试上下文；返回值：路由、无网络模型替身及合法分析输入；测试结束关闭数据库。
func mealHTTPFixture(t *testing.T) (*gin.Engine, *httpMealVision, domain.MealAnalysisInput) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "meal.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&domain.Day{}, &domain.Report{}, &domain.Meal{}, &domain.NutritionGoal{}, &usermodel.User{}, &aiconfigmodel.AIProviderConfig{}); err != nil {
		t.Fatal(err)
	}
	// 清理回调无参数和返回值；关闭测试数据库，失败令测试报错。
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
	for _, row := range []usermodel.User{{ID: 1, Account: "one", Role: usermodel.RoleUser}, {ID: 2, Account: "two", Role: usermodel.RoleUser}} {
		if err = db.Create(&row).Error; err != nil {
			t.Fatal(err)
		}
	}
	uid := uint64(1)
	config := aiconfigmodel.AIProviderConfig{OwnerType: aiconfigmodel.OwnerTypeUser, OwnerID: &uid, Visibility: aiconfigmodel.VisibilityPrivate, Name: "vision", BaseURL: "https://invalid", ModelName: "vision", APIKey: "private-key"}
	if err = db.Create(&config).Error; err != nil {
		t.Fatal(err)
	}
	users, err := userservice.NewService(db)
	if err != nil {
		t.Fatal(err)
	}
	configs, err := aiconfigservice.NewService(db, users)
	if err != nil {
		t.Fatal(err)
	}
	vision := &httpMealVision{}
	engine := gin.New()
	// 测试认证中间件参数c为请求；返回无；仅测试可信上下文传递及未登录拒绝，非生产身份校验。
	login := func(c *gin.Context) {
		if c.GetHeader("Test-User") == "" {
			response.AbortError(c, 401, "请登录")
			return
		}
		id := uint64(1)
		if c.GetHeader("Test-User") == "2" {
			id = 2
		}
		c.Set("auth.user_id", id)
		c.Next()
	}
	health.RegisterRoutes(engine.Group("/api"), handler.New(service.NewService(db, configs, vision)), login)
	var photo bytes.Buffer
	if err = jpeg.Encode(&photo, image.NewRGBA(image.Rect(0, 0, 2, 2)), nil); err != nil {
		t.Fatal(err)
	}
	return engine, vision, domain.MealAnalysisInput{ConfigID: config.ID, ConfigVersion: config.UpdatedAt.Format(time.RFC3339Nano), Consent: true, Image: "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(photo.Bytes())}
}

// mealHTTPRequest 调用内存路由并检查信封；参数：t 为测试上下文，engine 为路由，method/path/body为请求，user为空表示未登录，status为期望状态；返回值：data原始JSON；不使用网络。
func mealHTTPRequest(t *testing.T, engine *gin.Engine, method, path, body, user string, status int) json.RawMessage {
	t.Helper()
	req := httptest.NewRequest(method, "/api/health-management"+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Test-User", user)
	out := httptest.NewRecorder()
	engine.ServeHTTP(out, req)
	var envelope struct {
		Code    int             `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(out.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("invalid envelope %v", err)
	}
	if out.Code != status || envelope.Code != status || envelope.Message == "" || envelope.Data == nil {
		t.Fatalf("HTTP %d expected %d: %s", out.Code, status, out.Body.String())
	}
	if status >= 400 && string(envelope.Data) != "null" {
		t.Fatal("error data must be null")
	}
	return envelope.Data
}

// mealRequestJSON 返回固定确认正文；参数：无；返回值：不含归属的JSON；无副作用。
func mealRequestJSON() string {
	return `{"id":"11111111-2222-4333-8444-555555555555","date":"2026-10-17","meal_type":"lunch","items":[{"name":"米饭","grams":150,"calories":174}],"note":"照片估算"}`
}

// TestMealHTTPContract 验证认证、精确返回字段、幂等、本人查询删除和清空；参数：t 为测试上下文；返回值：无；全部请求在内存执行。
func TestMealHTTPContract(t *testing.T) {
	engine, _, _ := mealHTTPFixture(t)
	for _, request := range []struct{ method, path string }{{"GET", "/nutrition?date=2026-10-17"}, {"PUT", "/nutrition/goal"}, {"POST", "/meals"}, {"DELETE", "/meals/11111111-2222-4333-8444-555555555555"}, {"POST", "/meal-analysis"}} {
		mealHTTPRequest(t, engine, request.method, request.path, `{}`, "", 401)
	}
	data := mealHTTPRequest(t, engine, "GET", "/nutrition?date=2026-10-17", "", "1", 200)
	if string(data) != `{"daily_goal":null,"meals":[]}` {
		t.Fatalf("empty contract %s", data)
	}
	mealHTTPRequest(t, engine, "PUT", "/nutrition/goal", `{"daily_goal":2200}`, "1", 200)
	first := mealHTTPRequest(t, engine, "POST", "/meals", mealRequestJSON(), "1", 200)
	again := mealHTTPRequest(t, engine, "POST", "/meals", mealRequestJSON(), "1", 200)
	if !bytes.Equal(first, again) {
		t.Fatal("retry changed original record")
	}
	var meal map[string]json.RawMessage
	if err := json.Unmarshal(first, &meal); err != nil {
		t.Fatal(err)
	}
	if len(meal) != 6 {
		t.Fatalf("unexpected meal fields: %s", first)
	}
	for _, key := range []string{"id", "date", "meal_type", "items", "note", "created_at"} {
		if meal[key] == nil {
			t.Fatalf("missing %s", key)
		}
	}
	var created string
	if json.Unmarshal(meal["created_at"], &created) != nil {
		t.Fatal("invalid created_at")
	}
	if _, err := time.Parse(time.RFC3339Nano, created); err != nil {
		t.Fatal(err)
	}
	mealHTTPRequest(t, engine, "POST", "/meals", strings.Replace(mealRequestJSON(), "照片估算", "changed", 1), "1", 409)
	foreign := mealHTTPRequest(t, engine, "GET", "/nutrition?date=2026-10-17", "", "2", 200)
	if string(foreign) != `{"daily_goal":null,"meals":[]}` {
		t.Fatal("foreign read leaked")
	}
	mealHTTPRequest(t, engine, "DELETE", "/meals/11111111-2222-4333-8444-555555555555", "", "2", 200)
	data = mealHTTPRequest(t, engine, "GET", "/nutrition?date=2026-10-17", "", "1", 200)
	if !strings.Contains(string(data), `"daily_goal":2200`) || !strings.Contains(string(data), `"米饭"`) {
		t.Fatal("foreign delete changed owner")
	}
	mealHTTPRequest(t, engine, "DELETE", "", "", "1", 200)
	data = mealHTTPRequest(t, engine, "GET", "/nutrition?date=2026-10-17", "", "1", 200)
	if string(data) != `{"daily_goal":null,"meals":[]}` {
		t.Fatal("clear contract")
	}
}

// TestMealHTTPStrictInputs 验证null、未知字段、缺失字段、数值、日期和体积校验；参数：t 为测试上下文；返回值：无；所有非法输入写400信封。
func TestMealHTTPStrictInputs(t *testing.T) {
	engine, _, _ := mealHTTPFixture(t)
	for _, body := range []string{`null`, `{}`, mealRequestJSON() + `{}`, strings.Replace(mealRequestJSON(), `"grams":150`, `"grams":null`, 1), strings.Replace(mealRequestJSON(), `"calories":174`, `"calories":null`, 1), strings.Replace(mealRequestJSON(), `"grams":150`, `"grams":1e999`, 1), strings.Replace(mealRequestJSON(), `"grams":150`, `"grams":-1`, 1), strings.Replace(mealRequestJSON(), `"calories":174`, `"calories":0`, 1), strings.Replace(mealRequestJSON(), `"name":"米饭"`, `"name":null`, 1), strings.Replace(mealRequestJSON(), `"note":"照片估算"`, `"note":null`, 1), strings.Replace(mealRequestJSON(), `,"note":"照片估算"`, ``, 1), strings.Replace(mealRequestJSON(), `"note":"照片估算"`, `"note":"","user_id":2`, 1), strings.Replace(mealRequestJSON(), `"grams":150`, `"grams":150,"unknown":1`, 1), strings.Replace(mealRequestJSON(), `"2026-10-17"`, `"2026-02-30"`, 1), strings.Repeat(" ", 64<<10) + mealRequestJSON()} {
		mealHTTPRequest(t, engine, "POST", "/meals", body, "1", 400)
	}
	for _, body := range []string{`null`, `{}`, `{"daily_goal":null}`, `{"daily_goal":999}`, `{"daily_goal":6001}`, `{"daily_goal":2000,"user_id":2}`, `{"daily_goal":2000} {}`} {
		mealHTTPRequest(t, engine, "PUT", "/nutrition/goal", body, "1", 400)
	}
	for _, path := range []string{"/nutrition", "/nutrition?date=2026-02-30", "/nutrition?date=2026-2-01"} {
		mealHTTPRequest(t, engine, "GET", path, "", "1", 400)
	}
	mealHTTPRequest(t, engine, "DELETE", "/meals/not-uuid", "", "1", 400)
}

// TestMealAnalysisHTTP 验证分析版本授权、同意、返回形状和脱敏错误；参数：t 为测试上下文；返回值：无；照片和模型均为内存测试数据。
func TestMealAnalysisHTTP(t *testing.T) {
	engine, vision, input := mealHTTPFixture(t)
	raw, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	data := mealHTTPRequest(t, engine, "POST", "/meal-analysis", string(raw), "1", 200)
	if string(data) != `{"recognized":false,"items":[],"note":"无法辨认食物"}` {
		t.Fatalf("analysis contract %s", data)
	}
	mealHTTPRequest(t, engine, "POST", "/meal-analysis", string(raw), "2", 403)
	mealHTTPRequest(t, engine, "POST", "/meal-analysis", strings.Replace(string(raw), `"consent":true`, `"consent":false`, 1), "1", 400)
	mealHTTPRequest(t, engine, "POST", "/meal-analysis", strings.Replace(string(raw), `"consent":true`, `"consent":null`, 1), "1", 400)
	input.ConfigVersion = time.Now().Add(-24 * time.Hour).Format(time.RFC3339Nano)
	stale, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	mealHTTPRequest(t, engine, "POST", "/meal-analysis", string(stale), "1", 409)
	vision.err = errors.New("private-key should never leak")
	mealHTTPRequest(t, engine, "POST", "/meal-analysis", string(raw), "1", 502)
	data = mealHTTPRequest(t, engine, "GET", "/nutrition?date=2026-10-17", "", "1", 200)
	if string(data) != `{"daily_goal":null,"meals":[]}` {
		t.Fatal("analysis created record")
	}
}
