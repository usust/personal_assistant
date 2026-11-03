package database

import (
	"testing"

	mysqlDriver "github.com/go-sql-driver/mysql"
)

// TestMySQLDSNAllowsExistingAccountAuthentication 验证序列化后的连接配置兼容既有账户且不放开明文认证。
// 参数：t 为测试上下文；返回值：无；不连接真实数据库，配置不符合认证约束时测试失败。
func TestMySQLDSNAllowsExistingAccountAuthentication(t *testing.T) {
	dsn, err := mysqlDSN(MySQLOptions{
		Host: "127.0.0.1", Port: 3306, Username: "app", Password: "test-password",
		Database: "personal_assistant", Charset: "utf8mb4",
	})
	if err != nil {
		t.Fatalf("构造连接配置失败: %v", err)
	}
	// 检查实际传给驱动的 DSN，防止序列化时丢失兼容选项；失败时不打印含凭证的 DSN。
	cfg, err := mysqlDriver.ParseDSN(dsn)
	if err != nil {
		t.Fatal("驱动无法解析连接配置")
	}
	if !cfg.AllowNativePasswords {
		t.Error("必须允许已有 MySQL 账户使用 mysql_native_password")
	}
	if cfg.AllowCleartextPasswords || cfg.AllowOldPasswords {
		t.Error("不得放开明文或旧式密码认证")
	}
}
