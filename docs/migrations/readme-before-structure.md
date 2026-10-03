# 结构调整前的 README 归档

历史快照，不代表当前功能；当前入口见 [README](../../README.md)。

> 后端已移植到 `pa-backend/`，以 base-backend 当前工作区为准。当前接口、迁移范围和验证见 [迁移说明](backend-migration.md)；下文历史业务接口表不代表当前已实现能力。

# Personal Assistant

一个前后端分离的个人助手管理后台起点：前端使用 Vue 3，后端采用 go-admin 风格的 Gin + GORM + JWT 分层结构，并在 `internal/goutils` 内置了基于 [usust/goUtils](https://github.com/usust/goUtils) 调整的配置和日志工具代码。

## 技术栈

- 前端：Vue 3、TypeScript、Vite、Vue Router、Pinia、Element Plus、Axios
- 后端：Go、Gin、GORM、MySQL、JWT、bcrypt、内置配置及日志工具（Viper + Zap）
- 默认账号：`admin`
- 默认密码：`123456`

> 默认账号仅用于本地开发。部署前请修改管理员密码和配置中的 `jwt_secret`。

## 目录

```text
.
├── frontend/                    # Vue 3 前端
│   └── src/
│       ├── api/                 # HTTP 请求封装
│       ├── layouts/             # 后台布局
│       ├── router/              # 路由及登录守卫
│       ├── stores/              # Pinia 状态
│       └── views/               # 登录、工作台、设置页
└── pa-backend/                     # Gin 后端
    └── internal/
        ├── config/              # YAML 配置定义及启动校验
        ├── database/            # GORM 初始化及数据迁移
        ├── goutils/             # 本地配置加载、Bootstrap 和 Zap 日志代码
        ├── handler/             # API 控制器
        ├── middleware/          # JWT、CORS 中间件
        ├── model/               # 数据模型
        ├── router/              # 路由注册
        └── service/             # 业务服务
```

## 运行命令

需要 Node.js 20+、npm、Go 1.26.2+ 和 MySQL 8.0+。

以下命令均在项目根目录 `PersonalAssistant` 下执行。

### 1. 首次安装

```bash
# 安装前端依赖
cd frontend
npm install
cp .env.example .env.local

# 下载后端依赖并创建 YAML 配置
cd ../pa-backend
go mod download
cp config.example.yaml config.yaml
# 编辑 config.yaml，填写可用的 MySQL 地址、账号、密码和数据库名

# 返回项目根目录
cd ..
```

### 2. 启动后端

打开第一个终端：

```bash
cd pa-backend
go run .
```

后端默认读取当前目录下的 `config.yaml`，连接其中启用的 MySQL 数据库并监听 `http://localhost:16101`。数据库需提前创建；首次启动会自动建表并写入默认管理员账号。Zap 日志会写入 `pa-backend/log/`。

部署时可用 `EXPORT_CONFIG_FILE` 指定其他配置文件，无需复制为默认文件名：

```bash
cd pa-backend
EXPORT_CONFIG_FILE=/path/to/production.yaml go run .
```

配置在启动阶段完成校验；端口、运行模式、MySQL 连接参数、JWT 配置或跨域来源无效时，服务会直接拒绝启动。

### 3. 启动前端

打开第二个终端：

```bash
cd frontend
npm run dev
```

访问 `http://localhost:16100`。开发服务器会把 `/api` 请求代理到 `http://localhost:16101` 的后端。

### 4. 部署 Web 服务

生产环境不需要常驻 Vite。前端 workflow 会把构建结果发布到
`/srv/www/personal-assistant/current`，宿主机上的独立 Web 服务负责在 `16100`
端口提供静态页面。Docker 中监听 `8000` 的入口 Nginx 是另一个服务，可以按需
反向代理到宿主机的 `16100`。

首次部署或 Web 服务配置发生变化时，在服务器执行：

```bash
sudo cp /srv/www/personal-assistant/deploy/personal-assistant-web.service \
  /etc/systemd/system/personal-assistant-web.service
sudo systemctl daemon-reload
sudo systemctl enable --now personal-assistant-web.service
```

随后只需访问：

```text
http://192.168.31.6:16100
```

可以用下面的地址检查宿主机 Web 服务：

```bash
curl -I http://192.168.31.6:16100/
```

该服务只负责前端文件，不依赖后端 `16101`。如果入口 Nginx 需要通过 `8000`
提供同一个页面，应将它的上游设置为宿主机 `16100`。

正式环境使用同一个域名 `lylab.vip`：公网 DNS 将它解析到公网入口；需要在内网直连的
客户端则通过 hosts 将它覆盖为 `192.168.31.6`。前端正式构建使用同源 `/api`，Nginx
负责将页面请求转发到 Web `16100`，并将 `/api/` 转发到后端 `192.168.31.5:16101`。
macOS/Linux 的 `/etc/hosts` 可添加：

```text
192.168.31.6 lylab.vip person.lylab.vip
```

hosts 覆盖不会根据当前网络自动切换；设备离开内网后，需要注释或删除该条目，才能恢复
使用公网 DNS。
配置模板会随前端发布到：

```text
/srv/www/personal-assistant/deploy/personal-assistant.nginx.conf
```

将其安装到 Nginx 后检查并重载：

```bash
nginx -t
nginx -s reload
```

如果 Nginx 运行在 Docker 中，需要把该配置挂载到容器的 `/etc/nginx/conf.d/`，并将
宿主机标准端口 `80`（以及启用 HTTPS 后的 `443`）映射到容器。DNS 只能映射 IP，不能
把内网访问的 `80` 自动改成 `8000`。

### 5. 通过 CI 部署后端可执行程序

后端 workflow 在本机 Mac self-hosted Runner 上运行测试，并将不依赖 CGO 的 Go 后端
交叉编译为 Linux ARM64 可执行文件。随后 CI 将成品上传到
`dok@192.168.31.5`，由 systemd 直接运行在 `16101`。`.5` 服务器不负责编译，也不使用
Docker。新版本健康检查失败时，CI 会恢复上一个版本。

Runner 使用以下私钥免密登录：

```text
/Users/lyu/.ssh/personal_assistant_backend
```

当前 CI 不依赖 GitHub Secret。首次部署时会将 `pa-backend/config.example.yaml` 复制到
`/srv/personal-assistant-backend/shared/config.yaml`；后续部署不会覆盖服务器上的该文件。
此配置中的 `jwt_secret` 仅为临时占位值，正式使用前应直接在服务器上替换。
如果服务器已有旧配置，请在部署前将 `database.active` 改为 `mysql`，并确认对应连接参数
有效；新版后端只接受 MySQL 配置。

在 `.5` 服务器一次性准备目录：

```bash
sudo mkdir -p /srv/personal-assistant-backend
sudo chown -R dok:dok /srv/personal-assistant-backend
```

systemd 服务名称为 `personal-assistant-backend.service`。将仓库内的 service 上传并安装：

```bash
scp -i /Users/lyu/.ssh/personal_assistant_backend \
  deploy/backend/personal-assistant-backend.service \
  dok@192.168.31.5:/tmp/personal-assistant-backend.service

ssh -i /Users/lyu/.ssh/personal_assistant_backend dok@192.168.31.5 \
  'sudo install -m 644 /tmp/personal-assistant-backend.service /etc/systemd/system/personal-assistant-backend.service && sudo systemctl daemon-reload && sudo systemctl enable personal-assistant-backend.service'
```

为了允许 CI 无密码重启这一项服务，用 `sudo visudo` 添加：

```sudoers
dok ALL=(root) NOPASSWD: /usr/bin/systemctl restart personal-assistant-backend.service
```

推送代码并完成首次 CI 后检查：

```bash
sudo systemctl status personal-assistant-backend.service
curl http://192.168.31.5:16101/api/health
```

正式前端构建使用 `http://192.168.31.5:16101/api`，需要确保服务器防火墙允许访问
`16101`。

### 使用 Makefile 快速启动

完成首次安装后，也可以在项目根目录运行：

```bash
# 启动后端
make dev-backend

# 启动前端，需要另开一个终端
make dev-frontend
```

### 停止服务

在运行服务的终端按 `Ctrl + C`。

## PA_CONFIG_FILE 配置文件环境变量

`PA_CONFIG_FILE` 用于指定配置文件路径，便于在开发、测试或部署环境中使用不同的配置文件。它的值是文件路径，不是 YAML 配置内容；变量名称在代码中使用，变量的值由终端、IDE 运行配置或部署环境设置，程序不会从 README 读取变量。

### 检查顺序

`pa-backend/bootstrap/config_file.go` 中的 `CheckConfigFile()` 按以下顺序检查：

1. 读取 `PA_CONFIG_FILE`，去除值两端的空白；非空时优先检查该路径。
2. 环境变量未设置、为空或指定路径不可用时，检查当前工作目录下的 `config.yaml`。
3. 任一位置存在普通文件即返回成功；所有候选位置均不可用时，返回包含具体路径和原因的错误。目录不算配置文件。

相对路径以程序启动时的工作目录为基准，不是源码目录或可执行文件所在目录。部署时建议使用绝对路径。该函数只检查文件存在性和类型，不读取配置内容、不验证 YAML，也不返回选中的路径或修改环境变量。

### 设置方法

macOS / Linux（zsh、bash）：

```sh
# 设置后，当前终端启动的子进程会继承该变量
export PA_CONFIG_FILE="/absolute/path/to/config.yaml"

# 查看当前值
printenv PA_CONFIG_FILE

# 取消设置，让检查函数使用默认位置
unset PA_CONFIG_FILE
```

也可以只为一次命令设置变量：

```sh
PA_CONFIG_FILE="/absolute/path/to/config.yaml" your-command
```

其中 `your-command` 需替换为实际调用该检查函数的程序命令。这种写法不会永久修改当前终端环境。

Windows PowerShell：

```powershell
$env:PA_CONFIG_FILE = "C:\personal-assistant\config.yaml"
$env:PA_CONFIG_FILE
Remove-Item Env:PA_CONFIG_FILE
```

通过 IDE 启动时，在对应运行配置的环境变量中添加 `PA_CONFIG_FILE`，值填写配置文件路径，并确认工作目录设置正确。终端中的设置仅影响该终端及其后续启动的子进程，不会自动更新已经运行的 IDE 或服务。

### 当前接入状态

目前 `PA_CONFIG_FILE` 仅由新的 `CheckConfigFile()` 使用，该函数尚未接入主程序的启动流程。现有 `go run .` 启动流程仍使用 `internal/goutils` 中的 `EXPORT_CONFIG_FILE`；仅设置 `PA_CONFIG_FILE` 暂时不会改变主程序实际加载的配置文件。

旧加载流程在 `EXPORT_CONFIG_FILE` 非空时直接读取指定文件，读取失败会报错，不会回退到 `config.yaml`。上面的回退规则仅适用于新的检查函数；后续接入时，需要让实际配置加载使用同样的路径选择规则。

## API

| 方法 | 地址 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| GET | `/api/health` | 否 | 服务健康检查 |
| GET | `/api/captcha` | 否 | 获取一次性登录验证码，验证码两分钟内有效 |
| POST | `/api/login` | 否 | 用户登录并获取 JWT |
| GET | `/api/task-lists` | 是 | 查询当前用户的任务清单 |
| POST | `/api/task-lists` | 是 | 创建任务清单 |
| PATCH | `/api/task-lists/:taskListId` | 是 | 更新任务清单 |
| DELETE | `/api/task-lists/:taskListId` | 是 | 删除任务清单及其中任务 |
| GET | `/api/tasks` | 是 | 查询主任务、子任务和服务端汇总进度 |
| POST | `/api/tasks` | 是 | 创建主任务或带工作量设置的子任务 |
| PATCH | `/api/tasks/:taskId` | 是 | 更新无子任务主任务的完成状态 |
| PATCH | `/api/tasks/:taskId/progress` | 是 | 增加、编辑、完成或重置子任务进度 |
| DELETE | `/api/tasks/:taskId` | 是 | 删除任务；主任务可显式级联删除子任务 |

任务清单的创建接口支持 `name`、`remark`、`color` 和 `icon` 字段，其中 `remark` 为最长 2000 个字符的可选备注。更新接口支持部分更新这些字段，传入空字符串可清空备注。

子任务使用“进度总量、当前完成量、默认增量”记录执行情况。主任务的进度由后端按工作量加权计算：

```text
主任务进度 = 所有子任务完成量之和 / 所有子任务总量之和 × 100%
```

例如两个子任务分别为 `60/100` 和 `10/20`，主任务进度为 `70/120 = 58.33%`。进度数值最多支持两位小数；增量更新由后端原子处理，主任务状态随汇总结果自动切换为待办、进行中或已完成。

登录前先请求验证码：

```bash
curl http://localhost:16101/api/captcha
```

响应中的 `data.captchaId` 和 `data.image` 分别用于关联验证码及展示验证码图片。识别图片内容后，将验证码 ID 和输入内容随登录请求一并提交：

```bash
curl -X POST http://localhost:16101/api/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"123456","captchaId":"验证码ID","captchaCode":"图片中的验证码"}'
```

验证码只能校验一次，无论答案是否正确，登录尝试后都需要重新获取。

## 测试与构建命令

```bash
# 在项目根目录运行全部测试
make test

# 构建前端和后端
make build
```

也可以分别运行：

```bash
# 前端类型检查和生产构建
cd frontend
npm run type-check
npm run build

# 后端测试、静态检查和编译
cd ../pa-backend
go test ./...
go vet ./...
go build ./...
```

## 后续扩展

新增业务时，可以按 `model → service → handler → router` 添加后端模块，再在前端的 `api → store → view` 中接入。若要完整引入 go-admin 的 Casbin RBAC、代码生成、菜单权限和 Swagger，可继续在当前分层上扩展。
