// 文件职责：定义应用配置结构，作为文件加载、校验及资源组装之间的配置契约。

// Package config 定义应用配置及其文件加载规则，不创建日志或数据库。
package config

import (
	"fmt"
	"net"
	"strings"
)

// Config 定义应用启动和运行所需的全部配置。
type Config struct {
	DefaultUser     DefaultUserConfig `mapstructure:"default_user"` // 空用户表时创建的管理员
	ListenAddr      string            `mapstructure:"listen_addr"`  // HTTP 服务监听地址和端口
	RunMode         string            `mapstructure:"run_mode"`     // 运行模式：debug、release 或 test
	Auth            AuthConfig        `mapstructure:"auth"`
	ZapLog          LogConfig         `mapstructure:"zap_log"`          // 日志文件配置
	DataBaseDriver  string            `mapstructure:"database_driver"`  // 数据库驱动名称
	MysqlConnection MySQLConnection   `mapstructure:"mysql_connection"` // 定义单个 MySQL 数据库的连接参数
}

// AuthConfig 定义身份认证及跨域访问配置。
// JWTSecret 指定 JWT 签名密钥，JWTExpireHours 指定 JWT 有效期，单位为小时，
// AllowedOrigins 指定允许的跨域来源。
type AuthConfig struct {
	JWTSecret      string   `mapstructure:"jwt_secret"`
	JWTExpireHours int      `mapstructure:"jwt_expireHours"`
	AllowedOrigins []string `mapstructure:"allowed_origins"`
	// PrintDevToken 仅在 debug 模式下启动时输出默认账号的登录 token，默认关闭。
	PrintDevToken bool `mapstructure:"print_dev_token"`
}

// MySQLConnection 定义单个 MySQL 数据库的连接参数。
// Host 和 Port 指定 MySQL 服务器地址和服务端口，Username 和 Password 用于登录认证，
// Database 指定数据库名称，Charset 指定连接字符集。
// ParseTime 控制是否将 MySQL 日期和时间字段解析为 Go 的 time.Time 类型，
// Local 指定解析时间时使用的时区，值为 Local 时使用程序运行环境的本地时区。
type MySQLConnection struct {
	Host      string `mapstructure:"host"`
	Port      int    `mapstructure:"port"`
	Username  string `mapstructure:"username"`
	Password  string `mapstructure:"password"`
	Database  string `mapstructure:"database"`
	Charset   string `mapstructure:"charset"`
	ParseTime string `mapstructure:"parse_time"`
	Local     string `mapstructure:"loc"`
}

// DefaultUserConfig 仅用于用户表为空时初始化管理员，密码存库前使用 bcrypt 哈希。
type DefaultUserConfig struct {
	Account  string `mapstructure:"account"`
	Password string `mapstructure:"password"`
	Nickname string `mapstructure:"nickname"`
}

// LogConfig 定义日志配置，包括输出目录、日志级别、文件轮转及压缩设置。
//
// 字段说明：
//   - Output：输出目标 console、file；未填写或空列表时关闭日志。
//   - LogDir：日志文件的存放目录，仅选择 file 时必填。
//   - LogLevel：最低日志输出级别，如 debug、info、warn、error。
//   - MaxSize：单个日志文件的最大大小，单位为 MB，超过后进行轮转。
//   - MaxBackups：最多保留的旧日志文件数量。
//   - MaxAge：旧日志文件的最长保留时间，单位为天。
//   - IsCompress：是否压缩轮转后的旧日志文件。
type LogConfig struct {
	Output     []string `mapstructure:"output"`
	LogDir     string   `mapstructure:"log_dir"`
	LogLevel   string   `mapstructure:"log_level"`
	MaxSize    int      `mapstructure:"max_size"`
	MaxBackups int      `mapstructure:"max_backups"`
	MaxAge     int      `mapstructure:"max_age"`
	IsCompress bool     `mapstructure:"is_compress"`
}

// Validate 在资源创建前校验必要启动条件，默认账号的业务格式由空库初始化校验。
// 接收者：c 为已加载配置；参数：无；返回值：首个配置错误或 nil；不修改配置、不连接数据库。
func (c Config) Validate() error {
	// 校验 HTTP 监听地址的主机和端口格式。
	if _, _, err := net.SplitHostPort(c.ListenAddr); err != nil {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("listen_addr 无效: %w", err)
	}
	if c.RunMode != "debug" && c.RunMode != "release" && c.RunMode != "test" {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("run_mode 必须为 debug、release 或 test")
	}
	// 统一比较口径，避免大小写影响匹配。
	if strings.ToLower(strings.TrimSpace(c.DataBaseDriver)) != "mysql" {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("database_driver 仅支持 mysql")
	}
	if c.Auth.JWTSecret == "" || c.Auth.JWTExpireHours <= 0 || c.Auth.JWTExpireHours > 2562047 {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("JWT 密钥不能为空，有效期必须是可表示的正小时数")
	}
	return nil
}
