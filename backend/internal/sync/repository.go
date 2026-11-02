package sync

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"unicode"
	"unicode/utf8"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

var (
	ErrTransactionRequired = errors.New("sync: caller transaction required")
	ErrInvalidArgument     = errors.New("sync: invalid argument")
	ErrIdentityConflict    = errors.New("sync: immutable identity conflict")
	ErrCorruptBatch        = errors.New("sync: incomplete batch")
	modulePattern          = regexp.MustCompile(`^[a-z][a-z0-9_.-]{0,63}$`)
	uuidPattern            = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	fingerprintPattern     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	operationPattern       = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
)

// RevisionConflict 可由 errors.As 识别；Actual=0 表示实体尚不存在。
type RevisionConflict struct {
	Module, UUID     string
	Expected, Actual uint64
}

// Error 格式化 revision 冲突；参数：无；返回：错误文本；事务前置条件：无。
func (e *RevisionConflict) Error() string {
	return fmt.Sprintf("sync: revision conflict %s/%s: expected %d, actual %d", e.Module, e.UUID, e.Expected, e.Actual)
}

// OperationConflict 表示相同 operationId 被不同命令重用，不得再次执行业务写入。
type OperationConflict struct{ OperationID string }

// Error 格式化幂等冲突；参数：无；返回：错误文本；事务前置条件：无。
func (e *OperationConflict) Error() string {
	return "sync: operation fingerprint conflict: " + e.OperationID
}

// Repository 无连接状态。所有 API 仅使用调用方事务，不自行开启或提交事务。
// 调用方必须验证 owner 权限，错误时回滚整个事务，并在首次业务写入前调用 LookupReceipt。
// 同一业务事务只记录一次完整 RecordBatch；多账号事务须按 owner 升序取锁以降低死锁概率。
// 迁移由集成方对五个模型执行；生产表必须使用支持事务和行锁的 MySQL InnoDB。
type Repository struct{}

// requireTx 校验事务和账号；tx 必须是已开启且未结束的 GORM 事务，owner 必须非零；返回：参数错误或 nil。
// 不提交、不回滚；事务是否已结束仍由数据库执行时判断。
func requireTx(tx *gorm.DB, owner uint64) error {
	if tx == nil || tx.Statement == nil {
		return ErrTransactionRequired
	}
	if _, ok := tx.Statement.ConnPool.(gorm.TxCommitter); !ok {
		return ErrTransactionRequired
	}
	if tx.Error != nil {
		return tx.Error
	}
	if owner == 0 {
		return ErrInvalidArgument
	}
	return nil
}

// lockOwner 创建并锁定账号水位；tx 为调用方活动事务，owner 非零；返回：当前水位或数据库错误。
// 必须在业务写入前调用；锁持有至调用方提交/回滚，MySQL 首次建行的唯一键冲突也会串行化。
func lockOwner(tx *gorm.DB, owner uint64) (AccountWatermark, error) {
	w := AccountWatermark{OwnerID: owner}
	if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&w).Error; err != nil {
		return w, err
	}
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("owner_id = ?", owner).Take(&w).Error
	return w, err
}

// LookupReceipt 在业务写入前取得账号锁并查幂等回执；tx 为调用方活动事务，owner 为已授权账号，operationID 为 1..128 位 ASCII 标识，fingerprint 为规范化完整命令的 SHA-256 小写十六进制值。
// 返回：已有成功回执（调用方必须跳过业务写入）、nil（首次操作）或类型化 OperationConflict/数据库错误；出错必须回滚。
// 锁持续到调用方事务结束；必须使用当前读取，避免 MySQL REPEATABLE READ 的旧快照漏掉并发已提交回执。
func (Repository) LookupReceipt(tx *gorm.DB, owner uint64, operationID, fingerprint string) (*Receipt, error) {
	if err := requireTx(tx, owner); err != nil {
		return nil, err
	}
	if !operationPattern.MatchString(operationID) || !fingerprintPattern.MatchString(fingerprint) {
		return nil, ErrInvalidArgument
	}
	if _, err := lockOwner(tx, owner); err != nil {
		return nil, err
	}
	var receipt Receipt
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("owner_id = ? AND operation_id = ?", owner, operationID).Take(&receipt).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if receipt.Fingerprint != fingerprint {
		return nil, &OperationConflict{OperationID: operationID}
	}
	return &receipt, nil
}

