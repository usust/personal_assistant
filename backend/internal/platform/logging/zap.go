// 文件职责：按日志组件配置创建 Zap 日志资源，集中处理日志输出与运行环境设置。

package logging

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"gopkg.in/natefinch/lumberjack.v2"
)

// InitZap 按 Output 创建日志实例，console 输出文本到标准错误，file 输出轮转 JSON 文件。
// 参数：options 为日志组件配置；Output 仅支持 console、file，重复目标去重，空列表关闭日志并忽略其他参数。
// 返回值：日志实例及目标、级别或目录错误；成功后调用方负责 Sync，选择 file 时会创建目录与轮转文件。
func InitZap(options Options) (*zap.Logger, error) {
	// 输出目标是唯一开关，关闭日志时不解析级别或访问文件系统。
	if len(options.Output) == 0 {
		return zap.NewNop(), nil
	}
	console, file := false, false
	for _, target := range options.Output {
		switch target {
		case "console":
			console = true
		case "file":
			file = true
		default:
			return nil, fmt.Errorf("不支持的日志输出目标: %q", target)
		}
	}
	// 仅启用文件输出时要求目录，避免空路径意外写入工作目录。
	dir := strings.TrimSpace(options.Dir)
	if file && dir == "" {
		return nil, fmt.Errorf("文件日志输出必须配置日志目录")
	}
	level := zapcore.InfoLevel
	// 规范化输入，避免首尾空白影响校验。
	if value := strings.TrimSpace(options.Level); value != "" {
		// 解析配置中的日志级别。
		if err := level.UnmarshalText([]byte(value)); err != nil {
			// 为失败补充当前操作的错误上下文。
			return nil, fmt.Errorf("日志级别无效: %w", err)
		}
	}

	// 使用生产环境默认编码：级别为小写，ts 为 Unix 秒数，msg 为消息，caller 为调用位置。
	// 默认配置配合 JSON 编码器的示例：{"level":"info","ts":1790899200,"caller":"app/app.go:47","msg":"服务启动"}。
	// 下方会覆盖时间编码，因此实际文件日志的 ts 为 ISO 8601 字符串。
	encoderCfg := zap.NewProductionEncoderConfig()
	// 将时间编码为可读的 ISO 8601 格式，例如 "2026-10-02T08:00:00.000+0800"。
	encoderCfg.EncodeTime = zapcore.ISO8601TimeEncoder
	// 使用 caller 字段记录日志调用位置。
	encoderCfg.CallerKey = "caller"
	// 调用位置使用末级目录、文件名和行号，例如 "app/app.go:47"。
	encoderCfg.EncodeCaller = zapcore.ShortCallerEncoder

	// 每个目标最多创建一个输出通道，重复配置不会重复写日志。
	cores := make([]zapcore.Core, 0, 2)
	if console {
		// 终端保留简洁文本格式，文件使用完整 JSON 字段。
		consoleCfg := encoderCfg
		consoleCfg.EncodeTime = zapcore.TimeEncoderOfLayout("2006/01/02 15:04:05")
		consoleCfg.LevelKey = ""
		consoleCfg.ConsoleSeparator = " "
		cores = append(cores, zapcore.NewCore(
			zapcore.NewConsoleEncoder(consoleCfg),
			zapcore.Lock(zapcore.AddSync(os.Stderr)), level,
		))
	}
	if file {
		// 准备所需的目录结构。
		if err := os.MkdirAll(dir, 0750); err != nil {
			// 为失败补充当前操作的错误上下文。
			return nil, fmt.Errorf("创建日志目录失败: %w", err)
		}
		writer := &lumberjack.Logger{
			// 构造当前操作需要的完整路径或文本。
			Filename:   filepath.Join(dir, "app.log"),
			MaxSize:    options.MaxSize,
			MaxBackups: options.MaxBackups,
			MaxAge:     options.MaxAge,
			Compress:   options.Compress,
		}
		// 组合日志编码、输出目标与级别规则。
		cores = append(cores, zapcore.NewCore(
			// 创建结构化日志编码器。
			zapcore.NewJSONEncoder(encoderCfg), zapcore.AddSync(writer), level,
		))
	}

	// 合并多个日志输出通道。
	core := zapcore.NewTee(cores...)
	// 创建当前流程所需的组件。
	return zap.New(core, zap.AddCaller(), zap.AddStacktrace(zapcore.ErrorLevel)), nil
}
