// 文件职责：集中声明应用负责的业务表，并在启动阶段执行数据库结构迁移。

package app

import (
	"context"
	"fmt"

	aiconfigmodel "personal_assistant_server/internal/aiconfig/model"
	financemodel "personal_assistant_server/internal/finance/model"
	healthmodel "personal_assistant_server/internal/health/model"
	taskmodel "personal_assistant_server/internal/task/model"
	"personal_assistant_server/internal/user/model"
)

// migrate 集中声明当前应用拥有的表，已删除的个人设置表不再迁移，也不删除历史数据。
// 接收者：a 为已组装应用；参数：ctx 控制数据库操作；返回值：迁移错误，成功为 nil；可能创建表或补充字段。
func (a *App) migrate(ctx context.Context) error {
	// 将应用负责的表迁移到当前模型结构。
	if err := a.db.WithContext(ctx).AutoMigrate(
		// 健康日汇总表：保存每位用户按自然日汇总的步数、活动能量、心率和体重等健康指标。
		&healthmodel.Day{},
		// 健康报告表：保存用户的健康分析报告、生成时的数据快照及所用模型配置。
		&healthmodel.Report{},
		// 用户表：保存账号、密码哈希、昵称和角色，支持登录认证与业务授权。
		&model.User{},
		// 模型配置表：保存模型提供商、连接地址、模型名称、密钥及配置归属和使用范围。
		&aiconfigmodel.AIProviderConfig{},
		// 任务清单表：保存用户的任务分组和清单信息。
		&taskmodel.List{},
		// 任务表：保存任务内容、层级关系、进度和排序等信息。
		&taskmodel.Task{},
		// 任务事件表：记录任务与清单的业务变更及操作来源，用于追踪操作历史。
		&taskmodel.Event{},
		// 记账账户表：保存账户余额、币种、信用额度及账单和贷款相关配置。
		&financemodel.Account{},
		// 记账分类表：保存用户的收支分类及分类层级。
		&financemodel.Category{},
		// 交易流水表：保存收支、转账等记账记录及其账户、分类和处理状态。
		&financemodel.Transaction{},
		// 记账事件表：记录记账业务变更及操作来源，用于审计追踪。
		&financemodel.Event{},
		// 账户快照表：保存账户余额变更后的状态，用于追溯余额变化。
		&financemodel.Snapshot{},
		// 记账预设表：保存可复用的交易模板及周期记账计划。
		&financemodel.Preset{},
		// 同步回执表：保存同步操作标识、请求指纹和执行结果，防止重试造成重复写入。
		&financemodel.SyncReceipt{},
	); err != nil {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("迁移业务表失败: %w", err)
	}
	return nil
}
