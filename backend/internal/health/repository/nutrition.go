// 文件职责：按本人归属读写结构化餐食和每日目标，不接收或持久化照片。
package repository

import (
	"errors"
	"reflect"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	domain "personal_assistant_server/internal/health/model"
)

// ErrMealConflict 表示本人同一幂等键已被不同内容使用。
var ErrMealConflict = errors.New("餐食幂等键内容冲突")

// Nutrition 读取本人指定日期餐食及目标；参数：db 为上下文数据库，uid 为可信身份，date 为有效日期；返回值：可空目标、非nil餐食列表和数据库错误；无写入。
func Nutrition(db *gorm.DB, uid uint64, date string) (*float64, []domain.Meal, error) {
	meals := []domain.Meal{}
	if err := db.Where("user_id = ? AND date = ?", uid, date).Order("created_at ASC, id ASC").Find(&meals).Error; err != nil {
		return nil, nil, err
	}
	var goal domain.NutritionGoal
	err := db.Where("user_id = ?", uid).Take(&goal).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, meals, nil
	}
	if err != nil {
		return nil, nil, err
	}
	return &goal.DailyGoal, meals, nil
}

// PutNutritionGoal 保存本人手动目标；参数：db 为上下文数据库，uid 为可信身份，value 为已校验千卡；返回值：数据库错误；冲突更新只允许daily_goal字段。
func PutNutritionGoal(db *gorm.DB, uid uint64, value float64) error {
	row := domain.NutritionGoal{UserID: uid, DailyGoal: value}
	return db.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "user_id"}}, DoUpdates: clause.Assignments(map[string]any{"daily_goal": value})}).Create(&row).Error
}

// CreateMeal 原子创建或读取本人幂等记录；参数：db 为上下文数据库，meal 为已校验且仅包含可信归属的记录；返回值：原始记录或数据库/内容冲突错误；相同重试不覆盖创建时间。
func CreateMeal(db *gorm.DB, meal domain.Meal) (domain.Meal, error) {
	// 唯一键承担并发去重，不采用先查后插；冲突时绝不更新原内容。
	err := db.Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "user_id"}, {Name: "id"}}, DoNothing: true}).Create(&meal).Error
	if err != nil {
		return domain.Meal{}, err
	}
	var stored domain.Meal
	if err = db.Where("user_id = ? AND id = ?", meal.UserID, meal.ID).Take(&stored).Error; err != nil {
		return domain.Meal{}, err
	}
	if stored.Date != meal.Date || stored.MealType != meal.MealType || stored.Note != meal.Note || !reflect.DeepEqual(stored.Items, meal.Items) {
		return domain.Meal{}, ErrMealConflict
	}
	return stored, nil
}

// DeleteMeal 删除本人餐食；参数：db 为上下文数据库，uid 为可信身份，id 为已校验UUID；返回值：数据库错误；不存在或他人记录均无副作用且不泄漏存在性。
func DeleteMeal(db *gorm.DB, uid uint64, id string) error {
	return db.Where("user_id = ? AND id = ?", uid, id).Delete(&domain.Meal{}).Error
}
