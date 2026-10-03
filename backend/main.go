// 文件职责：后端进程入口，串联资源创建、数据初始化与 HTTP 运行，并将进程信号接入应用生命周期。
// 资源清理在退出前完成；启动或运行错误决定进程的非零退出状态。

package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"personal_assistant_server/internal/app"
)

// main 执行应用入口，并以非零退出状态报告启动或运行失败。
// 参数：无；返回值：无；失败会退出进程，资源清理由 run 在退出前完成。
func main() {
	// 执行应用完整启动与退出流程。
	if err := run(); err != nil {
		// 记录本次失败或运行提示。
		log.Print(err)
		// 将应用失败报告为非零进程退出状态。
		os.Exit(1)
	}
}

// run 绑定进程信号，按初始化、运行、关闭顺序管理应用。
// 参数：无；返回值：配置、初始化或 HTTP 错误；成功为 nil；会连接数据库并监听配置地址。
func run() error {
	// 将终端中断与服务管理器的终止请求统一接入应用生命周期，使初始化和运行共享取消边界。
	// Run 收到取消后使用独立的停机上下文等待在途请求，避免已取消的 ctx 使优雅停机立即失败。
	// stop 延迟到 run 返回才注销信号监听，因此停机期间再次发送 SIGINT/SIGTERM 不会强制退出；
	// 该策略允许清理完成，但若停机阻塞，重复按 Ctrl+C 也无法升级为默认的信号退出行为。
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	// 退出时释放进程信号监听。
	defer stop()
	// 将依赖组装、数据初始化与对外服务拆成三个阶段：Open 获取运行资源，Initialize 完成迁移和
	// 默认数据初始化，Run 才监听端口，确保初始化失败的实例不会接收业务请求。
	// Open 失败时自行回收部分资源，成功时将资源所有权交给 run；Close 在 Run 完成停机后执行，
	// 使数据库连接覆盖在途请求及后台任务的完整生命周期，初始化失败也走同一清理路径。
	// Open 不接收 ctx，资源创建阶段无法通过进程信号取消。
	// 当前忽略 Close 的返回错误，因此数据库关闭失败不会改变进程退出结果。
	application, err := app.Open()
	if err != nil {
		return err
	}
	// 退出时释放应用持有的运行资源。
	defer application.Close()
	// 将数据库就绪作为启动门槛：先迁移业务表，再初始化空库管理员，避免请求进入未就绪的数据层。
	// ctx 贯穿初始化数据库操作，允许终止信号取消启动；此阶段取消也作为启动错误上报。
	// 初始化并非覆盖迁移与默认数据写入的整体事务，失败前已完成的数据库变更可能保留；
	// 返回错误只阻止本次服务启动并释放运行资源，不代表回滚数据库到启动前的状态。
	// 开发凭证输出另受显式开关和 debug 模式限制，生成凭证失败仅记录提示，不阻断初始化。
	if err := application.Initialize(ctx); err != nil {
		return err
	}
	// 启动服务并等待应用退出。
	return application.Run(ctx)
}
