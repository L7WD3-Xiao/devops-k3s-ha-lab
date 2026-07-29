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

## 5. 实施步骤（5 步）

> 执行顺序严格按依赖关系排列：先配构建工具，再构建镜像、推送至 ACR，最后部署到集群并验证。

```
Step 1: 构建脚本 ──────────► build-push.sh 就绪（docker / nerdctl 自动检测）
    │                       环境变量 + 交互式密码
    ▼
Step 2: Dockerfile ────────► 多阶段构建 + build-push.sh 自动构建
    │                       （nerdctl 模式自动生成 Dockerfile.daocloud）
    ▼
Step 3: 推送至 ACR ────────► build-push.sh 内置推送 → 公网推 / VPC 拉
    │
    ▼
Step 4: K8s 资源部署 ──────► Namespace → ConfigMap → Secret → Deployment → Ingress → HPA
    │
    ▼
Step 5: 端到端验证 ────────► Pod 状态 → 健康检查 → API 功能 → 短链跳转
```

---

### Step 1: 配置构建推送脚本

**目标**：配置 `build-push.sh` 脚本，支持一键构建并推送镜像到 ACR。

**涉及文件**：

| 文件 | 说明 |
|------|------|
| `scripts/build-push.sh` | 构建推送脚本（本地 docker 或节点 nerdctl 双模式） |

**脚本工作流程**：

```
build-push.sh v1
    │
    ├─ 1. 自动检测工具：docker（本地）或 nerdctl（节点）
    │
    ├─ 2. nerdctl 模式自动生成 Dockerfile.daocloud
    │   （sed 替换 FROM golang: → docker.m.daocloud.io/library/golang:）
    │
    ├─ 3. 登录 ACR（公网域名，交互式输入密码）
    │
    ├─ 4. 构建镜像（含 --no-cache 选项）
    │
    ├─ 5. 推送镜像到 ACR
    │
    └─ 6. 输出 K3s 部署用的 VPC 域名镜像地址
```

**环境变量配置**（脚本已含脱敏默认值，可按需覆盖）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ACR_REGISTRY` | `crpi-...-vpc....` | VPC 域名，K3s 拉取用 |
| `ACR_REGISTRY_PUBLIC` | `crpi-...` | 公网域名，推送用 |
| `ACR_NAMESPACE` | `shortlink123` | ACR 命名空间 |
| `ACR_REPOSITORY` | `shortlink-app` | 镜像仓库名 |
| `ACR_USERNAME` | `L7WD3-Xiao` | ACR 登录用户名 |

> ⚠️ 密码不保存在脚本或环境变量中——每次执行 `build-push.sh` 时**交互式输入**（docker/nerdctl login 均弹出密码提示）。
> `ACR_USERNAME` 的默认值已脱敏，使用真实值即可。

**验证**：

> 如果开发机有 Docker Desktop 或 Docker 环境，就在本地验证，没有可以跳过

```bash
# 本地 Docker login 测试（交互式输入密码）
docker login crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com
# 输入密码后应显示 Login Succeeded
```

---

### Step 2: 构建应用镜像

**目标**：编写多阶段 Dockerfile，构建短链服务镜像。

`build-push.sh` 已封装构建流程——只需确保 Dockerfile 正确，然后执行 `./scripts/build-push.sh v1` 即可一键构建+推送。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `Dockerfile` | 新建 | 多阶段构建（golang:1.22-alpine → alpine:3.20） |
| `.dockerignore` | 新建 | 构建上下文排除 |

**多阶段 Dockerfile**：

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

- 静态编译（CGO_ENABLED=0），最终镜像 ~7.5MB
- 非 root 用户运行（UID 10001）
- 包含 ca-certificates（HTTPS 重定向需要）+ tzdata

**关于 `Dockerfile.daocloud`**：在 node-01 上使用时，`build-push.sh` 自动通过 `sed` 将 `FROM golang:` 和 `FROM alpine:` 替换为 daocloud 镜像源版本，生成临时的 `Dockerfile.daocloud`，构建完成后自动清理。本地 Docker 环境可直接使用 `Dockerfile`（无此需要，因为 Docker Desktop 可直连 Docker Hub）。

**构建环境细节（仅在手动调试时需要）**：

| 项 | 配置 |
|----|------|
| 构建工具 | nerdctl 1.7.7 + buildkitd（OCI worker） |
| containerd socket | `/run/k3s/containerd/containerd.sock` |
| 基础镜像源 | `docker.m.daocloud.io/library/`（国内可用） |
| Go 模块代理 | `goproxy.cn`（无需 VPN） |

**踩坑记录**：

| 问题 | 原因 | 修复 |
|------|------|------|
| `go.sum` 缺失 | `go mod download` 未生成完整 `go.sum` | Dockerfile 中 build 前加 `go mod tidy` |
| buildkitd HTTP_PROXY 干扰 daocloud | 代理不稳定导致国内镜像源拉取失败 | 移除 buildkitd 的 HTTP_PROXY 配置 |
| Docker Hub auth.docker.io 被墙 | 认证域名被墙，拉取失败 | Dockerfile 直接使用 `docker.m.daocloud.io/library/` 绕过 Docker Hub |

**验证**：
```bash
# 确认 Dockerfile 语法正确
docker build -f Dockerfile . --no-op 2>/dev/null || echo "Syntax check not available; use build-push.sh as next step"

