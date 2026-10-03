// 文件职责：适配记账 HTTP 请求并输出统一响应。

package handler

import (
	"strconv"

	"github.com/gin-gonic/gin"

	"personal_assistant_server/internal/finance/service"
)

// parseFilter 解析已知查询参数；参数：c 为请求上下文；返回值：筛选对象或格式错误，拒绝重复与未知键。
func parseFilter(c *gin.Context) (service.Filter, error) {
	f := service.Filter{}
	// 读取客户端提交的查询条件。
	for k, values := range c.Request.URL.Query() {
		if len(values) != 1 {
			// 拒绝本次操作：查询参数不得重复。
			return f, service.Invalid("查询参数不得重复")
		}
		v := values[0]
		switch k {
		case "startDate":
			f.StartDate = v
		case "endDate":
			f.EndDate = v
		case "type":
			f.Type = v
		case "status":
			f.Status = v
		case "minAmount":
			f.MinAmount = v
		case "maxAmount":
			f.MaxAmount = v
		case "keyword":
			f.Keyword = v
		case "accountId", "categoryId":
			if v == "" {
				continue
			}
			// 将资源标识解析为无符号整数。
			n, e := strconv.ParseUint(v, 10, 64)
			if e != nil || n == 0 {
				// 拒绝本次操作：筛选 ID 无效。
				return f, service.Invalid("筛选 ID 无效")
			}
			if k == "accountId" {
				f.AccountID = n
			} else {
				f.CategoryID = n
			}
		case "limit", "offset":
			// 将文本字段解析为整数。
			n, e := strconv.Atoi(v)
			if e != nil {
				// 拒绝本次操作：分页参数无效。
				return f, service.Invalid("分页参数无效")
			}
			if k == "limit" {
				f.Limit = n
			} else {
				f.Offset = n
			}
		default:
			// 拒绝本次操作：未知查询参数。
			return f, service.Invalid("未知查询参数")
		}
	}
	return f, nil
}
