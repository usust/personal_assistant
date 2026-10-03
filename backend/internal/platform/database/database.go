// 文件职责：按驱动选择数据库连接实现，提供统一资源创建入口。

package database

import (
	"fmt"
	"strings"

	"gorm.io/gorm"
)

// Open 按指定驱动创建 GORM 数据库资源，不执行迁移或初始化业务数据。
// 参数：options 为组件参数，Driver 去除首尾空白且不区分大小写，当前仅支持 mysql。
// 返回值：数据库实例及驱动选择或连接错误；成功后调用方负责关闭底层连接池。
func Open(options Options) (*gorm.DB, error) {
	// 仅向选中的实现传递专属参数，未启用驱动的参数不参与连接处理。
	switch strings.ToLower(strings.TrimSpace(options.Driver)) {
	case "mysql":
		return ConnectMySQL(options.MySQL)
	default:
		return nil, fmt.Errorf("不支持的数据库驱动: %q", options.Driver)
	}
}
