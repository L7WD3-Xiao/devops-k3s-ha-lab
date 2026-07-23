# Phase 4：短链服务应用部署

## 1. 概述

在 K3s 集群上部署 Go 编写的短链服务，连接 Phase 3 的数据层（MySQL via ProxySQL + Redis via Sentinel），通过 Ingress 对外暴露。

**状态：已完成 (2026-07-22)**

## 2. 架构

```
                        External Traffic
                              │
                    ┌─────────▼─────────┐
                    │  Traefik Ingress   │  (K3s 内置, :80)
                    └─────────┬─────────┘
                              │
                    ┌─────────▼─────────┐
                    │  shortlink Service │  (app-layer, :8080)
                    │  2 replicas + HPA  │
                    └────┬────────┬──────┘
                         │        │
          ┌──────────────▼──┐  ┌──▼───────────────────┐
          │  ProxySQL:6033   │  │  Sentinel:26379       │
          │  (data-layer)    │  │  (data-layer)         │
          │  读写分离          │  │  Redis Master 发现     │
          └────┬────────┬────┘  └──────────┬────────────┘
               │        │                  │
        ┌──────▼──┐  ┌──▼──────┐    ┌──────▼──────┐
        │ MySQL   │  │ MySQL   │    │ Redis HA    │
        │ Master  │  │ Slave   │    │ 1M + 2S     │
        │ (node02)│  │ (node03)│    │ + 3 Sentinel│
        └─────────┘  └─────────┘    └─────────────┘
```

## 3. 文件结构

```
app/
  main.go              Go 短链服务源码 (Gin + MySQL + Redis, 358 行)
  go.mod               Go module 依赖
Dockerfile             多阶段构建 (golang:1.22-alpine → alpine:3.20)
.dockerignore          构建上下文排除
k8s/app-layer/
  namespace.yaml       app-layer namespace
  configmap.yaml       非敏感配置 (MySQL/Redis 连接信息)
  secret.yaml.example  MySQL 密码 Secret 模板 (真实文件 gitignored)
  secret.yaml          真实密码 (gitignored)
  shortlink.yaml       Deployment (2 副本) + Service
  ingress.yaml         Traefik Ingress (:80 → :8080)
  hpa.yaml             HPA (2-6 副本, CPU 70%) + PDB
scripts/
  build-push.sh        构建推送脚本 (支持 docker / nerdctl)
```

## 4. 应用设计

### 4.1 API

| Method | Path | 功能 |
|--------|------|------|
| POST | `/api/shorten` | 创建短链 `{"url": "https://..."} → {"short_code": "dX7vQ"}` |
| GET | `/:code` | 301 重定向到原始 URL |
| GET | `/health` | 健康检查 (Liveness/Readiness Probe) |

### 4.2 短码生成

- **策略**：INSERT 获取自增 ID → Base62 编码 → UPDATE 写入 short_code
- **优点**：无碰撞、确定性、展示 ProxySQL 读写分离
- **字符集**：`0-9 a-z A-Z` (62 字符)
- **容量**：6 位 ≈ 568 亿组合

### 4.3 数据流

**写路径 (POST /api/shorten)**:
1. INSERT url_mapping → ProxySQL → MySQL Master (hostgroup 1)
2. 获取自增 ID → Base62 编码
3. UPDATE short_code → ProxySQL → MySQL Master (hostgroup 1)
4. SET Redis 缓存 (TTL 24h) → Sentinel → Redis Master

**读路径 (GET /:code)**:
1. GET Redis 缓存 → 命中则直接 301 重定向
2. 缓存未命中 → SELECT → ProxySQL → MySQL Slave (hostgroup 2)
3. 回填 Redis 缓存 → 301 重定向

### 4.4 优雅关闭

- 监听 SIGTERM 信号
- 5 秒超时优雅关闭 HTTP Server
- preStop hook + terminationGracePeriodSeconds=15

## 5. 镜像构建

### 5.1 工具：nerdctl + BuildKit (在 node-01 上)

由于本地无 Docker，且 K3s 节点上也没有 Docker，在 node-01 上使用 nerdctl (Docker 兼容 CLI) + BuildKit 构建镜像。

**关键配置**：
- nerdctl 1.7.7 + buildkitd (OCI worker 模式)
- buildkitd 使用 K3s 的 containerd socket (`/run/k3s/containerd/containerd.sock`)
- 基础镜像通过 daocloud 镜像源拉取 (`docker.m.daocloud.io/library/`)
- Go 模块通过 goproxy.cn 下载（无需代理）

### 5.2 多阶段 Dockerfile

