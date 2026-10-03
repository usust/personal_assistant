// 文件职责：构建 MySQL 连接配置并创建 GORM 数据库资源，隔离数据库连接细节。

package database

import (
	"fmt"
	"net"
	"strconv"
	"time"

	mysqlDriver "github.com/go-sql-driver/mysql"
	gormMySQL "gorm.io/driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// ConnectMySQL 使用组件参数建立 MySQL 连接，返回仅记录错误日志的可复用 GORM 实例。
// 参数：cfg 为 MySQL 连接参数；返回值：数据库及连接错误；成功连接由应用关闭，错误中不输出 DSN。
func ConnectMySQL(cfg MySQLOptions) (*gorm.DB, error) {
	// 将数据库配置转换为连接参数。
	dsn, err := mysqlDSN(cfg)
	if err != nil {
		return nil, err
	}
	// 仅保留数据库错误日志，关闭慢 SQL 警告和普通 SQL 日志。
	return gorm.Open(gormMySQL.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Error),
	})
}

// mysqlDSN 根据配置构造连接字符串；未配置时间选项时沿用原来的默认值。
// 参数：cfg 为连接配置；返回值：含敏感凭证的 DSN 及参数解析错误；调用方不得记录 DSN。
func mysqlDSN(cfg MySQLOptions) (string, error) {
	parseTime := true
	if cfg.ParseTime != "" {
		var err error
		// 将输入字段解析为布尔值。
		parseTime, err = strconv.ParseBool(cfg.ParseTime)
		if err != nil {
			// 为失败补充当前操作的错误上下文。
			return "", fmt.Errorf("MySQL parse_time 配置无效: %w", err)
		}
	}
	loc := time.Local
	if cfg.Local != "" {
		var err error
		// 加载业务所需的时区。
		loc, err = time.LoadLocation(cfg.Local)
		if err != nil {
			// 为失败补充当前操作的错误上下文。
			return "", fmt.Errorf("MySQL loc 配置无效: %w", err)
		}
	}
	dsnConfig := mysqlDriver.Config{
		User:   cfg.Username,
		Passwd: cfg.Password,
		Net:    "tcp",
		// 构造完整的数据库访问地址。
		Addr:      net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port)),
		DBName:    cfg.Database,
		Params:    map[string]string{"charset": cfg.Charset},
		ParseTime: parseTime,
		Loc:       loc,
		// 兼容仍使用 mysql_native_password 插件的现有数据库账户。
		AllowNativePasswords: true,
	}
	// 生成驱动使用的数据库连接串。
	return dsnConfig.FormatDSN(), nil
}
