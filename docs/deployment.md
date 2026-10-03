# 部署说明

本文保留现有服务器与 CI 布局，本次结构调整未执行部署。后端入口仍支持 `go build .`，配置环境变量仍为 `PA_CONFIG_FILE`。

## Web 服务

生产环境不需要常驻 Vite。前端 workflow 会把构建结果发布到
`/srv/www/personal-assistant/current`，宿主机上的独立 Web 服务负责在 `10000`
端口提供静态页面。Docker 中监听 `8000` 的入口 Nginx 是另一个服务，可以按需
反向代理到宿主机的 `10000`。

首次部署或 Web 服务配置发生变化时，在服务器执行：

```bash
sudo cp /srv/www/personal-assistant/deploy/personal-assistant-web.service \
  /etc/systemd/system/personal-assistant-web.service
sudo systemctl daemon-reload
sudo systemctl enable --now personal-assistant-web.service
```

随后只需访问：

```text
http://192.168.31.6:10000
```

可以用下面的地址检查宿主机 Web 服务：

```bash
curl -I http://192.168.31.6:10000/
```

该服务只负责前端文件，不依赖后端 `16101`。如果入口 Nginx 需要通过 `8000`
提供同一个页面，应将它的上游设置为宿主机 `10000`。

正式环境使用同一个域名 `lylab.vip`：公网 DNS 将它解析到公网入口；需要在内网直连的
客户端则通过 hosts 将它覆盖为 `192.168.31.6`。前端正式构建使用同源 `/api`，Nginx
负责将页面请求转发到 Web `10000`，并将 `/api/` 转发到后端 `192.168.31.5:16101`。
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

## 后端 CI 部署

后端 workflow 在本机 Mac self-hosted Runner 上运行测试，并将不依赖 CGO 的 Go 后端
交叉编译为 Linux ARM64 可执行文件。随后 CI 将成品上传到
`dok@192.168.31.5`，由 systemd 直接运行在 `16101`。`.5` 服务器不负责编译，也不使用
Docker。新版本健康检查失败时，CI 会恢复上一个版本。

Runner 使用以下私钥免密登录：

```text
/Users/lyu/.ssh/personal_assistant_backend
```

当前 CI 不依赖 GitHub Secret。首次部署时会将 `backend/config.example.yaml` 复制到
`/srv/personal-assistant-backend/shared/config.yaml`；后续部署不会覆盖服务器上的该文件。
此配置中的 `jwt_secret` 仅为临时占位值，正式使用前应直接在服务器上替换。
服务器配置使用 `database_driver: mysql` 和 `mysql_connection`，配置结构以 `backend/config.example.yaml` 为准。

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

正式前端默认使用同源 `/api`，由 Nginx 代理到后端；服务器之间需允许访问后端 `16101`。

