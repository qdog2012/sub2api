#!/usr/bin/env bash
# =============================================================================
# 在服务器上更新到「最新版本」的程序
# =============================================================================
# 用法（把镜像 tar 包和本脚本放到服务器同一目录）：
#   bash update.sh sub2api-custom-0.2.23.tar.gz
#
# 做的事：
#   1. 载入新镜像（docker load）
#   2. 用同一个 compose 文件重建容器（数据卷保持不变）
#   3. 等待健康检查通过，失败则回滚到上一个镜像
# =============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/sub2api}"
COMPOSE_FILE="${COMPOSE_FILE:-${APP_DIR}/docker-compose.custom.yml}"
IMAGE="${IMAGE:-sub2api-custom:latest}"
TARBALL="${1:-}"

cd "$APP_DIR"

if [ -z "$TARBALL" ]; then
  echo "用法: bash update.sh <镜像tar.gz>" >&2
  exit 1
fi

# ---- 备份当前镜像 ID，便于回滚 ----
OLD_IMAGE_ID="$(docker image inspect "$IMAGE" -f '{{.Id}}' 2>/dev/null || true)"
echo ">>> 当前镜像: ${OLD_IMAGE_ID:-<none>}"

# ---- 载入新镜像 ----
echo ">>> 载入新镜像: $TARBALL"
case "$TARBALL" in
  *.gz) gunzip -c "$TARBALL" | docker load ;;
  *)    docker load -i "$TARBALL" ;;
esac

# ---- 重建容器（命名卷保留数据）----
echo ">>> 重建容器"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps sub2api

# ---- 等待健康 ----
echo ">>> 等待健康检查（最多 180s）"
for i in $(seq 1 36); do
  STATUS="$(docker inspect -f '{{.State.Health.Status}}' sub2api 2>/dev/null || echo unknown)"
  case "$STATUS" in
    healthy)
      echo ">>> 更新成功，服务运行中"
      docker compose -f "$COMPOSE_FILE" ps sub2api
      exit 0
      ;;
    unhealthy)
      echo "!!! 容器 unhealthy，回滚" >&2
      break
      ;;
  esac
  sleep 5
done

# ---- 回滚 ----
echo ">>> 健康检查未通过，查看最近日志：" >&2
docker logs --tail 80 sub2api >&2 || true

if [ -n "$OLD_IMAGE_ID" ]; then
  echo ">>> 回滚到旧镜像 ${OLD_IMAGE_ID}" >&2
  docker tag "$OLD_IMAGE_ID" "$IMAGE"
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps sub2api
fi
exit 1