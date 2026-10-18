// 文件职责：核对重组业务模块实际注册的路由与本地 OpenAPI 契约，防止同步遗漏或路径漂移。
package router

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	aihandler "personal_assistant_server/internal/ai/handler"
	aiconfighandler "personal_assistant_server/internal/aiconfig/handler"
	authhandler "personal_assistant_server/internal/auth/handler"
	financehandler "personal_assistant_server/internal/finance/handler"
	healthhandler "personal_assistant_server/internal/health/handler"
	taskhandler "personal_assistant_server/internal/task/handler"
	userhandler "personal_assistant_server/internal/user/handler"
)

// TestBusinessRoutesMatchOpenAPI 验证全部业务路由（含餐食）与 OpenAPI 契约双向一致；参数：t 为非空测试上下文；返回值：无，集合为空或路由不一致时报告测试失败；只注册内存路由，不调用数据库、模型或业务处理器。
func TestBusinessRoutesMatchOpenAPI(t *testing.T) {
	// 认证占位回调只用于路由注册；参数：c 为上下文；返回值：无，不处理实际 HTTP 请求。
	login := func(c *gin.Context) { c.Next() }
	engine := Register(Handlers{Health: &healthhandler.Handler{}, Finance: &financehandler.Handler{}, Tasks: &taskhandler.Handler{}, Auth: &authhandler.Handler{}, Users: &userhandler.Handler{}, AI: &aihandler.Handler{}, AIConfig: &aiconfighandler.Handler{}, RequireLogin: login})
	raw, err := os.ReadFile("../../../docs/api/internal.openapi.json")
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Paths map[string]map[string]json.RawMessage `json:"paths"`
	}
	if err = json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	documented := map[string]bool{}
	for path, methods := range spec.Paths {
		for method := range methods {
			documented[strings.ToUpper(method)+" "+path] = true
		}
	}
	actual := map[string]bool{}
	for _, route := range engine.Routes() {
		path := strings.ReplaceAll(route.Path, ":id", "{id}")
		if strings.HasPrefix(path, "/api/auth") || strings.HasPrefix(path, "/api/users") || strings.HasPrefix(path, "/api/setting/ai") {
			continue
		}
		actual[route.Method+" "+path] = true
	}
	// 两侧集合都必须非空，防止路由或契约意外清空后双向比较仍通过。
	if len(actual) == 0 || len(documented) == 0 {
		t.Fatalf("业务路由与契约集合不能为空：实际 %d，文档 %d", len(actual), len(documented))
	}
	for route := range actual {
		if !documented[route] {
			t.Errorf("实际接口未记录：%s", route)
		}
	}
	for route := range documented {
		if !actual[route] {
			t.Errorf("文档接口未注册：%s", route)
		}
	}
}
