// 文件职责：验证分类 PATCH、DELETE 路由、HTTP 适配及业务服务的完整调用链。
package finance

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"personal_assistant_server/internal/finance/handler"
	domain "personal_assistant_server/internal/finance/model"
	"personal_assistant_server/internal/finance/service"
	usermodel "personal_assistant_server/internal/user/model"
)

// TestCategoryPatchHTTP 验证真实分类路由的部分更新、统一响应及错误状态；参数：t 为测试上下文；返回值：无，仅使用临时数据库和测试认证身份。
func TestCategoryPatchHTTP(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "category-http.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	// 清理回调关闭临时数据库；参数：无；返回值：无，关闭错误令测试失败。
	t.Cleanup(func() {
		if err := conn.Close(); err != nil {
			t.Error(err)
		}
	})
	if err := db.AutoMigrate(&usermodel.User{}, &domain.Category{}, &domain.Event{}); err != nil {
		t.Fatal(err)
	}
	for _, user := range []usermodel.User{{ID: 1, Account: "one"}, {ID: 2, Account: "two"}} {
		if err := db.Create(&user).Error; err != nil {
			t.Fatal(err)
		}
	}
	router := gin.New()
	// 测试认证回调将固定请求头映射为可信身份；参数：c 为请求上下文；返回值：无，缺少身份时中止请求并返回 401。
	login := func(c *gin.Context) {
		switch c.GetHeader("Test-User") {
		case "1":
			c.Set("auth.user_id", uint64(1))
		case "2":
			c.Set("auth.user_id", uint64(2))
		default:
			c.AbortWithStatus(http.StatusUnauthorized)
			return
		}
		c.Next()
	}
	RegisterRoutes(router.Group("/api"), handler.NewHandler(service.NewService(db)), login)
	// 请求回调检查状态和信封；参数：method/path/body 为固定 HTTP 请求，owner 为测试身份，status 为预期状态；返回值：data 原始 JSON，错误响应不得含业务数据。
	request := func(method, path, body, owner string, status int) json.RawMessage {
		t.Helper()
		writer := httptest.NewRecorder()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Test-User", owner)
		router.ServeHTTP(writer, req)
		if writer.Code != status {
			t.Fatalf("%s %s: 状态 %d，预期 %d，正文 %s", method, path, writer.Code, status, writer.Body.String())
		}
		if status == http.StatusUnauthorized {
			return nil
		}
		var envelope struct {
			Code    int             `json:"code"`
			Message string          `json:"message"`
			Data    json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.Code != status || (status < 400 && envelope.Message != "ok") || (status >= 400 && string(envelope.Data) != "null") {
			t.Fatalf("响应信封错误: %s", writer.Body.String())
		}
		return envelope.Data
	}
	created := request("POST", "/api/finance/categories", `{"name":"咖啡原名","type":"expense","groupKey":"food","icon":"star","color":"#654321"}`, "1", http.StatusCreated)
	var row domain.Category
	if err := json.Unmarshal(created, &row); err != nil || row.ID == 0 {
		t.Fatalf("创建分类未返回 ID: %s %v", created, err)
	}
	path := fmt.Sprintf("/api/finance/categories/%d", row.ID)
	updated := request("PATCH", path, `{"icon":""}`, "1", http.StatusOK)
	var got domain.Category
	if err := json.Unmarshal(updated, &got); err != nil || got.ID != row.ID || got.Name != row.Name || got.Icon != "" || got.GroupKey != "food" || got.Color != row.Color || got.Type != row.Type {
		t.Fatalf("HTTP 单字段清除覆盖未提交字段: %s %v", updated, err)
	}
	updated = request("PATCH", path, `{"name":"  咖啡新名  ","groupKey":"","color":"#123ABC","type":"expense"}`, "1", http.StatusOK)
	if err := json.Unmarshal(updated, &got); err != nil || got.Name != "咖啡新名" || got.GroupKey != "" || got.Icon != "" || got.Color != "#123ABC" || got.Type != row.Type {
		t.Fatalf("HTTP 组合更新错误: %s %v", updated, err)
	}
	request("POST", "/api/finance/categories", `{"name":"重名分类","type":"expense"}`, "1", http.StatusCreated)
	request("PATCH", path, `{"name":"重名分类"}`, "1", http.StatusConflict)
	request("PATCH", path, `{"type":"income"}`, "1", http.StatusBadRequest)
	request("PATCH", path, `{"ownerId":2}`, "1", http.StatusBadRequest)
	request("PATCH", path, `{"color":""}`, "1", http.StatusBadRequest)
	request("PATCH", path, `{"name":null}`, "1", http.StatusBadRequest)
	request("PATCH", path, `{"name":`, "1", http.StatusBadRequest)
	request("PATCH", path, `{"name":"越权"}`, "2", http.StatusNotFound)
	request("PATCH", "/api/finance/categories/99999", `{"name":"不存在"}`, "1", http.StatusNotFound)
	request("PATCH", "/api/finance/categories/0", `{"name":"无效ID"}`, "1", http.StatusBadRequest)
	request("PATCH", "/api/finance/categories/invalid", `{"name":"无效ID"}`, "1", http.StatusBadRequest)
	request("PATCH", path, `{"name":"未认证"}`, "", http.StatusUnauthorized)
	var saved domain.Category
	got.OwnerID = 1
	if err := db.First(&saved, row.ID).Error; err != nil || saved != got {
		t.Fatalf("成功更新未落库或失败请求修改数据: %+v %v", saved, err)
	}
}

// TestCategoryDeleteHTTP 验证分类 DELETE 的路由、认证、归属、幂等及墓碑列表；参数：t 为临时数据库测试上下文；返回值：无，删除沿用空 data 响应且落库审计，同名重建生成新 ID，活动重名与墓碑编辑返回冲突。
func TestCategoryDeleteHTTP(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "category-delete-http.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	// 清理回调关闭临时数据库；参数：无；返回值：无，关闭错误令测试失败。
	t.Cleanup(func() {
		if err := conn.Close(); err != nil {
			t.Error(err)
		}
	})
	if err := db.AutoMigrate(&usermodel.User{}, &domain.Category{}, &domain.Event{}); err != nil {
		t.Fatal(err)
	}
	for _, user := range []usermodel.User{{ID: 1, Account: "one"}, {ID: 2, Account: "two"}} {
		if err := db.Create(&user).Error; err != nil {
			t.Fatal(err)
		}
	}
	router := gin.New()
	// 认证回调为测试请求注入可信身份；参数：c 为 Gin 请求上下文；返回值：无，无测试身份时立即返回 401。
	login := func(c *gin.Context) {
		switch c.GetHeader("Test-User") {
		case "1":
			c.Set("auth.user_id", uint64(1))
		case "2":
			c.Set("auth.user_id", uint64(2))
		default:
			c.AbortWithStatus(http.StatusUnauthorized)
			return
		}
		c.Next()
	}
	RegisterRoutes(router.Group("/api"), handler.NewHandler(service.NewService(db)), login)
	// 请求回调验证状态与统一信封；参数：method/path/body 为固定请求，owner 为身份，status 为预期状态；返回值：业务 JSON 和消息，无身份时均为空，响应错误终止测试。
	request := func(method, path, body, owner string, status int) (json.RawMessage, string) {
		t.Helper()
		writer := httptest.NewRecorder()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Test-User", owner)
		router.ServeHTTP(writer, req)
		if writer.Code != status {
			t.Fatalf("%s %s: 状态 %d，预期 %d，正文 %s", method, path, writer.Code, status, writer.Body.String())
		}
		if status == http.StatusUnauthorized {
			return nil, ""
		}
		var envelope struct {
			Code    int             `json:"code"`
			Message string          `json:"message"`
			Data    json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.Code != status || (status < 400 && envelope.Message != "ok") || (status >= 400 && string(envelope.Data) != "null") {
			t.Fatalf("响应信封错误: %s", writer.Body.String())
		}
		return envelope.Data, envelope.Message
	}
	created, _ := request("POST", "/api/finance/categories", `{"name":"HTTP 待删除","type":"expense","groupKey":"food","icon":"star","color":"#123456"}`, "1", http.StatusCreated)
	var category domain.Category
	if err := json.Unmarshal(created, &category); err != nil || category.ID == 0 || category.Deleted {
		t.Fatalf("前置创建分类错误: %s %v", created, err)
	}
	path := fmt.Sprintf("/api/finance/categories/%d", category.ID)
	request("DELETE", path, "", "", http.StatusUnauthorized)
	request("DELETE", path, "", "2", http.StatusNotFound)
	request("DELETE", "/api/finance/categories/999999", "", "1", http.StatusNotFound)
	request("DELETE", "/api/finance/categories/0", "", "1", http.StatusBadRequest)
	request("DELETE", "/api/finance/categories/invalid", "", "1", http.StatusBadRequest)
	var saved domain.Category
	category.OwnerID = 1
	if err := db.First(&saved, category.ID).Error; err != nil || saved != category {
		t.Fatalf("失败 HTTP 删除改动分类: %+v %v", saved, err)
	}
	var count int64
	if err := db.Model(&domain.Event{}).Where("operation = ?", "finance.category.delete").Count(&count).Error; err != nil || count != 0 {
		t.Fatalf("失败 HTTP 删除留下审计: %d %v", count, err)
	}
	want := category
	want.Deleted = true
	want.NameVersion = want.ID
	for repeat := 0; repeat < 2; repeat++ {
		deleted, _ := request("DELETE", path, "", "1", http.StatusOK)
		if string(deleted) != "null" {
			t.Fatalf("DELETE 未沿用空 data 响应: %s", deleted)
		}
		var got domain.Category
		if err := db.First(&got, category.ID).Error; err != nil || got != want {
			t.Fatalf("DELETE 未保存完整分类墓碑: %+v %v", got, err)
		}
	}
	request("DELETE", path, "", "2", http.StatusNotFound)
	_, message := request("PATCH", path, `{"name":"不得改写墓碑"}`, "1", http.StatusConflict)
	if !strings.Contains(message, "分类已删除，不能编辑") {
		t.Fatalf("墓碑编辑冲突文案错误: %s", message)
	}
	recreated, _ := request("POST", "/api/finance/categories", `{"name":"  HTTP 待删除  ","type":"expense","icon":"bag"}`, "1", http.StatusCreated)
	var rebuilt domain.Category
	if err := json.Unmarshal(recreated, &rebuilt); err != nil || rebuilt.ID == 0 || rebuilt.ID == category.ID || rebuilt.Deleted || rebuilt.Name != category.Name || rebuilt.Icon != "bag" {
		t.Fatalf("HTTP 同名重建未创建新 ID: %s %v", recreated, err)
	}
	if strings.Contains(string(recreated), "NameVersion") || strings.Contains(string(recreated), "nameVersion") || strings.Contains(string(recreated), "name_version") {
		t.Fatalf("HTTP 泄漏内部名称版本: %s", recreated)
	}
	request("POST", "/api/finance/categories", `{"name":"HTTP 待删除","type":"expense"}`, "1", http.StatusConflict)
	listed, _ := request("GET", "/api/finance/categories", "", "1", http.StatusOK)
	var categories []domain.Category
	if err := json.Unmarshal(listed, &categories); err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, row := range categories {
		if row.ID == category.ID {
			found++
			row.OwnerID = 1
			// 内部名称版本不参与 JSON 契约，列表只验证原名称、图标及墓碑状态。
			wantJSON := want
			wantJSON.NameVersion = 0
			if row != wantJSON {
				t.Fatalf("HTTP 列表丢失墓碑状态或原资料: %+v", row)
			}
		}
	}
	if found != 1 {
		t.Fatalf("HTTP 列表未保留唯一墓碑: %d", found)
	}
	foreign, _ := request("GET", "/api/finance/categories", "", "2", http.StatusOK)
	var foreignCategories []domain.Category
	if err := json.Unmarshal(foreign, &foreignCategories); err != nil {
		t.Fatal(err)
	}
	for _, row := range foreignCategories {
		if row.ID == category.ID {
			t.Fatalf("HTTP 分类列表泄漏其他用户墓碑: %+v", row)
		}
	}
	if err := db.First(&saved, category.ID).Error; err != nil || saved != want {
		t.Fatalf("HTTP 删除未落库或列表读取复活分类: %+v %v", saved, err)
	}
	var events []domain.Event
	if err := db.Where("operation = ?", "finance.category.delete").Order("id").Find(&events).Error; err != nil || len(events) != 2 {
		t.Fatalf("HTTP 删除审计数量错误: %+v %v", events, err)
	}
	for _, event := range events {
		if event.OwnerID != 1 || event.EntityID != category.ID || event.Source != "http" {
			t.Fatalf("HTTP DELETE 未映射到正确业务审计: %+v", event)
		}
	}
}