// Resolve 查询账号内模块 UUID 映射；tx 为调用方活动事务，owner 已授权，module/uuid 必须规范化；返回：实体或 gorm.ErrRecordNotFound/参数/数据库错误。
// 写入流程须先 LookupReceipt 取账号锁；此处使用当前读取避免旧快照，绝不跨 owner 查询。
func (Repository) Resolve(tx *gorm.DB, owner uint64, module, uuid string) (Entity, error) {
	var entity Entity
	if err := requireTx(tx, owner); err != nil {
		return entity, err
	}
	if !modulePattern.MatchString(module) || !uuidPattern.MatchString(uuid) {
		return entity, ErrInvalidArgument
	}
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("owner_id = ? AND module = ? AND uuid = ?", owner, module, uuid).Take(&entity).Error
	return entity, err
}

// validServerID 校验领域适配层提供的不透明标识；id 必须为 1..128 字节有效 UTF-8 且无控制字符；返回：是否有效。
// 事务前置条件：无；不裁剪、不转换大小写、不猜测数字或 UUID，规范化由领域适配层负责。
func validServerID(id string) bool {
	if len(id) == 0 || len(id) > 128 || !utf8.ValidString(id) {
		return false
	}
	for _, r := range id {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// RecordBatch 记录调用方同事务业务写入的完整变更集；tx 为活动事务，owner 已授权，operationID/fingerprint 同 LookupReceipt，mutations 非空且每个实体只出现一次。
// Payload 必须由调用方白名单投影，禁止传原始请求/密钥；本方法仅存同步快照，绝不写业务表。
// 返回：成功回执、是否重放、错误（含 RevisionConflict/OperationConflict）；任意错误必须回滚整个业务事务。
// 调用方须先 LookupReceipt 并跳过已完成操作；本方法再次检查幂等，但不能撤销调用方误做的重复业务副作用。
func (r Repository) RecordBatch(tx *gorm.DB, owner uint64, operationID, fingerprint string, mutations []Mutation) (Receipt, bool, error) {
	prior, err := r.LookupReceipt(tx, owner, operationID, fingerprint)
	if err != nil {
		return Receipt{}, false, err
	}
	if prior != nil {
		return *prior, true, nil
	}
	if len(mutations) == 0 {
		return Receipt{}, false, ErrInvalidArgument
	}
	entities := make([]Entity, len(mutations))
	seen := make(map[string]bool, len(mutations))
	serverIDs := make(map[string]map[string]bool)
	// 先校验整个批的版本与身份，再写元数据；冲突不能静默覆盖，也不能复活已删除 UUID。
	for i, m := range mutations {
		key := m.Module + "/" + m.UUID
		if !modulePattern.MatchString(m.Module) || !uuidPattern.MatchString(m.UUID) || !validServerID(m.ServerID) || seen[key] || (!m.Tombstone && !json.Valid(m.Payload)) || (m.Tombstone && len(m.Payload) > 0 && string(m.Payload) != "null") {
			return Receipt{}, false, ErrInvalidArgument
		}
		seen[key] = true
		entity, err := r.Resolve(tx, owner, m.Module, m.UUID)
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return Receipt{}, false, err
		}
		if entity.Revision != m.BaseRevision {
			return Receipt{}, false, &RevisionConflict{Module: m.Module, UUID: m.UUID, Expected: m.BaseRevision, Actual: entity.Revision}
		}
		if entity.Tombstone || (entity.Revision != 0 && string(entity.ServerID) != m.ServerID) || (entity.Revision == 0 && m.Tombstone) {
			return Receipt{}, false, ErrIdentityConflict
		}
		if entity.Revision == math.MaxUint64 {
			return Receipt{}, false, ErrInvalidArgument
		}
		// 当前读取身份映射，避免 REPEATABLE READ 旧快照漏掉等待账号锁期间提交的映射。
		var mapped Entity
		err = tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("owner_id = ? AND module = ? AND server_id = ?", owner, m.Module, m.ServerID).Take(&mapped).Error
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return Receipt{}, false, err
		}
		if err == nil && mapped.UUID != m.UUID {
			return Receipt{}, false, ErrIdentityConflict
		}
		if serverIDs[m.Module] == nil {
			serverIDs[m.Module] = make(map[string]bool)
		}
		if serverIDs[m.Module][m.ServerID] {
			return Receipt{}, false, ErrIdentityConflict
		}
		serverIDs[m.Module][m.ServerID] = true
		entities[i] = Entity{OwnerID: owner, Module: m.Module, UUID: m.UUID, ServerID: ServerID(m.ServerID), Revision: m.BaseRevision + 1, Tombstone: m.Tombstone}
	}
	w, err := lockOwner(tx, owner)
	if err != nil {
		return Receipt{}, false, err
	}
	if w.Sequence == math.MaxUint64 {
		return Receipt{}, false, ErrInvalidArgument
	}
	sequence := w.Sequence + 1
	for i, entity := range entities {
		if mutations[i].BaseRevision == 0 {
			err = tx.Create(&entity).Error
		} else {
			err = tx.Model(&Entity{}).Where("owner_id = ? AND module = ? AND uuid = ?", owner, entity.Module, entity.UUID).Updates(map[string]any{"revision": entity.Revision, "tombstone": entity.Tombstone}).Error
		}
		if err != nil {
			return Receipt{}, false, err
		}
		payload := mutations[i].Payload
		if entity.Tombstone {
			payload = json.RawMessage("null")
		}
		change := Change{OwnerID: owner, Sequence: sequence, Position: i, Module: entity.Module, UUID: entity.UUID, ServerID: entity.ServerID, Revision: entity.Revision, Tombstone: entity.Tombstone, Payload: payload}
		if err = tx.Create(&change).Error; err != nil {
			return Receipt{}, false, err
		}
	}
	batch := Batch{OwnerID: owner, Sequence: sequence, ChangeCount: len(mutations)}
	if err = tx.Create(&batch).Error; err != nil {
		return Receipt{}, false, err
	}
	if err = tx.Model(&AccountWatermark{}).Where("owner_id = ?", owner).Updates(map[string]any{"sequence": sequence}).Error; err != nil {
		return Receipt{}, false, err
	}
	receipt := Receipt{OwnerID: owner, OperationID: operationID, Fingerprint: fingerprint, Sequence: sequence}
	if err = tx.Create(&receipt).Error; err != nil {
		return Receipt{}, false, err
	}
	return receipt, false, nil
}

