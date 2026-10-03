// 文件职责：提供服务健康检查响应，作为基础运行状态探测入口。

package router

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// health 返回进程存活状态，保留部署健康检查使用的响应协议。
// 参数：c 为请求上下文；返回值：无，写入 200 JSON；不执行数据库就绪检查。
func health(c *gin.Context) {
	// 向客户端返回本次操作结果。
	c.JSON(http.StatusOK, gin.H{"code": http.StatusOK, "message": "ok", "data": gin.H{"service": "personal-assistant", "status": "ok"}})
}