```dockerfile
# Build stage
FROM docker.m.daocloud.io/library/golang:1.22-alpine AS builder
WORKDIR /build
COPY app/go.mod ./
ENV GOPROXY=https://goproxy.cn
RUN go mod download
COPY app/ .
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o shortlink .

# Runtime stage
FROM docker.m.daocloud.io/library/alpine:3.20
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /app
COPY --from=builder /build/shortlink .
EXPOSE 8080
RUN adduser -D -u 10001 appuser
USER appuser
CMD ["./shortlink"]
```

- 静态编译 (CGO_ENABLED=0)，最终镜像 ~7.5MB
- 非 root 用户运行 (UID 10001)
- 包含 ca-certificates (HTTPS 重定向需要) + tzdata

### 5.3 构建命令

```bash
# 在 node-01 上执行
sudo -E env "PATH=/usr/local/bin:/usr/bin:/bin" \
     CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock \
     CONTAINERD_NAMESPACE=k8s.io \
     BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock \
     /usr/local/bin/nerdctl build \
     -t crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1 \
     -f Dockerfile.daocloud .

# 登录 ACR (公网域名)
nerdctl login crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com

# 推送
nerdctl push crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1
```

### 5.4 踩坑记录

1. **go.sum 缺失**：`go mod download` 下载了模块但未生成完整 `go.sum`，导致 `go build` 报 `missing go.sum entry`。
   - 修复：在 Dockerfile 中 `go build` 前加 `go mod tidy`

2. **buildkitd HTTP_PROXY 干扰 daocloud**：buildkitd 服务配置了 HTTP_PROXY 指向 SSH 隧道 (127.0.0.1:8888)，但隧道不稳定时会导致 daocloud 镜像源拉取失败。
   - 修复：移除 buildkitd 的 HTTP_PROXY 配置。daocloud 和 goproxy.cn 都是国内的，不需要代理。

3. **Docker Hub auth.docker.io 被墙**：buildkitd 拉取 Docker Hub 镜像时需要访问 auth.docker.io 认证，该域名被墙。
   - 修复：Dockerfile 中直接使用 `docker.m.daocloud.io/library/` 镜像 URL 绕过 Docker Hub 认证。

## 6. K8s 部署

### 6.1 部署顺序

```bash
# 通过 SSH 在 node-01 上执行 (本机无 kubectl)
cat k8s/app-layer/*.yaml | ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl apply -f -"
```

资源创建顺序：
1. Namespace (app-layer)
2. ConfigMap (MySQL/Redis 连接配置)
3. Secret (MySQL 密码)
4. Deployment (2 副本 + 反亲和) + Service (:8080)
5. Ingress (Traefik :80 → :8080)
6. HPA (2-6, CPU 70%) + PDB (minAvailable 1)

### 6.2 验证结果

| 项目 | 结果 |
|------|------|
| Pod 状态 | 2/2 Running, 分布在 node-02 + node-03 (反亲和生效) |
| 镜像拉取 | VPC 域名 1.77s 拉取完成 (7.5MB) |
| 健康检查 | `GET /health` → `{"status":"ok"}` |
| 创建短链 | `POST /api/shorten` → `{"short_code":"6","short_url":"http://<集群公网入口IP>/6"}` |
| 短链跳转 | `GET /6` → 301 → `https://kubernetes.io` |
| HPA | cpu 2%/70%, 2 replicas (metrics-server 正常) |
| Ingress | Traefik, 3 节点 IP, port 80 |

### 6.3 外部访问测试

```bash
# 健康检查
curl http://<集群公网入口IP>/health
# → {"status":"ok"}

# 创建短链
curl -X POST http://<集群公网入口IP>/api/shorten \
  -H 'Content-Type: application/json' \
  -d '{"url": "https://kubernetes.io"}'
# → {"short_code":"6","short_url":"http://<集群公网入口IP>/6"}

# 短链跳转 (注意：用 GET 不是 HEAD)
curl -v http://<集群公网入口IP>/6
# → HTTP/1.1 301 Moved Permanently
# → Location: https://kubernetes.io
```

## 7. ACR 镜像地址

- **推送 (公网)**：`crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1`
- **拉取 (VPC)**：`crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1`

K3s registries.yaml 已配置 VPC 域名认证，全局免 imagePullSecret。

## 8. 安全注意事项

- MySQL 密码通过 K8s Secret 注入，不硬编码在镜像中
- `secret.yaml` 已加入 `.gitignore`，仅 `secret.yaml.example` 入库
- 容器以非 root 用户 (UID 10001) 运行
- ConfigMap 只包含非敏感信息，敏感信息全部走 Secret

## 9. 下一步

- Phase 5：CI/CD (FluxCD GitOps) — Git push 自动触发构建和部署
- Phase 6：安全加固 (RBAC + NetworkPolicy + Trivy)
- Phase 7：备份容灾 (Velero + xtrabackup)
