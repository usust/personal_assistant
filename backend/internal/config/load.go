// 文件职责：加载配置文件到应用配置结构，隔离文件读取与后续资源初始化。

package config

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/viper"
)

// LoadConfig 读取本地 YAML 配置，按 mapstructure 标签填充 cfg。
// cfg 必须为非 nil 指针；文件中未提供的字段保留原有默认值。
// PA_CONFIG_FILE 去除首尾空白后非空时读取指定路径，否则读取运行目录下的 config.yaml。
// 指定路径不可读取或文件内容解析失败时直接返回错误，不回退到其他文件。
// 参数：cfg 为已填默认值的非 nil 指针；返回值：读取、解析或校验错误；成功会修改 cfg。
func LoadConfig(cfg *Config) error {
	if cfg == nil {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("配置目标必须是非 nil 指针")
	}

	file := "config.yaml"
	// 显式指定的配置路径必须按部署意图读取，失败时不回退，避免误用其他环境的配置。
	if candidate := strings.TrimSpace(os.Getenv("PA_CONFIG_FILE")); candidate != "" {
		file = candidate
	}

	// 创建独立的配置加载器。
	v := viper.New()
	// 指定本次读取的配置文件。
	v.SetConfigFile(file)
	// 指定配置内容的解析格式。
	v.SetConfigType("yaml")
	// 读取选定的配置文件。
	if err := v.ReadInConfig(); err != nil {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("读取配置文件 %q 失败: %w", file, err)
	}
	// 将文件配置映射到应用结构。
	if err := v.Unmarshal(cfg); err != nil {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("解析配置文件 %q 失败: %w", file, err)
	}
	// 在创建运行资源前确认配置有效。
	if err := cfg.Validate(); err != nil {
		// 为失败补充当前操作的错误上下文。
		return fmt.Errorf("配置校验失败: %w", err)
	}
	return nil
}
