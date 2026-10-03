# Personal Assistant

Vue 3 + TypeScript 前端与 Go / Gin / GORM 后端组成的个人助手项目。

当前可用功能：验证码登录、用户管理、AI 连接配置及带工具调用的 AI 对话、任务管理和日常财务记账。个人偏好后端已移除；日历和个人偏好页面目前显示占位页。财务已恢复账户、流水和总览，贷款与房贷源码保留供后续开发。

## 目录与文档

```text
backend/          Go 后端，入口 main.go
apps/web/            Vue 前端
  src/api/           按业务区分的 HTTP 客户端
  src/types/         按业务区分的数据类型
  src/views/         页面
  src/finance/       财务业务组件（贷款、房贷暂未接入）
  tests/             API 契约与 Markdown 测试
docs/                当前架构与使用说明
  design/            尚未实现的设计规划
  migrations/        历史迁移记录与旧文档快照
  assets/            文档图片
deploy/              Web 和后端部署配置
.github/workflows/   CI 与发布流程
```

- [当前架构与依赖方向](docs/architecture.md)
- [AI 对话与工具接入](docs/ai-chat.md)
- [部署说明](docs/deployment.md)
- [历史后端移植记录](docs/migrations/backend-migration.md)
- [助手后续设计](docs/design/assistant-roadmap.md)

## 本地启动

需要 Go 1.26.2+、Node.js 20+、npm 和 MySQL；测试使用项目已有的 SQLite 驱动，需要 CGO 编译环境。

```sh
cd backend
cp config.example.yaml config.yaml
# 编辑数据库连接、JWT 密钥及 default_user 账号密码
go run .
```

`PA_CONFIG_FILE` 去除首尾空白后非空时，读取指定路径；未设置或为空时，读取当前工作目录的 `config.yaml`。配置按 YAML 格式解析，读取、解析或校验失败时直接终止启动，不回退到其他文件。缺少文件时，请复制 `config.example.yaml` 为 `config.yaml` 并填写必要配置后再启动。默认管理员仅在用户表为空时创建，已有用户不会被覆盖。

```sh
PA_CONFIG_FILE=/absolute/path/config.yaml go run .
```

日志仅由 `zap_log.output` 数组控制：`[console]` 输出终端，`[file]` 写入文件，`[console, file]` 同时输出；未填写或 `[]` 关闭日志。选择 `file` 时 `log_dir` 必须非空，否则忽略目录和轮转配置。未知输出目标会导致启动失败，重复目标只输出一次。

另开终端启动前端：

```sh
cd apps/web
npm install
cp .env.example .env.local
npm run dev
```

默认前端端口 `10000`，Vite 将 `/api` 代理到后端 `16101`。生产采用同源代理；`allowed_origins` 为保留配置，目前未启用跨域中间件。

## 当前接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 进程存活检查 |
| GET | `/api/auth/captcha` | 一次性验证码 |
| POST | `/api/auth/login` | 验证码及密码登录 |
| POST | `/api/users/register` | 公开注册普通用户 |
| GET | `/api/users` | 公开用户列表，不含密码哈希 |
| GET | `/api/users/me` | 当前登录用户 |
| PATCH / DELETE | `/api/users/:id` | 管理员局部更新或删除用户 |

所有业务模块及存活检查的普通 JSON 响应统一为 `{"code":200,"message":"ok","data":{}}`。
`code` 必须与实际 HTTP 状态码一致：查询、更新、登录和删除成功为 200，注册、新建业务资源成功为 201；失败使用对应 4xx/5xx，并返回 `data:null`。删除业务资源成功返回 200 和 `data:null`。错误信息通过 `message` 返回，响应不再使用 `error` 字段。此协议适用于 `/api/users`、`/api/auth`、`/api/setting/ai`、`/api/tasks`、`/api/task-lists`、`/api/finance`、`/api/health-management`、`/api/ai` 和 `/api/health`。AI 对话中的部分执行失败保留在 `data.error`，同时返回已执行的 `data.actions`。

| GET | `/api/setting/ai/providers` | 登录后读取提供商目录 |
| GET | `/api/setting/ai/provider_config` | 当前用户可使用的配置，不含密钥 |
| POST | `/api/setting/ai/provider_config/create` | 创建配置，返回无密钥摘要 |
| POST | `/api/setting/ai/models` | 查询模型目录，编辑时可复用已保存连接密钥 |
| PATCH / DELETE | `/api/setting/ai/provider_config/:id` | 局部更新或删除有管理权限的配置 |
| POST | `/api/ai/chat` | 对话及工具执行结果 |

Web 模型服务支持目录刷新、创建、编辑和删除，表单与删除确认统一在第三栏展开；刷新目录不缓存密钥，编辑仅提交变更字段。iOS 使用 iOS 27 原生液态玻璃导航及操作元素，模型服务列表保留普通系统背景。

内部模块调整保留了上述 URL、YAML 键及业务表名。创建配置的服务器字段（ID、创建者、更新时间）不属于请求 DTO，不接受客户端提交。`/api/settings/user` 不再注册，也不再迁移 `user_settings`；历史数据不会被删除。

## 验证与构建

```sh
make test
make build
```

也可以分别执行：

```sh
cd backend
go test ./...
go vet ./...
go build ./...

cd ../apps/web
npm test
npm run build
```

后端集成测试使用临时 SQLite 与内存 HTTP 模型传输，覆盖显式迁移、权限一致性、PATCH、配置可见范围及工具部分执行失败，不连接真实 MySQL 或模型。

## 任务管理

任务清单页面已恢复，后端提供用户隔离的任务树、进度、排序和操作记录，并通过共享 Capability 支持 AI 对话操作。接口、设计依据、补充后的实施提示词与数据迁移边界见 [任务管理说明](docs/task-management.md)。

## 财务管理

已支持账户、默认及自定义分类、收支/转账、筛选分页、月度统计与流水作废。AI 通过共享 Capability 查询账本和生成待确认草稿，由用户在财务页面确认后入账。补充后的需求提示词、设计参考、接口、金额与幂等规则见 [财务管理说明](docs/finance-management.md)。

## 健康管理

iOS 经 HealthKit 授权同步最近 30 个自然日（含今天，今天截至同步时刻）的步数、活动能量、距离、静息心率和体重；后端保存用户隔离的日汇总，经明确同意后调用所选 AI 生成健康报告。iOS 和 Web 支持查看与清除，Web 使用统一第三栏。完整实施提示词、API、统计口径和真机验收见 [健康管理说明](docs/health-management.md)。

### 其余业务模块 API 契约

- [任务、记账、健康、AI 与存活检查 OpenAPI](docs/api/internal.openapi.json)：57 个接口，包含白名单输入、请求与响应模型、状态码、认证和业务约束。
- [Apifox 同步记录](docs/api/apifox-internal-sync.json)：项目 8566884，AI 分支 `ai/20261003-from-main-user-models`，57 个接口与 54 个新增模型已回读校验。