# 用 build-push.sh 一键构建+推送
./scripts/build-push.sh v1
```

---

### Step 3: 推送镜像至 ACR

**目标**：将构建好的镜像推送到 ACR，使 K3s 集群能通过 VPC 域名拉取。

`build-push.sh` 已内置登录+推送逻辑，执行 `./scripts/build-push.sh v1` 即自动完成。完成后脚本会输出 K3s 部署用的 VPC 域名镜像地址。

**镜像地址对照**：

| 场景 | 域名格式 | 示例 |
|------|---------|------|
| 推送（公网） | `crpi-{id}.{region}.personal.cr.aliyuncs.com` | `crpi-....cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1` |
| 拉取（VPC） | `crpi-{id}-vpc.{region}.personal.cr.aliyuncs.com` | `crpi-...-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1` |

> - 两个域名指向 ACR 中的同一份镜像 manifest，推送到公网域名后，VPC 域名立即可见
> - K3s registries.yaml 已配置 VPC 域名认证，全局免 imagePullSecret

**验证**：
```bash
# build-push.sh 执行成功后，确认 ACR 控制台镜像仓库中出现 v1 标签
# 或查看脚本输出的 Summary 确认无报错
```

---

### Step 4: 部署 K8s 资源

**目标**：将短链服务的 K8s 清单部署到集群，使应用在 app-layer namespace 中运行。

**涉及文件**：

| 文件 | 说明 |
|------|------|
| `k8s/app-layer/namespace.yaml` | app-layer namespace |
| `k8s/app-layer/configmap.yaml` | 非敏感配置（MySQL/Redis 连接信息） |
| `k8s/app-layer/secret.yaml` | MySQL 密码 Secret（已 gitignore） |
| `k8s/app-layer/shortlink.yaml` | Deployment（2 副本 + 反亲和）+ Service（:8080） |
| `k8s/app-layer/ingress.yaml` | Traefik Ingress（:80 → :8080） |
| `k8s/app-layer/hpa.yaml` | HPA（2-6 副本，CPU 70%）+ PDB（minAvailable 1） |

**部署命令**（本机无 kubectl，通过 SSH 提交）：
```bash
cat k8s/app-layer/*.yaml | ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl apply -f -"
```

**资源创建顺序**（kubectl apply 自动按依赖顺序处理）：
1. Namespace（app-layer）
2. ConfigMap（MySQL/Redis 连接配置）
3. Secret（MySQL 密码）
4. Deployment（2 副本 + 反亲和）+ Service（:8080）
5. Ingress（Traefik :80 → :8080）
6. HPA（2-6, CPU 70%）+ PDB（minAvailable 1）

**验证**：
```bash
# 检查 Pod 状态
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get pods -n app-layer -o wide"

# 确认 Deployment 已就绪（2/2 READY）
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl rollout status deploy/shortlink -n app-layer"

# 确认 Service 和 Endpoints
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get svc,ep -n app-layer"

# 确认 Ingress
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get ingress -n app-layer"

# 确认 HPA
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get hpa -n app-layer"
```

---

### Step 5: 端到端验证

**目标**：从集群外部验证短链服务的完整功能链路。

**验证步骤**：

```bash
# 1. 健康检查
curl -s http://<集群公网入口IP>/health
# → {"status":"ok"}

# 2. 创建短链
curl -s -X POST http://<集群公网入口IP>/api/shorten \
  -H 'Content-Type: application/json' \
  -d '{"url": "https://kubernetes.io"}'
# → {"short_code":"6","short_url":"http://<集群公网入口IP>/6"}

# 3. 短链跳转（用 GET 模拟浏览器访问）
curl -v http://<集群公网入口IP>/6
# → HTTP/1.1 301 Moved Permanently
# → Location: https://kubernetes.io
```

**验证指标**：

| 检查项 | 预期结果 | 验证命令 |
|--------|---------|---------|
| Pod 状态 | 2/2 Running（分布在 node-02 + node-03，反亲和生效） | `kubectl get pods -n app-layer -o wide` |
| 镜像拉取 | VPC 域名 < 2s 完成（~7.5MB） | `kubectl describe pod -n app-layer` → Events |
| 健康检查 | `200 OK` + `{"status":"ok"}` | `curl <IP>/health` |
| 创建短链 | `201 Created` + `short_code` 返回 | `curl -X POST <IP>/api/shorten` |
| 短链跳转 | `301 Moved` + `Location` 头 | `curl -v <IP>/<code>` |
| HPA | cpu 2%/70%，2 replicas | `kubectl get hpa -n app-layer` |
| Ingress | 3 节点 IP 均可访问 port 80 | `curl http://<node-ip>` |

**安全合规确认**：
- MySQL 密码通过 K8s Secret 注入，不硬编码在镜像中
- `secret.yaml` 已加入 `.gitignore`，仅 `secret.yaml.example` 入库
- 容器以非 root 用户（UID 10001）运行，SecurityContext 与 Dockerfile USER 一致
- ConfigMap 只包含非敏感信息，敏感信息全部走 Secret
