// 文件职责：在同一个只读一致事务中导出本人完整数据，任意失败均丢弃整个快照。
package backup

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"time"

	"gorm.io/gorm"

	aiconfigmodel "personal_assistant_server/internal/aiconfig/model"
	financemodel "personal_assistant_server/internal/finance/model"
	healthmodel "personal_assistant_server/internal/health/model"
	taskmodel "personal_assistant_server/internal/task/model"
	usermodel "personal_assistant_server/internal/user/model"
)

// Service 只持有共享数据库，不调用可能执行初始化、补默认值或过滤历史数据的业务列表服务。
type Service struct{ db *gorm.DB }

// NewService 创建备份服务；参数：db 为非 nil 的已初始化共享数据库；返回值：仅执行读取的服务，无数据库副作用。
func NewService(db *gorm.DB) *Service { return &Service{db: db} }

// Export 导出同一时间视图内的全部本人业务数据；参数：ctx 为请求上下文，取消后中止查询；ownerID 为认证身份且必须大于零。
// 返回值：完整且集合非 nil 的快照，以及事务、查询或身份错误；失败时快照始终为 nil。无写入，不分页、不截断，不导出凭证和同步回执。
func (s *Service) Export(ctx context.Context, ownerID uint64) (*Snapshot, error) {
	if ownerID == 0 {
		return nil, errors.New("备份需要有效的本人身份")
	}
	if s == nil || s.db == nil {
		return nil, errors.New("备份数据库不可用")
	}
	snapshot := &Snapshot{Format: Format, SchemaVersion: SchemaVersion}
	// 显式指定可重复读与只读：MySQL 默认隔离级别即使被调整，也不能让跨表查询落入不同版本。
	// 首次身份查询建立一致读取视图；后续所有查询使用同一个 tx，提交失败也不得返回半份结果。
	// 事务回调参数：tx 为当前只读事务；返回值：任意读取错误以回滚并丢弃快照；不得调用共享 s.db 查询。
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&usermodel.User{}).Select("id", "account", "nickname").Where("id = ?", ownerID).Take(&snapshot.Source.Owner).Error; err != nil {
			return fmt.Errorf("读取备份来源: %w", err)
		}
		snapshot.ExportedAt = time.Now().UTC()
		// 每项查询独立按归属筛选，避免通过关联或全局默认分类误导出他人记录；主键排序确保输出稳定。
		queries := []struct {
			model       any
			ownerColumn string
			destination any
			order       string
		}{
			{&taskmodel.List{}, "owner_id", &snapshot.Task.Lists, "id"},
			{&taskmodel.Task{}, "owner_id", &snapshot.Task.Tasks, "id"},
			{&taskmodel.Event{}, "owner_id", &snapshot.Task.Events, "id"},
			{&financemodel.Account{}, "owner_id", &snapshot.Finance.Accounts, "id"},
			{&financemodel.Category{}, "owner_id", &snapshot.Finance.Categories, "id"},
			{&financemodel.Transaction{}, "owner_id", &snapshot.Finance.Transactions, "id"},
			{&financemodel.Preset{}, "owner_id", &snapshot.Finance.Presets, "id"},
			{&financemodel.Event{}, "owner_id", &snapshot.Finance.Events, "id"},
			{&financemodel.Snapshot{}, "owner_id", &snapshot.Finance.Snapshots, "id"},
			{&healthmodel.Day{}, "user_id", &snapshot.Health.Days, "id"},
			{&healthmodel.Report{}, "user_id", &snapshot.Health.Reports, "id"},
			{&healthmodel.Meal{}, "user_id", &snapshot.Health.Meals, "id"},
			{&healthmodel.NutritionGoal{}, "user_id", &snapshot.Health.NutritionGoals, "user_id"},
			// 配置归属与创建者独立：共享或系统配置仅在本人创建时导出，禁止按可见范围导出他人配置。
			{&aiconfigmodel.AIProviderConfig{}, "created_by", &snapshot.ModelConfigs, "id"},
		}
		for _, query := range queries {
			// Model 决定持久化表；不同于模型的显式 DTO 使 GORM 仅选择其对应列，避免读取秘密列或派生展示值。
			if err := tx.Model(query.model).Where(query.ownerColumn+" = ?", ownerID).Order(query.order).Find(query.destination).Error; err != nil {
				return fmt.Errorf("读取备份集合 %T: %w", query.model, err)
			}
		}
		return nil
	}, &sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	// 连接地址只保留可迁移的端点，避免 URL 用户信息或查询参数绕过 APIKey 白名单泄露凭证。
	for index := range snapshot.ModelConfigs {
		snapshot.ModelConfigs[index].BaseURL = credentialFreeBaseURL(snapshot.ModelConfigs[index].BaseURL)
	}
	return snapshot, nil
}

// credentialFreeBaseURL 移除端点地址中的认证信息；参数：raw 为原始 HTTP(S) 模型端点；返回值：仅保留协议、主机与路径的 URL，无效地址返回空字符串，无副作用。
// 用户信息、全部查询参数与片段均不属于可安全迁移的端点元数据，避免依赖有限的敏感参数名称黑名单。
func credentialFreeBaseURL(raw string) string {
	endpoint, err := url.Parse(raw)
	if err != nil || (endpoint.Scheme != "https" && endpoint.Scheme != "http") || endpoint.Host == "" {
		return ""
	}
	endpoint.User = nil
	endpoint.RawQuery = ""
	endpoint.ForceQuery = false
	endpoint.Fragment = ""
	endpoint.RawFragment = ""
	return endpoint.String()
}
