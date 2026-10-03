// 文件职责：提供非敏感的启动配置默认值。

package config

// Defaults 提供非敏感启动默认值，凭证仍必须由配置文件提供。
// 参数：无；返回值：独立配置值；无副作用。
func Defaults() Config {
	return Config{
		ListenAddr:     ":16101",
		RunMode:        "release",
		DataBaseDriver: "mysql",
		MysqlConnection: MySQLConnection{
			Host:      "127.0.0.1",
			Port:      3306,
			Charset:   "utf8mb4",
			ParseTime: "true",
			Local:     "Local"},
		Auth: AuthConfig{JWTExpireHours: 24},
		ZapLog: LogConfig{
			LogLevel:   "info",
			MaxSize:    100,
			MaxBackups: 5,
			MaxAge:     30,
			IsCompress: true}}
}
