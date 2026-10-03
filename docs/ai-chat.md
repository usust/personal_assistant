# 最小 AI 对话链路

前端侧边栏的「AI 对话」对应 `/ai` 页面。先在「系统设置 → AI 配置」创建配置，再在对话页选择配置并发送消息。

第一版使用支持工具调用的 OpenAI 兼容 Chat Completions 协议。服务地址填写 API 前缀（例如 `https://api.example.com/v1`），后端追加 `/chat/completions`；也支持填写完整的 `/chat/completions` 地址。提供商列表中的名称不保证其原生协议兼容，需要填写兼容接口的地址并选择支持该接口工具调用的模型。

可尝试：

- 列出所有用户。
- 注册账号 demo_user，昵称演示用户，密码为指定的测试密码。
- 把用户 123 的昵称改成小明。
- 删除用户 123。

修改和删除遵循现有管理员权限，明确请求的操作直接执行。对话暂存页面内存，刷新或离开后清空。AI 回答使用 Markdown 展示，支持表格、列表、标题、引用、链接和代码块；用户消息保持纯文本。禁用原始 HTML 和图片，宽表格与代码块在消息内滚动，历史消息仍以原始文本回传模型。

## 目录与函数调用链

```text
apps/web/src/views/AIChatView.vue: send()
  → apps/web/src/api/ai.ts: sendChat()
  → POST /api/ai/chat
  → internal/ai/handler.go: (*Handler).Chat()
  → internal/ai/service.go: (*Service).Run()
  → internal/aiconfig/service.go: (*Service).GetUsable()
  → internal/ai/chat.go: (*Chat).Run()
  → internal/ai/client.go: (*HTTPClient).Complete()
  → internal/capability/executor.go: (*Executor).Invoke()
  → internal/user/capability/definitions.go: 工具参数适配
  → internal/user/service/: 统一业务授权、校验与执行
  → 工具结果回传模型
  → 返回 reply / actions / error
```

路径中的 `internal/` 相对于 `backend/`。共享用户服务、执行器和模型客户端在 `internal/app/wire.go: New()` 组装。HTTP 用户接口直接调用同一个用户服务，AI 工具通过执行器适配后调用；权限校验只维护在业务服务中。

各能力的 `InputSchema` 描述模型需要填写的参数。`Executor.Definitions()` 读取注册表，AI 适配器生成工具目录；模型函数名用 `cap_0` 等局部别名映射到 `user.list` 等能力名，避免含点名称不符合模型协议。

新增能力时，在所属模块定义接收可信 `Actor` 的执行回调和 `InputSchema`，再于 `app/wire.go` 追加到应用级注册表。业务服务必须自行校验操作者权限，不能依赖 HTTP 中间件代替授权。无需在 AI 模块另写一套业务实现。

## 最小实现的边界

- 支持注册的用户、任务及财务能力，未注册业务无法调用。财务 AI 写入只创建待确认草稿，不能直接改变余额，见 [财务管理](finance-management.md)。
- 配置使用权限和操作人身份由后端检查；API 密钥不返回前端。
- 客户端提交文本历史，系统消息和本轮工具调用由后端构造。
- 每轮最多 6 次模型请求、12 次工具调用，总超时 90 秒。
- 没有通用自动重试、通用审批、持久化会话、流式响应或复杂任务编排；财务模块单独实现草稿确认与幂等保护。
- 操作后模型出错会返回已执行的操作状态，不自动回滚；浏览器断线时应先查询数据再决定是否重新操作。
- 工具调用协议参考：https://developers.openai.com/api/docs/guides/function-calling

验证使用内存 HTTP 模型传输与临时 SQLite 数据库，覆盖共享授权、用户更新工具循环、部分执行后上游失败，以及对话入口登录与配置访问限制。不调用真实模型，不修改真实用户数据。
