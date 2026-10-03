# Mac Runner 自动发布

当前后端配置 listen_addr 为 :20000；Compose 内部后端端口为 20000，Web 映射为 192.168.31.3:10000。
生产配置使用 /mnt/sata2-4/personal-assistant/shared/config.yaml，只读挂载且不随代码发布覆盖。

## 触发与运行环境

.github/workflows/release.yml 在 main 的应用或部署文件改动后自动执行，也可通过 Actions 页面手动执行。
Runner 使用 self-hosted、macOS、ARM64 标签；专用仓库 Runner 需要具备 Node（兼容 Vite，建议 22.12+）、npm、Go（满足 go.mod）、clang 和 SSH。
后台服务需在同一用户下能免交互访问 root@192.168.31.3，known_hosts 必须提前核对并记录。

Mac 执行后端测试、go vet、Linux amd64 交叉编译，以及 Web 锁定依赖安装、测试和构建。
成品通过 SSH 上传到服务器版本目录，服务器从 runtime Dockerfile 构建镜像，无需安装 Node 或 Go，也无需在 Mac 安装 Docker。
服务器需要能访问 Docker Hub。当前基础镜像使用版本系列标签，后续可锁定已验证的 digest。

## 部署行为

每次发布使用完整 Git SHA、run ID、attempt 作为独立版本。Compose 项目名固定，禁止并行部署。
服务器先验证成品和配置、构建两个镜像，再备份 personal_assistant 数据库并更新容器。
mysql8 的备份依赖容器中可用的 MYSQL_ROOT_PASSWORD（或已有无密码认证）；失败时阻止更新。
数据库启动迁移不自动撤销，旧版本必须兼容迁移后的结构。首次部署失败无旧版本时停止新容器。
健康检查验证进程和入口，不替代业务验收；日志、数据目录保留，Docker 日志轮转启用。
升级有短暂中断；不会修改 NextPass 或现有 Nginx 入口。iOS 不参与编译。

## 验证及手动回滚

在服务器查看状态：

```sh
cd /mnt/sata2-4/personal-assistant/current
docker compose --env-file release.env -f compose.yaml ps
docker compose --env-file release.env -f compose.yaml logs --tail 100
```

回滚到 previous（先确认镜像仍存在）：

```sh
cd /mnt/sata2-4/personal-assistant/previous
docker compose --env-file release.env -f compose.yaml up -d --no-build --pull never --wait --wait-timeout 180
curl -f http://192.168.31.3:10000/api/health
```

确认成功后将 current 指向该实际版本目录，避免下次自动部署使用错误的回退基线。不要在自动发布期间手动回滚。
数据库备份与镜像不自动清理；应监测磁盘空间并另存备份。部署锁若因服务器断电残留，应确认没有部署进程后手动移除。

源码 Dockerfile 仅作为可选完整构建方式；自动发布采用 runtime Dockerfile。构建上下文排除本机配置。
当前自动发布尚未在 Runner 上实跑；首次触发需观察 Actions 输出。

## API 子域名入口

现有 lylab-proxy-nginx-1 挂载 deploy/docker/paapi.nginx.conf 对应配置到 conf.d，监听 8888。
后端加入已有外部网络 lylab-proxy_default，使用专用别名 personal-assistant-api；宿主机同时映射 192.168.31.3:20000，供局域网 iOS 直连。
Nginx 使用 Docker DNS 动态解析上游，后端重新创建后自动解析新地址。
DNS 和公网 HTTPS 入口还需将 paapi.lylab.vip 的请求（保留 Host）转发到 192.168.31.3:8888。
Nginx 域名配置当前为服务器独立管理文件；workflow 更新 Compose 保留网络连接，不自动覆盖入口配置。

局域网 iOS API 地址：http://192.168.31.3:20000/api。端口仅绑定指定服务器地址。
