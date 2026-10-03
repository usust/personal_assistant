// 文件职责：用户数据库错误转换与仓储公共定义。

package repository

import (
	"errors"
	"github.com/go-sql-driver/mysql"
	"gorm.io/gorm"
)

// normalizeError 将驱动差异转换为仓储层统一错误。
// 参数：err 为数据库错误，可为 nil；返回值：唯一键错误或原始错误，nil 保持不变。
func normalizeError(err error) error {
	var mysqlErr *mysql.MySQLError
	// 区分预期错误与需要继续上报的异常。
	if errors.Is(err, gorm.ErrDuplicatedKey) || (errors.As(err, &mysqlErr) && mysqlErr.Number == 1062) {
		return gorm.ErrDuplicatedKey
	}
	return err
}
