// 文件职责：定义数据库组件的连接参数，与应用配置文件结构保持独立。

package database

// Options 定义驱动选择及各驱动的专属参数，仅使用选中驱动对应的参数。
// 当前仅支持 mysql；新增驱动时添加对应参数分组及连接实现。
type Options struct {
	Driver string
	MySQL  MySQLOptions
}

// MySQLOptions 定义 MySQL 连接参数，不承载配置文件字段映射。
type MySQLOptions struct {
	Host      string // 数据库主机地址。
	Port      int    // 数据库 TCP 端口。
	Username  string // 数据库登录账号。
	Password  string // 数据库登录密码，不得记录到日志。
	Database  string // 数据库名称。
	Charset   string // 连接字符集。
	ParseTime string // 是否解析时间，支持 strconv.ParseBool 的值；空值使用 true。
	Local     string // 时间解析时区，空值使用进程本地时区。
}
