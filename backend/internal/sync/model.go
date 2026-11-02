// Package sync 保存账号级同步元数据；不执行业务实体写入，也不负责鉴权。
package sync

import (
	"encoding/json"

	"gorm.io/gorm"
	"gorm.io/gorm/schema"
)

// ServerID 是不透明字符串标识；独立类型仅用于跨数据库存储类型适配，不解析或转换标识内容。
type ServerID string

// GormDataType 返回 GORM 逻辑类型；参数：无；返回：字符串类型；事务前置条件：无。
func (ServerID) GormDataType() string { return "string" }

// GormDBDataType 选择无数值转换的数据库类型；db 为迁移连接，field 为字段描述（未使用）；返回：MySQL 二进制字符串或 SQLite 文本类型；事务前置条件：无。
// SQLite 的 varbinary 类型具有 NUMERIC 亲和性，会破坏大整数文本；测试库必须使用 TEXT 保留逐字节标识。
func (ServerID) GormDBDataType(db *gorm.DB, field *schema.Field) string {
	if db.Dialector.Name() == "sqlite" {
		return "text"
	}
	return "varbinary(128)"
}

// AccountWatermark 是账号提交水位；同一账号的写入必须先锁定此行。
type AccountWatermark struct {
	OwnerID  uint64 `gorm:"primaryKey;autoIncrement:false"`
	Sequence uint64 `gorm:"not null"`
}

// Entity 保存永久身份映射；删除后仍保留映射及最后 revision，不复用 UUID。
type Entity struct {
	OwnerID   uint64   `gorm:"primaryKey;autoIncrement:false;uniqueIndex:ux_sync_server,priority:1"`
	Module    string   `gorm:"type:varbinary(64);primaryKey;uniqueIndex:ux_sync_server,priority:2"`
	UUID      string   `gorm:"type:varbinary(36);primaryKey"`
	ServerID  ServerID `gorm:"not null;uniqueIndex:ux_sync_server,priority:3"`
	Revision  uint64   `gorm:"not null"`
	Tombstone bool     `gorm:"not null"`
}

// Batch 是一次完整业务事务的同步批；Sequence 仅在 OwnerID 内有序。
type Batch struct {
	OwnerID     uint64 `gorm:"primaryKey;autoIncrement:false"`
	Sequence    uint64 `gorm:"primaryKey;autoIncrement:false"`
	ChangeCount int    `gorm:"not null"`
}

// Change 是调用方白名单投影的历史快照，不可用于通用业务覆盖写入。
type Change struct {
	OwnerID   uint64          `gorm:"primaryKey;autoIncrement:false"`
	Sequence  uint64          `gorm:"primaryKey;autoIncrement:false"`
	Position  int             `gorm:"primaryKey;autoIncrement:false"`
	Module    string          `gorm:"type:varbinary(64);not null"`
	UUID      string          `gorm:"type:varbinary(36);not null"`
	ServerID  ServerID        `gorm:"not null"`
	Revision  uint64          `gorm:"not null"`
	Tombstone bool            `gorm:"not null"`
	Payload   json.RawMessage `gorm:"type:json;not null"`
}

// Receipt 是 owner + operationId 的成功回执，Fingerprint 为调用方规范化命令的 SHA-256 小写十六进制值。
type Receipt struct {
	OwnerID     uint64 `gorm:"primaryKey;autoIncrement:false"`
	OperationID string `gorm:"type:varbinary(128);primaryKey"`
	Fingerprint string `gorm:"type:varbinary(64);not null"`
	Sequence    uint64 `gorm:"not null"`
}

// Mutation 仅描述已授权的业务变更及其白名单投影；新建 BaseRevision=0，删除 Payload 必须为空或 null。
type Mutation struct {
	Module string
	UUID   string
	// ServerID 为领域适配层规范化的不透明标识（1..128 字节，无控制字符）；数字 ID 由适配层十进制格式化，仓库不猜测类型。
	ServerID     string
	BaseRevision uint64
	Tombstone    bool
	Payload      json.RawMessage
}

// CommitBatch 是完整批及其有序变更。
type CommitBatch struct {
	Batch   Batch
	Changes []Change
}

// PullPage 的 Next 是最后返回的完整批游标；Watermark 是本次查询的上界，HasMore 表示仍有后续批。
type PullPage struct {
	Batches   []CommitBatch
	Next      uint64
	Watermark uint64
	HasMore   bool
}

// TableName 返回独立同步表名；参数：无；返回：表名；事务前置条件：无。
func (AccountWatermark) TableName() string { return "sync_account_watermarks" }

// TableName 返回独立同步表名；参数：无；返回：表名；事务前置条件：无。
func (Entity) TableName() string { return "sync_entities" }

// TableName 返回独立同步表名；参数：无；返回：表名；事务前置条件：无。
func (Batch) TableName() string { return "sync_batches" }

// TableName 返回独立同步表名；参数：无；返回：表名；事务前置条件：无。
func (Change) TableName() string { return "sync_changes" }

// TableName 返回独立同步表名；参数：无；返回：表名；事务前置条件：无。
func (Receipt) TableName() string { return "sync_receipts" }
