// 文件职责：验证餐食业务的本人隔离、幂等、手动目标与配置授权，不调用真实AI。
package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"image"
	"image/jpeg"
	"math"
	"testing"
	"time"

	aimodel "personal_assistant_server/internal/ai/model"
	aiconfigmodel "personal_assistant_server/internal/aiconfig/model"
	aiconfigservice "personal_assistant_server/internal/aiconfig/service"
	domain "personal_assistant_server/internal/health/model"
	usermodel "personal_assistant_server/internal/user/model"
)

// confirmedMeal 返回合法确认输入；参数：无；返回值：固定餐食；无副作用。
func confirmedMeal() MealInput {
	return MealInput{ID: "11111111-2222-4333-8444-555555555555", Date: "2026-10-17", MealType: "lunch", Items: []domain.MealItem{{Name: "米饭", Grams: 150, Calories: 174}}, Note: "照片估算"}
}

// requireMealStatus 检查公开错误分类；参数：t 为测试上下文，err 为实际错误，status 为期望HTTP状态；返回值：无；不输出敏感错误正文。
func requireMealStatus(t *testing.T, err error, status int) {
	t.Helper()
	var public *OperationError
	if !errors.As(err, &public) || public.Status != status {
		t.Fatalf("expected %d, got %v", status, err)
	}
}

// TestMealRecordsIsolationAndIdempotency 验证幂等键按本人隔离、同内容返回原时间、冲突不覆盖、按日读删与清空；参数：t 为测试上下文；返回值：无；使用隔离SQLite。
func TestMealRecordsIsolationAndIdempotency(t *testing.T) {
	s, ctx, in := healthFixture(t), context.Background(), confirmedMeal()
	initial, err := s.Nutrition(ctx, 1, in.Date)
	if err != nil || initial.DailyGoal != nil || initial.Meals == nil || len(initial.Meals) != 0 {
		t.Fatalf("empty %#v %v", initial, err)
	}
	for _, uid := range []uint64{1, 2} {
		if _, err := s.PutNutritionGoal(ctx, uid, GoalInput{DailyGoal: float64(uid) * 1000}); err != nil {
			t.Fatal(err)
		}
		if _, err := s.CreateMeal(ctx, uid, in); err != nil {
			t.Fatal(err)
		}
	}
	first, err := s.CreateMeal(ctx, 1, in)
	if err != nil {
		t.Fatal(err)
	}
	again, err := s.CreateMeal(ctx, 1, in)
	if err != nil || !first.CreatedAt.Equal(again.CreatedAt) || first.CreatedAt.IsZero() {
		t.Fatalf("retry %#v %v", again, err)
	}
	changed := in
	changed.Note = "different"
	_, err = s.CreateMeal(ctx, 1, changed)
	requireMealStatus(t, err, 409)
	result, err := s.Nutrition(ctx, 1, in.Date)
	if err != nil || len(result.Meals) != 1 || result.Meals[0].Note != in.Note || *result.DailyGoal != 1000 {
		t.Fatalf("conflict changed row %#v %v", result, err)
	}
	otherDay, err := s.Nutrition(ctx, 1, "2026-10-16")
	if err != nil || len(otherDay.Meals) != 0 {
		t.Fatal("date leaked")
	}
	if err = s.DeleteMeal(ctx, 3, in.ID); err != nil {
		t.Fatal(err)
	}
	result, err = s.Nutrition(ctx, 1, in.Date)
	if err != nil || len(result.Meals) != 1 {
		t.Fatal("foreign delete changed owner")
	}
	if err = s.DeleteMeal(ctx, 1, in.ID); err != nil {
		t.Fatal(err)
	}
	foreign, err := s.Nutrition(ctx, 2, in.Date)
	if err != nil || len(foreign.Meals) != 1 || *foreign.DailyGoal != 2000 {
		t.Fatal("owner delete affected foreign record")
	}
	if _, err = s.CreateMeal(ctx, 1, in); err != nil {
		t.Fatal(err)
	}
	if err = s.Clear(ctx, 1); err != nil {
		t.Fatal(err)
	}
	result, err = s.Nutrition(ctx, 1, in.Date)
	if err != nil || len(result.Meals) != 0 || result.DailyGoal != nil {
		t.Fatal("clear did not remove meals and goal")
	}
	foreign, err = s.Nutrition(ctx, 2, in.Date)
	if err != nil || len(foreign.Meals) != 1 || *foreign.DailyGoal != 2000 {
		t.Fatal("clear affected foreign records")
	}
}

