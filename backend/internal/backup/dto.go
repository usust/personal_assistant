// 文件职责：定义版本 1 备份的显式字段白名单，保留持久化业务数据与关联 ID，不暴露用户凭证或派生展示字段。
package backup

import (
	financemodel "personal_assistant_server/internal/finance/model"
	"time"
)

const Format = "personal-assistant-backup"
const SchemaVersion = 1

// Snapshot 是完整本人业务快照；所有集合非 nil，schemaVersion 标识独立于普通列表 API 的备份协议。
type Snapshot struct {
	Format        string        `json:"format"`
	SchemaVersion int           `json:"schemaVersion"`
	ExportedAt    time.Time     `json:"exportedAt"`
	Source        Source        `json:"source"`
	Task          TaskData      `json:"task"`
	Finance       FinanceData   `json:"finance"`
	Health        HealthData    `json:"health"`
	ModelConfigs  []ModelConfig `json:"modelConfigs"`
}

// Source 保存快照的原始账户归属，供离线备份追溯。
type Source struct {
	Owner Owner `json:"owner"`
}

// Owner 只读取并输出身份白名单；不包含密码哈希、角色或认证令牌。
type Owner struct {
	ID       uint64 `json:"id"`
	Account  string `json:"account"`
	Nickname string `json:"nickname"`
}

// TaskData 包含全部清单、任务及操作事件，保留归档和父子任务。
type TaskData struct {
	Lists  []TaskList  `json:"lists"`
	Tasks  []Task      `json:"tasks"`
	Events []TaskEvent `json:"events"`
}

// FinanceData 包含原始财务数据（含分类删除墓碑），不包含同步回执。
type FinanceData struct {
	Accounts     []FinanceAccount     `json:"accounts"`
	Categories   []FinanceCategory    `json:"categories"`
	Transactions []FinanceTransaction `json:"transactions"`
	Presets      []FinancePreset      `json:"presets"`
	Events       []FinanceEvent       `json:"events"`
	Snapshots    []FinanceSnapshot    `json:"snapshots"`
}

// HealthData 保留健康指标、报告原文、餐食及已保存的营养目标；不生成默认目标。
type HealthData struct {
	Days           []HealthDay     `json:"days"`
	Reports        []HealthReport  `json:"reports"`
	Meals          []HealthMeal    `json:"meals"`
	NutritionGoals []NutritionGoal `json:"nutritionGoals"`
}

