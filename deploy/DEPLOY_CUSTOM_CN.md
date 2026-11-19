# 自定义分支部署指南（my-main → Docker）

本文档说明如何把本仓库 `my-main` 分支的代码编译并部署到 Linux 服务器，以及后续如何更新到最新版本。

---

## 一、整体思路

```
你的电脑 (Windows/WSL)                     Linux 服务器
┌──────────────────────────┐              ┌──────────────────────┐
│ git pull (my-main)       │              │                      │
│   ↓                      │              │  docker load         │
│ 编译前端 (vite)          │  镜像 tar    │   ↓                  │
│   ↓                      │  ──────────► │  docker compose up   │
│ 编译后端 (Go+embed)      │   传输       │   ↓                  │
│   ↓                      │              │  sub2api + PG + Redis│
│ docker build → 镜像      │              │                      │
│   ↓                      │              │                      │
│ docker save → tar.gz     │              │                      │
└──────────────────────────┘              └──────────────────────┘
```

**关键点**：前端已被 `-tags embed` 编译进 Go 二进制，所以镜像里只需要一个可执行文件，不需要 Node 运行时。编译在你本地做，服务器只负责跑。

---

## 二、本地编译

### 2.1 环境要求

| 工具 | 版本 | 说明 |
| --- | --- | --- |
| Go | ≥ 1.27.4 | 与 `backend/go.mod` 一致，低版本会自动下载工具链 |
| Node.js | ≥ 20 | 推荐 24 |
| pnpm | 9.15.9 | 与 Dockerfile 固定版本一致，用 `corepack prepare pnpm@9.15.9 --activate` |
| Docker | 任意较新版本 | 仅用于打包镜像 |

Windows 上如果没装 Docker Desktop，可以在 WSL 里用 docker。

### 2.2 一键编译

**在 WSL / Linux 里**（推荐，脚本是 bash）：

```bash
cd /path/to/sub2api
bash deploy/build-custom.sh
```

这会依次完成：装前端依赖 → 构建前端 → 编译后端（嵌入前端）→ 打包镜像 `sub2api-custom:latest`。

**在 Windows PowerShell 里**手动执行等价步骤：

```powershell
# 1) 前端依赖（首次或 lockfile 变更后）
corepack prepare pnpm@9.15.9 --activate
pnpm --dir frontend install --frozen-lockfile

# 2) 构建前端 -> backend/internal/web/dist
pnpm --dir frontend run build

# 3) 编译后端（关键：-tags embed 把前端打进去）
cd backend
$env:CGO_ENABLED="0"; $env:GOOS="linux"; $env:GOARCH="amd64"
$env:GOPROXY="https://goproxy.cn,direct"
$env:GOSUMDB="sum.golang.google.cn"
go build -tags embed -trimpath `
  -ldflags="-s -w -X main.Version=0.2.23 -X main.Commit=my-main -X main.BuildType=release" `
  -o bin/server-linux-amd64 ./cmd/server
cd ..
```

> ⚠️ **必须指定 `GOARCH=amd64`**。本机 Go 默认是 `windows/386`，32 位下 `int` 溢出会导致 `gemini_oauth_service.go` 编译报错。
> ⚠️ **必须带 `-tags embed`**，否则二进制不会嵌入前端页面。

### 2.3 验证产物

```powershell
# Windows 上确认是 Linux ELF
$b = [System.IO.File]::ReadAllBytes("backend/bin/server-linux-amd64")[0..3]
$b -join ','   # 应为 127,69,76,70
```

```bash
# WSL/服务器上直接跑，应输出版本日志
./backend/bin/server-linux-amd64 --version
# Sub2API 0.2.23 (commit: my-main, built: ...)
```

---

## 三、打包与传输

### 3.1 打包镜像

```bash
docker build --platform linux/amd64 -f deploy/Dockerfile.custom \
  -t sub2api-custom:latest -t sub2api-custom:0.2.23 .
```

### 3.2 导出并压缩

```bash
docker save sub2api-custom:latest sub2api-custom:0.2.23 | gzip -1 > sub2api-custom-0.2.23.tar.gz
ls -lh sub2api-custom-0.2.23.tar.gz     # 约 80–120 MB
```

### 3.3 传到服务器

```bash
scp sub2api-custom-0.2.23.tar.gz user@your-server:/tmp/
```

---

## 四、服务器首次部署

### 4.1 准备目录

```bash
sudo mkdir -p /opt/sub2api
sudo chown "$USER":"$USER" /opt/sub2api
cd /opt/sub2api
```

把仓库里这三个文件拷到 `/opt/sub2api`：

- `deploy/docker-compose.custom.yml`
- `deploy/update-custom.sh`
- 镜像 tar 包（放 `/tmp` 或本目录都行）

> 服务器上**不需要**整个源码仓库，只要有 compose 文件即可。

### 4.2 生成配置文件

```bash
cd /opt/sub2api
cat > .env <<EOF
# ---- 必填 ----
POSTGRES_PASSWORD=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
TOTP_ENCRYPTION_KEY=$(openssl rand -hex 32)

# ---- 管理员账号（首次启动自动创建）----
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=$(openssl rand -base64 12)

# ---- 端口与网络 ----
SERVER_PORT=8080
BIND_HOST=0.0.0.0
TZ=Asia/Shanghai

# ---- 数据库 ----
POSTGRES_USER=sub2api
POSTGRES_DB=sub2api

# ---- Redis（留空则不设密码；建议设置）----
REDIS_PASSWORD=$(openssl rand -hex 16)
EOF
chmod 600 .env
```

