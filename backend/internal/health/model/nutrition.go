// 文件职责：定义用户确认后的餐食、手动热量目标及共用输入校验，不保存照片。
package model

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"strings"
	"time"
	"unicode/utf8"
)

// MealItem 保存一项食物的照片估算或用户修正值；单位为克和千卡。
type MealItem struct {
	Name     string  `json:"name"`
	Grams    float64 `json:"grams"`
	Calories float64 `json:"calories"`
}

// Meal 只保存用户明确确认的结构化记录，ID 在用户范围内作为幂等键。
type Meal struct {
	UserID    uint64     `json:"-" gorm:"primaryKey;autoIncrement:false"`
	ID        string     `json:"id" gorm:"primaryKey;size:36"`
	Date      string     `json:"date" gorm:"size:10;index"`
	MealType  string     `json:"meal_type" gorm:"size:16"`
	Items     []MealItem `json:"items" gorm:"serializer:json;type:text"`
	Note      string     `json:"note" gorm:"type:text"`
	CreatedAt time.Time  `json:"created_at"`
}

// TableName 返回餐食表名；参数：无；返回值：表名；无副作用。
func (Meal) TableName() string { return "health_meals" }

// NutritionGoal 仅保存本人手动设置的每日目标，不根据照片自动生成目标。
type NutritionGoal struct {
	UserID    uint64  `json:"-" gorm:"primaryKey;autoIncrement:false"`
	DailyGoal float64 `json:"daily_goal"`
}

// TableName 返回目标表名；参数：无；返回值：表名；无副作用。
func (NutritionGoal) TableName() string { return "health_nutrition_goals" }

// MealAnalysisInput 要求明确的配置版本、外发同意和内嵌图片；图片只用于本次分析。
type MealAnalysisInput struct {
	ConfigID      uint   `json:"config_id"`
	ConfigVersion string `json:"config_version"`
	Consent       bool   `json:"consent"`
	Image         string `json:"image"`
}

// MealAnalysis 是只读视觉结果，不含任何可自动创建记录的字段。
type MealAnalysis struct {
	Recognized bool       `json:"recognized"`
	Items      []MealItem `json:"items"`
	Note       string     `json:"note"`
}

// ValidateMealItems 校验食物项和备注；参数：items 最多20项，note 最多1500 UTF-8字节，required 为是否至少一项；返回值：公开校验错误或nil；无副作用。
func ValidateMealItems(items []MealItem, note string, required bool) error {
	if len(items) > 20 || (required && len(items) == 0) || !utf8.ValidString(note) || len(note) > 1500 {
		return errors.New("餐食需包含1–20项，备注不能超过1500字节")
	}
	for _, item := range items {
		if !utf8.ValidString(item.Name) || strings.TrimSpace(item.Name) == "" || len(item.Name) > 120 || !positiveBounded(item.Grams, 10000) || !positiveBounded(item.Calories, 20000) {
			return errors.New("食物名称或估算数值无效")
		}
	}
	return nil
}

// positiveBounded 验证有限正数；参数：value 为待检数值，max 为正上限；返回值：是否在范围内；无副作用。
func positiveBounded(value, max float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && value > 0 && value <= max
}

// DecodeNutritionJSON 严格解码餐食JSON；参数：raw 为正文，dst 为目标指针，max 为字节上限，required 为顶层必填字段；返回值：校验错误或nil；拒绝未知字段、任何null、重复键、尾随内容及无效UTF-8，不记录正文。
func DecodeNutritionJSON(raw []byte, dst any, max int, required ...string) error {
	invalid := errors.New("餐食JSON格式或字段无效")
	if len(raw) == 0 || len(raw) > max || !utf8.Valid(raw) {
		return invalid
	}
	// 单独检查JSON树，避免encoding/json把null静默转为数值零或空字符串。
	check := json.NewDecoder(bytes.NewReader(raw))
	if err := checkNutritionValue(check, 0); err != nil {
		return invalid
	}
	if _, err := check.Token(); err != io.EOF {
		return invalid
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return invalid
	}
	for _, key := range required {
		if _, ok := fields[key]; !ok {
			return invalid
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(dst) != nil {
		return invalid
	}
	if decoder.Decode(new(any)) != io.EOF {
		return invalid
	}
	return nil
}

// checkNutritionValue 检查JSON树；参数：decoder 为当前位置解码器，depth 为嵌套深度且最多8层；返回值：错误或nil；拒绝null和重复键，不保存数据。
func checkNutritionValue(decoder *json.Decoder, depth int) error {
	if depth > 8 {
		return errors.New("JSON嵌套过深")
	}
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	if token == nil {
		return errors.New("字段不能为null")
	}
	delim, composite := token.(json.Delim)
	if !composite {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			if !ok || seen[name] {
				return errors.New("JSON字段重复")
			}
			seen[name] = true
			if err = checkNutritionValue(decoder, depth+1); err != nil {
				return err
			}
		}
	case '[':
		for decoder.More() {
			if err := checkNutritionValue(decoder, depth+1); err != nil {
				return err
			}
		}
	default:
		return errors.New("JSON结构无效")
	}
	_, err = decoder.Token()
	return err
}
