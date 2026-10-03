// 文件职责：定义记账领域模型与协议契约。

package model

// SyncReceipt 持久保存每个用户的操作结果，客户端丢失响应后仍可安全重试。
type SyncReceipt struct {
	OwnerID     uint64 `gorm:"primaryKey;autoIncrement:false"`
	OperationID string `gorm:"primaryKey;size:96"`
	Fingerprint string `gorm:"size:64;not null"`
	Result      string `gorm:"type:longtext;not null"`
}

// TableName 返回同步回执表；参数：无；返回值：独立表名，无副作用。
func (SyncReceipt) TableName() string { return "finance_sync_receipts" }
