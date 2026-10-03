#!/bin/sh
# 部署一套已编译成品；参数：$1 为发布版本，只允许字母、数字和连字符。
# 返回值：退出码 0 表示入口检查通过，非零表示失败；会打包镜像、备份数据库并更新容器。
# 失败时恢复上一个成功版本；首次发布无旧版本则停止新服务，数据库迁移不自动撤销。
set -eu
release_id=${1:?需要发布版本}
case "$release_id" in *[!a-zA-Z0-9-]*|'') echo 'Invalid release ID' >&2; exit 1;; esac
root=/mnt/sata2-4/personal-assistant
release="$root/releases/$release_id"
lock="$root/.deploy-lock"
mkdir "$lock" || { echo 'Another deployment is active; inspect lock before retrying' >&2; exit 1; }
previous=$(readlink "$root/current" 2>/dev/null || true)
activated=false
# 清理部署锁，更新失败且已切换服务时尝试恢复旧容器；参数：无；返回值：保留原退出码。
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$result" -ne 0 ] && [ "$activated" = true ]; then
    if [ -n "$previous" ] && [ -f "$previous/compose.yaml" ]; then
      if docker compose --env-file "$previous/release.env" -f "$previous/compose.yaml" up -d --no-build --pull never --wait --wait-timeout 180; then
        curl -fsS --max-time 10 http://192.168.31.3:10000/api/health >/dev/null || echo 'Rollback API verification failed' >&2
        echo 'Previous containers restored' >&2
      else
        echo 'Rollback failed; inspect containers immediately' >&2
      fi
    else
      docker compose --env-file "$release/release.env" -f "$release/compose.yaml" down || true
      echo 'First deployment failed; no previous application release exists' >&2
    fi
  fi
  rmdir "$lock" || true
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
cd "$release"
test -s backend
test -s web/index.html
test -r "$root/shared/config.yaml"
# 使用用户上传的配置，监听端口必须与容器代理一致，错误时在更新前停止。
grep -Eq '^listen_addr:[[:space:]]*"?:20000"?([[:space:]]|$)' "$root/shared/config.yaml" || { echo 'Config must listen on :20000' >&2; exit 1; }
mkdir -p "$root/shared/data" "$root/shared/log" "$root/backups"
chown 10001:10001 "$root/shared/data" "$root/shared/log"
chmod 700 "$root/backups"
printf 'RELEASE_ID=%s\nPA_SHARED_DIR=%s/shared\nWEB_BIND_ADDRESS=192.168.31.3\n' "$release_id" "$root" > release.env
docker compose --env-file release.env -f compose.yaml config --quiet
# Mac 已完成编译；服务器只把成品放进运行镜像，无需 Go 或 Node。
docker build -f backend.runtime.Dockerfile -t "personal-assistant-backend:$release_id" .
docker build -f web.runtime.Dockerfile -t "personal-assistant-web:$release_id" .
# 启动会自动迁移表结构，先保存一致性逻辑备份；不把密码或业务内容打印到日志。
umask 077
backup="$root/backups/personal_assistant-$release_id.sql"
docker exec mysql8 sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mysqldump -uroot --single-transaction --routines --triggers --events --hex-blob --no-tablespaces --set-gtid-purged=OFF personal_assistant' > "$backup"
test -s "$backup"
activated=true
docker compose --env-file release.env -f compose.yaml up -d --no-build --pull never --wait --wait-timeout 180
curl -fsS --retry 3 --max-time 10 http://192.168.31.3:10000/ >/dev/null
curl -fsS --retry 3 --max-time 10 http://192.168.31.3:10000/api/health >/dev/null
if [ -n "$previous" ]; then ln -sfn "$previous" "$root/previous"; fi
ln -sfn "$release" "$root/current"
echo "Deployed $release_id at http://192.168.31.3:10000"
