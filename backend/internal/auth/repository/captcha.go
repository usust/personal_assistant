// 文件职责：保存验证码摘要与期限，保证一次性消费的并发原子性。

package repository

import (
	"crypto/sha256"
	"sync"
	"time"
)

type captchaEntry struct {
	hash      [sha256.Size]byte
	expiresAt time.Time
}

// CaptchaStore 持有单实例内存记录，所有访问均由互斥锁保护。
type CaptchaStore struct {
	mu      sync.Mutex
	entries map[string]captchaEntry
}

// NewCaptchaStore 创建验证码仓储。
// 参数：无；返回值：已初始化仓储；无外部副作用。
func NewCaptchaStore() *CaptchaStore { return &CaptchaStore{entries: make(map[string]captchaEntry)} }

// Save 保存摘要与期限，并清理已过期记录。
// 接收者：s 为已初始化仓储；参数：id 为非空标识，hash 为答案摘要，expiresAt 为期限，now 为清理时间基准。
// 返回值：无；修改内存记录，可并发调用，不保存答案明文。
func (s *CaptchaStore) Save(id string, hash [sha256.Size]byte, expiresAt, now time.Time) {
	// 将记录访问限制在临界区内，保证并发安全。
	s.mu.Lock()
	// 所有返回路径都释放锁，避免后续挑战操作被阻塞。
	defer s.mu.Unlock()
	// 保存与清理在同一临界区内完成，避免并发读写 map。
	for key, entry := range s.entries {
		// 保存新挑战时淘汰到期记录，控制内存中无效状态的积累。
		if !entry.expiresAt.After(now) {
			delete(s.entries, key)
		}
	}
	s.entries[id] = captchaEntry{hash: hash, expiresAt: expiresAt}
}

// Consume 原子读取并删除记录，业务校验由服务层执行。
// 接收者：s 为已初始化仓储；参数：id 为验证码标识；返回值：摘要、期限与是否找到，未找到时为零值。
// 副作用：找到即删除，保证并发请求最多一个取得记录。
func (s *CaptchaStore) Consume(id string) ([sha256.Size]byte, time.Time, bool) {
	// 将记录访问限制在临界区内，保证并发安全。
	s.mu.Lock()
	// 所有返回路径都释放锁，避免后续挑战操作被阻塞。
	defer s.mu.Unlock()
	entry, exists := s.entries[id]
	delete(s.entries, id)
	return entry.hash, entry.expiresAt, exists
}