> 🔐 **`JWT_SECRET` 和 `TOTP_ENCRYPTION_KEY` 必须固定**。留空的话每次重启会随机生成，导致所有人被登出、2FA 全部失效。

记下 `ADMIN_PASSWORD`，首次登录要用：

```bash
grep ADMIN_PASSWORD .env
```

### 4.3 载入镜像并启动

```bash
cd /opt/sub2api
docker load -i /tmp/sub2api-custom-0.2.23.tar.gz

# 前台先跑一次，方便看首次初始化日志
docker compose -f docker-compose.custom.yml up -d
docker compose -f docker-compose.custom.yml logs -f sub2api
```

首次启动会自动建表、跑完 305 个迁移脚本，大约 1–3 分钟。看到健康检查变 healthy 即可：

```bash
docker compose -f docker-compose.custom.yml ps
# sub2api 应为 (healthy)
```

### 4.4 访问

浏览器打开 `http://你的服务器IP:8080`，用 `.env` 里的 `ADMIN_EMAIL` / `ADMIN_PASSWORD` 登录。

---

## 五、更新到最新版本（日常运维）

### 5.1 完整流程

```bash
# ---- 本地 ----
git fetch upstream && git switch my-main && git merge upstream/main   # 合上游（可选）
git push
bash deploy/build-custom.sh                                          # 重新编译

VERSION=$(tr -d '\r\n' < backend/cmd/server/VERSION)
docker save sub2api-custom:latest | gzip -1 > "sub2api-custom-${VERSION}.tar.gz"
scp "sub2api-custom-${VERSION}.tar.gz" user@your-server:/opt/sub2api/
```

```bash
# ---- 服务器 ----
cd /opt/sub2api
bash update-custom.sh "sub2api-custom-${VERSION}.tar.gz"
```

`update-custom.sh` 会：载入新镜像 → 重建容器（**数据卷保留，不丢数据**）→ 等健康检查 → 失败自动回滚旧镜像并打印日志。

### 5.2 手动更新（等价操作）

```bash
cd /opt/sub2api
docker load -i sub2api-custom-0.2.24.tar.gz
docker compose -f docker-compose.custom.yml up -d --force-recreate --no-deps sub2api
docker compose -f docker-compose.custom.yml logs -f sub2api
```

> 只重建 `sub2api` 服务（`--no-deps`），PostgreSQL 和 Redis 容器不会重启，数据不动。

### 5.3 数据库迁移

程序启动时会自动执行 `backend/migrations/*.sql`（已嵌入二进制）。**升级前建议先备份**：

```bash
cd /opt/sub2api
docker exec sub2api-postgres pg_dump -U sub2api sub2api \
  | gzip > "backup-$(date +%F-%H%M).sql.gz"
```

回滚程序时注意：如果新版本已执行过迁移，旧版本可能不兼容新的表结构，必要时连数据一起回滚。

---

## 六、常用运维命令

```bash
cd /opt/sub2api
C="docker compose -f docker-compose.custom.yml"

$C ps                      # 状态
$C logs -f sub2api         # 实时日志
$C restart sub2api         # 重启应用
$C down                    # 停止（保留数据卷）
$C down -v                 # ⚠️ 停止并删除数据卷（数据全丢）

docker stats sub2api       # 资源占用
docker exec -it sub2api sh # 进容器
```

配置文件在容器内 `/app/data/config.yaml`，映射到命名卷 `sub2api_data`：

```bash
# 查看自动生成的配置
docker run --rm -v sub2api_sub2api_data:/d alpine cat /d/config.yaml | head -40
```

---

## 七、常见问题

**Q：启动报数据库连不上？**
PostgreSQL 初始化需要几十秒。程序内置重试，等 `start_period: 120s` 过去。若仍失败，看 `$C logs postgres`。

**Q：端口被占用？**
改 `.env` 里的 `SERVER_PORT`（改宿主机端口，容器内仍是 8080）。

**Q：想改端口/域名，用 Nginx 反代？**

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # SSE / 流式响应必需
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

**Q：镜像太大？**
`-ldflags="-s -w"` 已去掉符号表。想更小可以用 `upx`，但不建议用于服务端。

**Q：怎么确认跑的是我的分支代码？**
```bash
docker exec sub2api /app/sub2api --version
# 应显示 commit: my-main
```

**Q：服务器拉不到 Docker Hub 镜像？**
compose 里的 `postgres:18-alpine`、`redis:8-alpine`、`alpine:3.21` 需要能拉取。若无外网，先在能上网的机器 `docker pull` 后 `docker save`，一并传过去再 `docker load`。

---

## 八、相关文件

| 文件 | 用途 |
| --- | --- |
| `deploy/Dockerfile.custom` | 打包预编译二进制成镜像（不编译） |
| `deploy/docker-compose.custom.yml` | 服务器端编排：app + PG + Redis |
| `deploy/build-custom.sh` | 本地一键：编译 + 打包镜像 |
| `deploy/update-custom.sh` | 服务器端：载入镜像 + 重建容器 + 失败回滚 |