// 文件职责：提供餐食记录、手动目标和只读视觉分析的严格JSON HTTP边界。
package handler

import (
	"io"
	"net/http"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/auth"
	domain "personal_assistant_server/internal/health/model"
	"personal_assistant_server/internal/health/service"
	"personal_assistant_server/internal/response"
)

// nutritionBody 严格解析受限JSON；参数：c 为认证请求，dst 为目标指针，max 为字节上限，required 为必填顶层字段；返回值：成功与否；错误写统一400信封，不记录正文。
func nutritionBody(c *gin.Context, dst any, max int, required ...string) bool {
	reader := http.MaxBytesReader(c.Writer, c.Request.Body, int64(max))
	defer reader.Close()
	raw, err := io.ReadAll(reader)
	if err != nil || domain.DecodeNutritionJSON(raw, dst, max, required...) != nil {
		response.Error(c, 400, "餐食请求格式或字段无效")
		return false
	}
	return true
}

// Nutrition 返回本人指定日的餐食及可空目标；接收者：h 已初始化；参数：c 为登录请求，date须yyyy-MM-dd；返回值：无；成功写200统一信封，不访问他人记录。
func (h *Handler) Nutrition(c *gin.Context) {
	uid, _ := auth.UserID(c)
	result, err := h.service.Nutrition(c.Request.Context(), uid, c.Query("date"))
	if err != nil {
		writeError(c, err)
		return
	}
	response.Success(c, 200, result)
}

// PutNutritionGoal 保存本人手动每日目标；接收者：h 已初始化；参数：c 为登录请求，仅接受daily_goal；返回值：无；写200或统一错误，不自动生成极低目标。
func (h *Handler) PutNutritionGoal(c *gin.Context) {
	var input service.GoalInput
	if !nutritionBody(c, &input, 64<<10, "daily_goal") {
		return
	}
	uid, _ := auth.UserID(c)
	result, err := h.service.PutNutritionGoal(c.Request.Context(), uid, input)
	if err != nil {
		writeError(c, err)
		return
	}
	response.Success(c, 200, result)
}

// CreateMeal 保存用户明确确认的结构化餐食；接收者：h 已初始化；参数：c 为登录请求，须含UUID、日期、餐次、项目和备注；返回值：无；成功及同内容重试均返回200原记录，不接受照片或归属字段。
func (h *Handler) CreateMeal(c *gin.Context) {
	var input service.MealInput
	if !nutritionBody(c, &input, 64<<10, "id", "date", "meal_type", "items", "note") {
		return
	}
	uid, _ := auth.UserID(c)
	meal, err := h.service.CreateMeal(c.Request.Context(), uid, input)
	if err != nil {
		writeError(c, err)
		return
	}
	response.Success(c, 200, meal)
}

// DeleteMeal 幂等删除本人餐食；接收者：h 已初始化；参数：c 为登录请求且id为UUID路径参数；返回值：无；成功写200空data，他人或不存在记录同样不泄漏存在性。
func (h *Handler) DeleteMeal(c *gin.Context) {
	uid, _ := auth.UserID(c)
	if err := h.service.DeleteMeal(c.Request.Context(), uid, c.Param("id")); err != nil {
		writeError(c, err)
		return
	}
	response.Success(c, 200, nil)
}

// AnalyzeMeal 分析授权照片但不保存记录；接收者：h 已初始化；参数：c 为登录请求且含配置版本、同意和内嵌图片，正文最多6MiB；返回值：无；写200估算或统一400/403/409/502信封，图片不日志或持久化。
func (h *Handler) AnalyzeMeal(c *gin.Context) {
	var input domain.MealAnalysisInput
	if !nutritionBody(c, &input, 6<<20, "config_id", "config_version", "consent", "image") {
		return
	}
	uid, _ := auth.UserID(c)
	result, err := h.service.AnalyzeMeal(c.Request.Context(), uid, input)
	if err != nil {
		writeError(c, err)
		return
	}
	response.Success(c, 200, result)
}