// TestMealValidation 验证非法日期、餐次、UUID、有限正数和目标范围；参数：t 为测试上下文；返回值：无；无效输入不得写库。
func TestMealValidation(t *testing.T) {
	s, ctx := healthFixture(t), context.Background()
	for _, date := range []string{"", "2026-02-30", "2026-2-01", "0000-01-01", "2026-10-17T00:00:00Z"} {
		_, err := s.Nutrition(ctx, 1, date)
		requireMealStatus(t, err, 400)
		input := confirmedMeal()
		input.Date = date
		_, err = s.CreateMeal(ctx, 1, input)
		requireMealStatus(t, err, 400)
	}
	for _, number := range []float64{0, -1, math.Inf(1), math.NaN(), 10001} {
		input := confirmedMeal()
		input.Items[0].Grams = number
		_, err := s.CreateMeal(ctx, 1, input)
		requireMealStatus(t, err, 400)
	}
	for _, number := range []float64{0, -1, math.Inf(1), math.NaN(), 20001} {
		input := confirmedMeal()
		input.Items[0].Calories = number
		_, err := s.CreateMeal(ctx, 1, input)
		requireMealStatus(t, err, 400)
	}
	for _, number := range []float64{0, 999.99, 6000.01, math.Inf(1), math.NaN()} {
		_, err := s.PutNutritionGoal(ctx, 1, GoalInput{DailyGoal: number})
		requireMealStatus(t, err, 400)
	}
	for _, number := range []float64{1000, 6000, 2000.5} {
		if got, err := s.PutNutritionGoal(ctx, 1, GoalInput{DailyGoal: number}); err != nil || got.DailyGoal != number {
			t.Fatal("valid goal rejected")
		}
	}
	input := confirmedMeal()
	input.ID = "bad"
	_, err := s.CreateMeal(ctx, 1, input)
	requireMealStatus(t, err, 400)
	input = confirmedMeal()
	input.MealType = "other"
	_, err = s.CreateMeal(ctx, 1, input)
	requireMealStatus(t, err, 400)
}

// mealUsers 提供配置权限测试所需身份，不访问用户数据库。
type mealUsers struct{}

// Current 返回普通用户；参数：ctx 为上下文，id 为可信身份；返回值：公开用户及nil；无副作用。
func (mealUsers) Current(_ context.Context, id uint64) (*usermodel.User, error) {
	return &usermodel.User{ID: id, Role: usermodel.RoleUser}, nil
}

// mealVision 是无网络的模型替身，并记录分析调用次数。
type mealVision struct {
	calls  int
	result domain.MealAnalysis
	err    error
}

// Complete 禁止餐食流程调用普通聊天；参数：上下文、连接、消息和工具均不使用；返回值：空消息及错误；无网络副作用。
func (*mealVision) Complete(context.Context, aiconfigservice.Connection, []aimodel.Message, []any) (aimodel.Message, error) {
	return aimodel.Message{}, errors.New("unexpected ordinary chat")
}

// AnalyzeMeal 检查90秒截止时间并返回替身结果；参数：ctx 为受限上下文，其余连接和输入不使用；返回值：预设估算及错误；增加调用计数，不保存照片。
func (v *mealVision) AnalyzeMeal(ctx context.Context, _ aiconfigservice.Connection, _ domain.MealAnalysisInput) (domain.MealAnalysis, error) {
	v.calls++
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > 90*time.Second {
		return domain.MealAnalysis{}, errors.New("missing deadline")
	}
	return v.result, v.err
}

