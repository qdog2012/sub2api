#!/usr/bin/env bash
# =============================================================================
# 编译当前分支（前端 + 后端）并打包成 Docker 镜像
# =============================================================================
# 在仓库根目录执行：  bash deploy/build-custom.sh
#
# 环境要求：node >= 20、pnpm 9（corepack 自动提供）、go >= 1.27.4、docker
# 产物：      Docker 镜像 sub2api-custom:latest + sub2api-custom:<版本号>
#             以及 backend/bin/server-linux-amd64（可直接拷到服务器复用）
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

IMAGE_NAME="${IMAGE_NAME:-sub2api-custom}"
TARGET_PLATFORM="${TARGET_PLATFORM:-linux/amd64}"
GOARCH_VALUE="${TARGET_PLATFORM#linux/}"

# ---- 版本号：git tag 优先，否则读 backend/cmd/server/VERSION ----
VERSION="$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
if [ -z "$VERSION" ]; then
  VERSION="$(tr -d '\r\n' < backend/cmd/server/VERSION)"
fi
COMMIT="$(git rev-parse --short HEAD)"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo ">>> 构建 ${IMAGE_NAME}  version=${VERSION}  commit=${COMMIT}  arch=${GOARCH_VALUE}"

# ---- 1. 前端 ----
echo ">>> [1/4] 安装前端依赖"
if command -v pnpm >/dev/null 2>&1; then
  PNPM=pnpm
else
  corepack enable >/dev/null 2>&1 || true
  PNPM="corepack pnpm"
fi
$PNPM --dir frontend install --frozen-lockfile

echo ">>> [2/4] 构建前端 -> backend/internal/web/dist"
$PNPM --dir frontend run build

# ---- 2. 后端（前端已嵌入二进制）----
echo ">>> [3/4] 编译后端（${TARGET_PLATFORM}）"
(
  cd backend
  CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH_VALUE}" \
  GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" \
  GOSUMDB="${GOSUMDB:-sum.golang.google.cn}" \
  go build -tags embed -trimpath \
    -ldflags="-s -w -X main.Version=${VERSION} -X main.Commit=${COMMIT} -X main.Date=${DATE} -X main.BuildType=release" \
    -o bin/server-linux-amd64 ./cmd/server
)
ls -lh backend/bin/server-linux-amd64

# ---- 3. 打包镜像 ----
echo ">>> [4/4] 打包 Docker 镜像"
docker build \
  --platform "${TARGET_PLATFORM}" \
  -f deploy/Dockerfile.custom \
  -t "${IMAGE_NAME}:latest" \
  -t "${IMAGE_NAME}:${VERSION}" \
  .

echo
echo "完成："
docker images "${IMAGE_NAME}" --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'