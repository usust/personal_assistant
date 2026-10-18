// 文件职责：校验餐食、手动目标与本人记录访问，并执行授权后的只读照片分析。
package service

import (
	"context"
	"errors"
	"math"
	"regexp"
	"strings"
	"time"

	airepository "personal_assistant_server/internal/ai/repository"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
	domain "personal_assistant_server/internal/health/model"
	"personal_assistant_server/internal/health/repository"
)

// MealInput 仅接收用户确认后的内容，不接受归属、创建时间或照片。
type MealInput struct {
	ID       string            `json:"id"`
	Date     string            `json:"date"`
	MealType string            `json:"meal_type"`
	Items    []domain.MealItem `json:"items"`
	Note     string            `json:"note"`
}

// GoalInput 只允许用户手动指定每日千卡目标。
type GoalInput struct {
	DailyGoal float64 `json:"daily_goal"`
}

// NutritionResult 保证未设置目标为null且无餐食时返回空数组。
type NutritionResult struct {
	DailyGoal *float64      `json:"daily_goal"`
	Meals     []domain.Meal `json:"meals"`
}

var mealUUID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// validMealDate 验证完整自然日；参数：date 必须严格yyyy-MM-dd且年份为0001–9999；返回值：是否有效；不施加时区或历史范围限制。
func validMealDate(date string) bool {
	parsed, err := time.Parse("2006-01-02", date)
	return err == nil && parsed.Year() >= 1 && parsed.Format("2006-01-02") == date
}

// Nutrition 读取本人某日餐食；接收者：s 已初始化；参数：ctx 为请求上下文，uid 为可信身份，date 为自然日；返回值：目标及列表或公开错误；无外发。
func (s *Service) Nutrition(ctx context.Context, uid uint64, date string) (NutritionResult, error) {
	if !validMealDate(date) {
		return NutritionResult{}, &OperationError{400, "日期须为有效的yyyy-MM-dd"}
	}
	goal, meals, err := repository.Nutrition(s.db.WithContext(ctx), uid, date)
	if err != nil {
		return NutritionResult{}, &OperationError{500, "读取餐食记录失败"}
	}
	return NutritionResult{DailyGoal: goal, Meals: meals}, nil
}

// PutNutritionGoal 更新手动目标；接收者：s 已初始化；参数：ctx 为上下文，uid 为可信身份，input 为1000–6000千卡目标；返回值：目标或公开错误；不会调用AI自动建议目标。
func (s *Service) PutNutritionGoal(ctx context.Context, uid uint64, input GoalInput) (GoalInput, error) {
	if math.IsNaN(input.DailyGoal) || math.IsInf(input.DailyGoal, 0) || input.DailyGoal < 1000 || input.DailyGoal > 6000 {
		return GoalInput{}, &OperationError{400, "每日目标须为1000–6000千卡"}
	}
	if repository.PutNutritionGoal(s.db.WithContext(ctx), uid, input.DailyGoal) != nil {
		return GoalInput{}, &OperationError{500, "保存每日目标失败"}
	}
	return input, nil
}

// CreateMeal 保存用户确认的餐食；接收者：s 已初始化；参数：ctx 为上下文，uid 为可信身份，input 为UUID幂等键及结构化内容；返回值：原始记录或400/409/500公开错误；仅此入口创建记录。
func (s *Service) CreateMeal(ctx context.Context, uid uint64, input MealInput) (domain.Meal, error) {
	if !mealUUID.MatchString(input.ID) || !validMealDate(input.Date) {
		return domain.Meal{}, &OperationError{400, "餐食ID或日期无效"}
	}
	switch input.MealType {
	case "breakfast", "lunch", "dinner", "snack":
	default:
		return domain.Meal{}, &OperationError{400, "餐次无效"}
	}
	if err := domain.ValidateMealItems(input.Items, input.Note, true); err != nil {
		return domain.Meal{}, &OperationError{400, err.Error()}
	}
	meal, err := repository.CreateMeal(s.db.WithContext(ctx), domain.Meal{UserID: uid, ID: strings.ToLower(input.ID), Date: input.Date, MealType: input.MealType, Items: input.Items, Note: input.Note})
	if errors.Is(err, repository.ErrMealConflict) {
		return domain.Meal{}, &OperationError{409, "此餐食ID已用于不同内容"}
	}
	if err != nil {
		return domain.Meal{}, &OperationError{500, "保存餐食失败"}
	}
	return meal, nil
}

// DeleteMeal 幂等删除本人记录；接收者：s 已初始化；参数：ctx 为上下文，uid 为可信身份，id 为UUID；返回值：公开错误或nil；不影响他人记录，不泄漏其存在性。
func (s *Service) DeleteMeal(ctx context.Context, uid uint64, id string) error {
	if !mealUUID.MatchString(id) {
		return &OperationError{400, "餐食ID无效"}
	}
	if repository.DeleteMeal(s.db.WithContext(ctx), uid, strings.ToLower(id)) != nil {
		return &OperationError{500, "删除餐食失败"}
	}
	return nil
}

// AnalyzeMeal 仅在授权、版本与外发同意均有效时分析照片；接收者：s 已初始化；参数：ctx 为上下文，uid 为可信身份，input 含内嵌图片；返回值：照片估算或400/403/409/502公开错误；限时90秒，不保存或日志记录照片、不创建餐食。
func (s *Service) AnalyzeMeal(ctx context.Context, uid uint64, input domain.MealAnalysisInput) (domain.MealAnalysis, error) {
	version, err := time.Parse(time.RFC3339Nano, input.ConfigVersion)
	if !input.Consent || input.ConfigID == 0 || err != nil || version.IsZero() {
		return domain.MealAnalysis{}, &OperationError{400, "请选择配置并同意发送餐食照片"}
	}
	if airepository.ValidateScreenshot(input.Image) != nil {
		return domain.MealAnalysis{}, &OperationError{400, "请提供有效且不超过3MB的JPEG或PNG餐食照片（最长边4096像素）"}
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	if s.configs == nil {
		return domain.MealAnalysis{}, &OperationError{403, "AI配置不可用"}
	}
	connection, currentVersion, err := s.configs.GetUsableVersioned(ctx, uid, input.ConfigID)
	if err != nil {
		return domain.MealAnalysis{}, &OperationError{403, "该AI配置不存在或无权使用"}
	}
	// 版本与连接来自同一条授权查询，避免两次读取间的配置变更导致外发到未同意的连接。
	if currentVersion != input.ConfigVersion {
		return domain.MealAnalysis{}, &OperationError{409, "AI配置已变化，请重新选择并同意照片外发"}
	}
	// 独立视觉接口不暴露对话工具或写入能力，不能复用记账或普通聊天提示词。
	recognizer, ok := s.client.(interface {
		AnalyzeMeal(context.Context, aiconfigservice.Connection, domain.MealAnalysisInput) (domain.MealAnalysis, error)
	})
	if !ok {
		return domain.MealAnalysis{}, &OperationError{502, "餐食视觉分析服务不可用"}
	}
	result, err := recognizer.AnalyzeMeal(ctx, connection, input)
	// 服务层再次约束替代实现，且不向客户端转发上游错误、密钥或响应正文。
	if err != nil || result.Items == nil || (!result.Recognized && len(result.Items) != 0) || domain.ValidateMealItems(result.Items, result.Note, result.Recognized) != nil {
		return domain.MealAnalysis{}, &OperationError{502, "餐食照片分析失败，请稍后重试"}
	}
	return result, nil
}
