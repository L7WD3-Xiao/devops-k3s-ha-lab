# Phase 4：短链服务应用部署 — 已完成

## 完成内容

### 1. Go 短链服务应用 (app/main.go, 358 行)
- Gin 框架，3 个 API 端点：POST /api/shorten, GET /:code (301 重定向), GET /health
- Base62 短码编码 (INSERT 自增 ID → Base62 → UPDATE)
- MySQL via ProxySQL (读写分离透明), Redis via Sentinel (自动故障切换)
- 优雅关闭 (SIGTERM + 5s timeout + preStop hook)

### 2. 多阶段 Dockerfile 构建
- golang:1.22-alpine (构建) → alpine:3.20 (运行), 静态编译 CGO_ENABLED=0
- 最终镜像 ~7.5MB, 非 root 用户 (UID 10001)
- 在 node-01 上用 nerdctl + buildkitd 构建 (无 Docker 环境)
- daocloud 镜像源 + goproxy.cn (国内直连, 无需代理)

### 3. ACR 镜像推送
- 公网域名推送: `crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com`
- VPC 域名拉取: `crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com`
- K3s registries.yaml 全局认证, 免 imagePullSecret

### 4. K8s 应用层部署 (6 个 manifests)
- Namespace + ConfigMap + Secret + Deployment(2 副本) + Service + Ingress + HPA + PDB
- podAntiAffinity 跨节点分布 (node-02 + node-03)
- HPA: 2-6 副本, CPU 70%; PDB: minAvailable 1
- Traefik Ingress: :80 → shortlink:8080

### 5. 功能验证
- 健康检查: `GET /health` → `{"status":"ok"}`
- 创建短链: `POST /api/shorten` → `{"short_code":"6"}`
- 短链跳转: `GET /6` → 301 → `https://kubernetes.io`
- 集群全 Pod Running (app-layer 2 + data-layer 8 + kube-system 9)

## 踩坑记录

| 问题 | 原因 | 修复 |
|------|------|------|
| go build 报 missing go.sum | go mod download 未生成完整 go.sum | Dockerfile 加 `go mod tidy` |
| buildkitd 拉取 daocloud 失败 | HTTP_PROXY 指向已断开的 SSH 隧道 | 移除 buildkitd 的 HTTP_PROXY (daocloud 国内直连) |
| Docker Hub auth.docker.io 超时 | auth.docker.io 被墙 | Dockerfile 用 daocloud 镜像 URL 绕过 |

## 新增/修改文件

| 文件 | 说明 |
|------|------|
| `app/main.go` | Go 短链服务源码 (358 行) |
| `app/go.mod` | Go module 依赖 |
| `Dockerfile` | 多阶段构建 (daocloud mirror + goproxy.cn + go mod tidy) |
| `.dockerignore` | 构建上下文排除 |
| `k8s/app-layer/namespace.yaml` | app-layer namespace |
| `k8s/app-layer/configmap.yaml` | MySQL/Redis 连接配置 |
| `k8s/app-layer/secret.yaml.example` | MySQL 密码 Secret 脱敏模板 |
| `k8s/app-layer/secret.yaml` | 真实密码 (gitignored) |
| `k8s/app-layer/shortlink.yaml` | Deployment(2 副本) + Service |
| `k8s/app-layer/ingress.yaml` | Traefik Ingress |
| `k8s/app-layer/hpa.yaml` | HPA + PDB |
| `scripts/build-push.sh` | 构建推送脚本 (docker/nerdctl 兼容) |
| `docs/phase-4-app-deploy.md` | Phase 4 部署文档 |

## 下一步

- Phase 5：CI/CD (FluxCD GitOps)
