// 文件职责：定义日志组件的初始化参数，与应用配置文件格式保持独立。

package logging

// Options 定义日志实现共用的输出及文件轮转参数，不承载配置文件字段映射、应用级默认值或实现专属选项。
type Options struct {
	Output     []string // 输出目标：console、file；空列表关闭日志，重复目标去重。
	Level      string   // 日志级别，空字符串使用 info。
	Dir        string   // 文件输出目录，选择 file 时必须非空，其他情况忽略。
	MaxSize    int      // 单个日志文件大小上限，单位 MB；0 使用轮转组件默认值 100。
	MaxBackups int      // 保留的旧日志文件数量；0 不按数量限制。
	MaxAge     int      // 旧日志文件保留天数；0 不按时间限制。
	Compress   bool     // 是否压缩轮转后的旧日志文件。
}