// TestMealAnalysisAuthorization 验证同意、配置权限及精确版本先于模型调用，成功分析不创建记录；参数：t 为测试上下文；返回值：无；模型完全替身。
func TestMealAnalysisAuthorization(t *testing.T) {
	s, ctx := healthFixture(t), context.Background()
	if err := s.db.AutoMigrate(&aiconfigmodel.AIProviderConfig{}); err != nil {
		t.Fatal(err)
	}
	configs, err := aiconfigservice.NewService(s.db, mealUsers{})
	if err != nil {
		t.Fatal(err)
	}
	s.configs = configs
	uid, foreign := uint64(1), uint64(2)
	for _, row := range []aiconfigmodel.AIProviderConfig{
		{ID: 1, OwnerType: aiconfigmodel.OwnerTypeUser, OwnerID: &uid, Visibility: aiconfigmodel.VisibilityPrivate, Name: "own", BaseURL: "https://invalid", ModelName: "vision", APIKey: "secret"},
		{ID: 2, OwnerType: aiconfigmodel.OwnerTypeUser, OwnerID: &foreign, Visibility: aiconfigmodel.VisibilityPrivate, Name: "foreign", BaseURL: "https://invalid", ModelName: "vision", APIKey: "secret"},
	} {
		if err := s.db.Create(&row).Error; err != nil {
			t.Fatal(err)
		}
	}
	var own aiconfigmodel.AIProviderConfig
	if err := s.db.First(&own, 1).Error; err != nil {
		t.Fatal(err)
	}
	var photo bytes.Buffer
	if err := jpeg.Encode(&photo, image.NewRGBA(image.Rect(0, 0, 2, 2)), nil); err != nil {
		t.Fatal(err)
	}
	input := domain.MealAnalysisInput{ConfigID: 1, ConfigVersion: own.UpdatedAt.Format(time.RFC3339Nano), Consent: true, Image: "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(photo.Bytes())}
	vision := &mealVision{result: domain.MealAnalysis{Recognized: true, Items: confirmedMeal().Items, Note: "照片估算"}}
	s.client = vision
	bad := input
	bad.Consent = false
	_, err = s.AnalyzeMeal(ctx, 1, bad)
	requireMealStatus(t, err, 400)
	bad = input
	bad.ConfigID = 2
	_, err = s.AnalyzeMeal(ctx, 1, bad)
	requireMealStatus(t, err, 403)
	bad.ConfigID = 999
	_, err = s.AnalyzeMeal(ctx, 1, bad)
	requireMealStatus(t, err, 403)
	bad = input
	bad.ConfigVersion = own.UpdatedAt.Add(-time.Nanosecond).Format(time.RFC3339Nano)
	_, err = s.AnalyzeMeal(ctx, 1, bad)
	requireMealStatus(t, err, 409)
	bad.ConfigVersion = "invalid"
	_, err = s.AnalyzeMeal(ctx, 1, bad)
	requireMealStatus(t, err, 400)
	bad = input
	bad.Image = "https://invalid/photo.jpg"
	_, err = s.AnalyzeMeal(ctx, 1, bad)
	requireMealStatus(t, err, 400)
	if vision.calls != 0 {
		t.Fatal("unauthorized photo sent")
	}
	if _, err = s.AnalyzeMeal(ctx, 1, input); err != nil || vision.calls != 1 {
		t.Fatalf("analysis %v", err)
	}
	result, err := s.Nutrition(ctx, 1, confirmedMeal().Date)
	if err != nil || len(result.Meals) != 0 || result.DailyGoal != nil {
		t.Fatal("analysis persisted meal or goal")
	}
	vision.result = domain.MealAnalysis{Recognized: false, Items: []domain.MealItem{{Name: "米饭", Grams: 100, Calories: 120}}, Note: "矛盾结果"}
	_, err = s.AnalyzeMeal(ctx, 1, input)
	requireMealStatus(t, err, 502)
	vision.result = domain.MealAnalysis{Recognized: false, Items: []domain.MealItem{}, Note: "非食物"}
	if _, err = s.AnalyzeMeal(ctx, 1, input); err != nil {
		t.Fatal(err)
	}
	vision.result.Recognized = true
	_, err = s.AnalyzeMeal(ctx, 1, input)
	requireMealStatus(t, err, 502)
	vision.err = errors.New("private upstream secret")
	_, err = s.AnalyzeMeal(ctx, 1, input)
	requireMealStatus(t, err, 502)
	if err.Error() == vision.err.Error() {
		t.Fatal("upstream error leaked")
	}
}
