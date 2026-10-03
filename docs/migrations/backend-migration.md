> 历史记录：当前结构和功能范围见 [架构说明](../architecture.md)。

# 后端移植说明

## 补全后的执行提示词

对比 `/Users/lyu/Library/Mobile Documents/com~apple~CloudDocs/mycode/base-backend/backend` 与个人助手项目当前的后端目录 `pa-backend/`，以源目录当前磁盘内容为权威版本，完整移植全部后端源码、依赖声明和配置。同路径冲突以源版本为准，覆盖前备份目标差异文件；保留个人助手独有代码、文档、前端和部署资源。保留已有未提交改动的状态，不擅自恢复用户已删除的历史文件，也不删除源目录。排除编辑器和操作系统元数据，调整必要的初始化、路由、登录集成及构建配置，完成测试和构建并记录限制。

## 对比与移植结果

- 源目录的 50 个文件全部移植到 `pa-backend/`。逐文件 SHA-256 基线见 `backend-migration-manifest.json`，包含源配置文件的指纹，但不包含配置内容。
- 新增源项目的 `internal/setting/` 全模块，包括 AI 提供商、配置创建和读取、用户语言及时区设置。
- 日志、认证配置、认证中间件、主程序、路由、Go 工具版本和本地配置以源文件为准。`go.mod`、`go.sum` 原本一致，完整保留。
- 保留助手独有的 `docs/agent-context-flow.png`、原有用户服务测试及其他现存文件。
- 覆盖前的不同版本保存在项目根目录 `.migration-backup/base-backend-20260925/`；备份及 `pa-backend/config.yaml` 已加入 Git 忽略规则。源项目没有被修改或删除。
- `.idea`、`.DS_Store` 不属于项目源码，未迁移。

## 必要的集成修改

移植文件中仅 `main.go`、`internal/router/router.go` 与源版本有差异：路由初始化失败后停止启动；在注册路由前调用新增的 `integration.go`，恢复助手原有用户表迁移和空表默认管理员初始化，并迁移用户设置表。

新增集成文件注册以下助手接口，同时保留源项目全部认证及设置路由：

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/health` | 健康检查 |
| GET | `/api/users/me` | 获取登录用户，使用源认证中间件 |
| GET / PATCH | `/api/settings/user` | 读取和更新自己的设置 |
| GET | `/api/auth/captcha` | 源验证码接口 |
| POST | `/api/auth/login` | 源登录接口 |
| POST | `/api/users/register` | 源注册接口 |
| GET | `/api/setting/ai/providers` | 源 AI 提供商列表 |
| POST | `/api/setting/ai/provider_config/create` | 源 AI 配置创建 |
| GET | `/api/setting/ai/provider_config` | 源 AI 配置读取 |

前端登录适配 `/auth/*` 的路径、snake_case 请求和响应，登录后通过 `/users/me` 获取用户资料；错误提示兼容源项目的 `error` 字段。现有页面和其他业务 API 代码保留。

Makefile、CI 的工作目录和构建产物路径已使用 `pa-backend/`；部署模板仍在 `deploy/backend/`。systemd 使用 `PA_CONFIG_FILE`。新增无真实凭证的 `config.example.yaml`，采用源项目的 `listen_addr`、`database_driver`、`mysql_connection` 和 `auth.jwt_expireHours` 配置结构。

## 验证与运行边界

后端 `go test ./...` 通过，包括原有管理员测试和新增 SQLite 内存库集成测试：空库建表、重复初始化、健康检查、验证码、未登录拒绝访问、登录用户资料、AI 配置和用户设置读取。

Linux ARM64 静态可执行文件构建通过；前端 `vue-tsc -b && vite build` 通过，依赖来自现有 `package-lock.json`，锁文件未修改。前端仅有第三方注释和打包体积警告。`git diff --check` 通过。

本次没有启动连接真实 MySQL 的服务，没有修改任何真实数据库，也没有执行远程部署。上线前服务器的共享配置必须按新示例迁移；现有部署校验会拒绝旧数据库配置结构。源项目允许跨域来源的配置字段尚未接入 CORS 中间件，前端应使用 Vite 或生产同源代理访问。

任务和财务后端源码在开始本次操作前已从当前工作区删除，源目录也没有这些模块，因此没有从 Git 历史恢复；保留下来的任务和财务前端页面目前没有对应后端接口。README 的历史接口清单应结合此说明阅读。