// TaskList 显式保留 List 的持久化业务字段，空值及零值同样输出。
type TaskList struct {
	ID        uint64    `json:"id"`
	OwnerID   uint64    `json:"ownerId"`
	Name      string    `json:"name"`
	Remark    string    `json:"remark"`
	Color     string    `json:"color"`
	Icon      string    `json:"icon"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// Task 显式保留 Task 的持久化业务字段，空值及零值同样输出。
type Task struct {
	ID                uint64    `json:"id"`
	OwnerID           uint64    `json:"ownerId"`
	Icon              string    `json:"icon"`
	Title             string    `json:"title"`
	Remark            string    `json:"remark"`
	ListID            uint64    `json:"listId"`
	ParentID          *uint64   `json:"parentId"`
	TaskType          string    `json:"taskType"`
	Priority          string    `json:"priority"`
	StartDate         string    `json:"startDate"`
	StartTime         string    `json:"startTime"`
	EndDate           string    `json:"endDate"`
	EndTime           string    `json:"endTime"`
	AutoArchive       bool      `json:"autoArchive"`
	Archived          bool      `json:"archived"`
	SortOrder         int       `json:"sortOrder"`
	ProgressTotal     float64   `json:"progressTotal"`
	ProgressCompleted float64   `json:"progressCompleted"`
	ProgressStep      float64   `json:"progressStep"`
	ProgressUnit      string    `json:"progressUnit"`
	CreatedAt         time.Time `json:"createdAt"`
	UpdatedAt         time.Time `json:"updatedAt"`
}

// TaskEvent 显式保留 Event 的持久化业务字段，空值及零值同样输出。
type TaskEvent struct {
	ID        uint64    `json:"id"`
	OwnerID   uint64    `json:"ownerId"`
	Operation string    `json:"operation"`
	EntityID  uint64    `json:"entityId"`
	Source    string    `json:"source"`
	CreatedAt time.Time `json:"createdAt"`
}

// FinanceAccount 显式保留 Account 的持久化业务字段，空值及零值同样输出。
type FinanceAccount struct {
	LoanPrincipal          financemodel.Money `json:"loanPrincipal"`
	LoanAnnualRate         string             `json:"loanAnnualRate"`
	LoanMethod             string             `json:"loanMethod"`
	LoanPeriods            int                `json:"loanPeriods"`
	LoanPaidPeriods        int                `json:"loanPaidPeriods"`
	LoanFirstPaymentDate   string             `json:"loanFirstPaymentDate"`
	LoanLender             string             `json:"loanLender"`
	LoanReceivingAccountID uint64             `json:"loanReceivingAccountId"`
	LoanScheduleJSON       string             `json:"loanScheduleJSON"`
	LoanRevision           int                `json:"loanRevision"`
	ReminderDays           int                `json:"reminderDays"`
	ReminderTime           string             `json:"reminderTime"`
	CreditLimit            financemodel.Money `json:"creditLimit"`
	BillingDay             int                `json:"billingDay"`
	RepaymentDay           int                `json:"repaymentDay"`
	BillDayInclusive       bool               `json:"billDayInclusive"`
	Selectable             bool               `json:"selectable"`
	ID                     uint64             `json:"id"`
	OwnerID                uint64             `json:"ownerId"`
	Name                   string             `json:"name"`
	AccountType            string             `json:"accountType"`
	Institution            string             `json:"institution"`
	MaskedAccountNumber    string             `json:"maskedAccountNumber"`
	Cards                  []AccountCard      `json:"cards" gorm:"serializer:json"`
	Balance                financemodel.Money `json:"balance"`
	Currency               string             `json:"currency"`
	IncludeInNetWorth      bool               `json:"includeInNetWorth"`
	SortOrder              int                `json:"sortOrder"`
	Notes                  string             `json:"notes"`
	Archived               bool               `json:"archived"`
	CreatedAt              time.Time          `json:"createdAt"`
	UpdatedAt              time.Time          `json:"updatedAt"`
}

// FinanceCategory 显式保留 Category 的持久化业务字段，空值及零值同样输出。
type FinanceCategory struct {
	GroupKey    string `json:"groupKey"`
	Icon        string `json:"icon"`
	ID          uint64 `json:"id"`
	OwnerID     uint64 `json:"ownerId"`
	Name        string `json:"name"`
	Type        string `json:"type"`
	NameVersion uint64 `json:"nameVersion"`
	Color       string `json:"color"`
	IsDefault   bool   `json:"isDefault"`
	Deleted     bool   `json:"deleted"`
}

// FinanceTransaction 显式保留 Transaction 的持久化业务字段，空值及零值同样输出。
type FinanceTransaction struct {
	Discount               financemodel.Money `json:"discount"`
	RefundParentID         *uint64            `json:"refundParentId"`
	ReimbursementStatus    string             `json:"reimbursementStatus"`
	Rebate                 financemodel.Money `json:"rebate"`
	RebateAccountID        *uint64            `json:"rebateAccountId"`
	RebatePending          bool               `json:"rebatePending"`
	RebateParentID         *uint64            `json:"rebateParentId"`
	Fee                    financemodel.Money `json:"fee"`
	InstallmentJSON        string             `json:"installmentJSON"`
	InstallmentParentID    *uint64            `json:"installmentParentId"`
	InstallmentPeriod      int                `json:"installmentPeriod"`
	InstallmentEditRemoved bool               `json:"installmentEditRemoved"`
	ID                     uint64             `json:"id"`
	OwnerID                uint64             `json:"ownerId"`
	RequestID              string             `json:"requestId"`
	Fingerprint            string             `json:"fingerprint"`
	AccountID              uint64             `json:"accountId"`
	TargetAccountID        *uint64            `json:"targetAccountId"`
	Type                   string             `json:"type"`
	Amount                 financemodel.Money `json:"amount"`
	CategoryID             *uint64            `json:"categoryId"`
	Counterparty           string             `json:"counterparty"`
	TransactionTime        string             `json:"transactionTime"`
	TransactionDate        string             `json:"transactionDate"`
	Description            string             `json:"description"`
	Status                 string             `json:"status"`
	Source                 string             `json:"source"`
	CreatedAt              time.Time          `json:"createdAt"`
	UpdatedAt              time.Time          `json:"updatedAt"`
}

// FinancePreset 显式保留 Preset 的持久化业务字段，空值及零值同样输出。
type FinancePreset struct {
	ID          uint64            `json:"id"`
	OwnerID     uint64            `json:"ownerId"`
	Key         string            `json:"key"`
	Name        string            `json:"name"`
	Transaction PresetTransaction `json:"transaction" gorm:"serializer:json"`
	Frequency   string            `json:"frequency"`
	StartDate   string            `json:"startDate"`
	EndDate     string            `json:"endDate"`
	NextDate    string            `json:"nextDate"`
	Enabled     bool              `json:"enabled"`
	LastError   string            `json:"lastError"`
}

// FinanceEvent 显式保留 Event 的持久化业务字段，空值及零值同样输出。
type FinanceEvent struct {
	ID        uint64    `json:"id"`
	OwnerID   uint64    `json:"ownerId"`
	EntityID  uint64    `json:"entityId"`
	Operation string    `json:"operation"`
	Source    string    `json:"source"`
	CreatedAt time.Time `json:"createdAt"`
}

// FinanceSnapshot 显式保留 Snapshot 的持久化业务字段，空值及零值同样输出。
type FinanceSnapshot struct {
	ID        uint64             `json:"id"`
	OwnerID   uint64             `json:"ownerId"`
	AccountID uint64             `json:"accountId"`
	Balance   financemodel.Money `json:"balance"`
	CreatedAt time.Time          `json:"createdAt"`
}

// HealthDay 显式保留 Day 的持久化业务字段，空值及零值同样输出。
type HealthDay struct {
	ID               uint      `json:"id"`
	UserID           uint64    `json:"userId"`
	Date             string    `json:"date"`
	Steps            *float64  `json:"steps"`
	ActiveEnergy     *float64  `json:"active_energy"`
	Distance         *float64  `json:"distance"`
	RestingHeartRate *float64  `json:"resting_heart_rate"`
	Weight           *float64  `json:"weight"`
	Timezone         string    `json:"timezone"`
	UpdatedAt        time.Time `json:"updated_at"`
}

// HealthReport 显式保留 Report 的持久化业务字段，空值及零值同样输出。
type HealthReport struct {
	ID        uint      `json:"id"`
	UserID    uint64    `json:"userId"`
	Content   string    `json:"content"`
	Snapshot  string    `json:"snapshot"`
	ConfigID  uint      `json:"config_id"`
	CreatedAt time.Time `json:"created_at"`
}

// HealthMeal 显式保留 Meal 的持久化业务字段，空值及零值同样输出。
type HealthMeal struct {
	UserID    uint64     `json:"userId"`
	ID        string     `json:"id"`
	Date      string     `json:"date"`
	MealType  string     `json:"meal_type"`
	Items     []MealItem `json:"items" gorm:"serializer:json"`
	Note      string     `json:"note"`
	CreatedAt time.Time  `json:"created_at"`
}

// NutritionGoal 显式保留 NutritionGoal 的持久化业务字段，空值及零值同样输出。
type NutritionGoal struct {
	UserID    uint64  `json:"userId"`
	DailyGoal float64 `json:"daily_goal"`
}

// ModelConfig 只保留本人创建的模型连接元数据；显式白名单不包含 APIKey，归属与共享范围保持原样。
type ModelConfig struct {
	ID           uint      `json:"id"`
	OwnerType    string    `json:"owner_type"`
	OwnerID      *uint64   `json:"owner_id"`
	Visibility   string    `json:"visibility"`
	CreatedBy    *uint64   `json:"created_by"`
	IsSelected   bool      `json:"is_selected"`
	Name         string    `json:"name"`
	ProviderName string    `json:"provider_name"`
	BaseURL      string    `json:"base_url"`
	ModelName    string    `json:"model_name"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// PresetTransaction 使用显式业务字段白名单保留嵌套 JSON 值，不受普通 API 省略零值影响。
type PresetTransaction struct {
	ReimbursementStatus string             `json:"reimbursementStatus"`
	Discount            financemodel.Money `json:"discount"`
	Rebate              financemodel.Money `json:"rebate"`
	RebateAccountID     *uint64            `json:"rebateAccountId"`
	RebatePending       bool               `json:"rebatePending"`
	Fee                 financemodel.Money `json:"fee"`
	RequestID           string             `json:"requestId"`
	AccountID           uint64             `json:"accountId"`
	TargetAccountID     *uint64            `json:"targetAccountId"`
	TargetCreditCardID  *uint64            `json:"targetCreditCardId"`
	Type                string             `json:"type"`
	Amount              financemodel.Money `json:"amount"`
	CategoryID          *uint64            `json:"categoryId"`
	Counterparty        string             `json:"counterparty"`
	TransactionTime     string             `json:"transactionTime"`
	TransactionDate     string             `json:"transactionDate"`
	Description         string             `json:"description"`
}

// AccountCard 使用显式业务字段白名单保留嵌套 JSON 值，不受普通 API 省略零值影响。
type AccountCard struct {
	ID                  string `json:"id"`
	Name                string `json:"name"`
	MaskedAccountNumber string `json:"maskedAccountNumber"`
}

// MealItem 使用显式业务字段白名单保留嵌套 JSON 值，不受普通 API 省略零值影响。
type MealItem struct {
	Name     string  `json:"name"`
	Grams    float64 `json:"grams"`
	Calories float64 `json:"calories"`
}
