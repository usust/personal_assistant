// 文件职责：验证任务 HTTP 创建、部分更新、删除和错误的统一响应契约。
package handler

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	domain "personal_assistant_server/internal/task/model"
	"personal_assistant_server/internal/task/service"
	usermodel "personal_assistant_server/internal/user/model"
)

// TestHTTPEnvelope 验证完整接口链的响应和零值更新；参数：t 为测试上下文；返回值：无；使用独立数据库和可信测试身份，不连接生产服务。
func TestHTTPEnvelope(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "http.db")), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.AutoMigrate(&usermodel.User{}, &domain.Task{}, &domain.List{}, &domain.Event{}); err != nil {
		t.Fatal(err)
	}
	if err = db.Create(&usermodel.User{ID: 1, Account: "test"}).Error; err != nil {
		t.Fatal(err)
	}
	// 清理回调释放连接；参数：无；返回值：无，关闭错误令测试失败。
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
	h := NewHandler(service.NewService(db))
	r := gin.New()
	// 认证测试回调写入可信身份；参数：c 为请求；返回值：无，仅修改请求上下文。
	r.Use(func(c *gin.Context) { c.Set("auth.user_id", uint64(1)); c.Next() })
	r.POST("/lists", h.Handle("task_list.create"))
	r.PATCH("/lists/:id", h.Handle("task_list.update"))
	r.DELETE("/lists/:id", h.Handle("task_list.delete"))
	// 请求测试回调解析信封；参数：method/path/body 为固定请求，status 为预期状态；返回值：响应对象，异常令测试失败。
	request := func(method, path, body string, status int) map[string]any {
		t.Helper()
		w := httptest.NewRecorder()
		req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		req.Header.Set("Content-Type", "application/json")
		r.ServeHTTP(w, req)
		var out map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if w.Code != status || out["code"] != float64(status) {
			t.Fatalf("response %d %s", w.Code, w.Body.String())
		}
		if status < 400 && out["message"] != "ok" {
			t.Fatal(out)
		}
		return out
	}
	created := request("POST", "/lists", `{"name":"测试","remark":"初始"}`, 201)
	if created["data"].(map[string]any)["icon"] != "List" {
		t.Fatal("default icon changed")
	}
	updated := request("PATCH", "/lists/1", `{"remark":""}`, 200)
	data := updated["data"].(map[string]any)
	if data["remark"] != "" || data["name"] != "测试" {
		t.Fatal("partial update overwrote fields")
	}
	if request("PATCH", "/lists/1", `{"ownerId":2}`, 400)["data"] != nil {
		t.Fatal("error data must be null")
	}
	if request("DELETE", "/lists/1", "", 200)["data"] != nil {
		t.Fatal("delete data must be null")
	}
	request("DELETE", "/lists/1", "", 404)
}