// Pull 拉取完整事务批；tx 为调用方活动只读或读写事务，owner 已授权，after 为上次完整批游标，maxBatches 为 1..100 的批数而非变更数。
// 返回：完整批页或错误；不按模块过滤，不截断大批；Next 仅越过完整返回的批，空页保持 after。
// 查询以已读取水位为上界；调用方不得在同一事务夹入同步写入，不支持历史裁剪，未来裁剪须另加过期游标协议。
func (Repository) Pull(tx *gorm.DB, owner, after uint64, maxBatches int) (PullPage, error) {
	page := PullPage{Next: after, Batches: []CommitBatch{}}
	if err := requireTx(tx, owner); err != nil {
		return page, err
	}
	if maxBatches < 1 || maxBatches > 100 {
		return page, ErrInvalidArgument
	}
	var w AccountWatermark
	err := tx.Where("owner_id = ?", owner).Take(&w).Error
	if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return page, err
	}
	page.Watermark = w.Sequence
	if after > w.Sequence {
		return page, ErrInvalidArgument
	}
	var batches []Batch
	if err = tx.Where("owner_id = ? AND sequence > ? AND sequence <= ?", owner, after, w.Sequence).Order("sequence ASC").Limit(maxBatches).Find(&batches).Error; err != nil {
		return page, err
	}
	for _, batch := range batches {
		var changes []Change
		if err = tx.Where("owner_id = ? AND sequence = ?", owner, batch.Sequence).Order("position ASC").Find(&changes).Error; err != nil {
			return page, err
		}
		if len(changes) != batch.ChangeCount || batch.ChangeCount == 0 || batch.Sequence != page.Next+1 {
			return PullPage{}, ErrCorruptBatch
		}
		for i, change := range changes {
			if change.Position != i {
				return PullPage{}, ErrCorruptBatch
			}
		}
		page.Batches = append(page.Batches, CommitBatch{Batch: batch, Changes: changes})
		page.Next = batch.Sequence
	}
	// 查询未满页却尚未到水位，说明尾部也缺批；不能把残缺页当作正常 HasMore 返回。
	if len(batches) < maxBatches && page.Next < w.Sequence {
		return PullPage{}, ErrCorruptBatch
	}
	page.HasMore = page.Next < page.Watermark
	return page, nil
}
