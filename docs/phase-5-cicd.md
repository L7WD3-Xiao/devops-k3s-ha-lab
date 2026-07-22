# Phase 5: FluxCD GitOps + GitHub Actions CI/CD

## 概述

Phase 5 实现短链服务的完整 CI/CD 流水线：

- **CI (GitHub Actions)**：push to main 触发，Go vet → Docker build → push ACR
- **CD (FluxCD GitOps)**：watch GitHub repo → Kustomize 同步 → 自动漂移纠正
- **镜像自动更新**：FluxCD ImageReflector 检测 ACR 新 tag → 自动 commit → 滚动更新

## 核心组件

### K3s 集群侧
| 组件 | 命名空间 | 功能 |
|------|---------|------|
| source-controller | flux-system | 轮询 GitHub 仓库，拉取 manifests |
| kustomize-controller | flux-system | 应用 Kustomize manifests 到集群 |
| helm-controller | flux-system | Helm Release 管理（预留） |
| image-reflector-controller | flux-system | 扫描 ACR 镜像仓库，发现新 tag |
| image-automation-controller | flux-system | 将新 tag 写入 Git repo |
| notification-controller | flux-system | 事件通知（预留） |

> FluxCD 6 个 controller 全部通过 node affinity 固定在 node-01（node-02/03 无公网，无法拉取 ghcr.io 镜像）。

### GitHub 侧
- **仓库**：`k3s-shortlink`（Private）
- **CI Workflow**：`.github/workflows/build-deploy.yml`
- **Secrets**：ACR 凭证（`ACR_REGISTRY`, `ACR_NAMESPACE`, `ACR_REPOSITORY`, `ACR_USERNAME`, `ACR_PASSWORD`）

## Kustomize 结构

```
k8s/
├── data-layer/
│   ├── kustomization.yaml          # 资源聚合
│   ├── namespace.yaml
│   ├── redis-configmap.yaml
│   ├── redis-statefulset.yaml
│   ├── sentinel-statefulset.yaml
│   ├── orchestrator.yaml
│   └── proxysql.yaml
├── app-layer/
│   ├── kustomization.yaml          # 资源聚合 + image marker
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── shortlink.yaml
│   ├── ingress.yaml
│   └── hpa.yaml
```

> 不引入 base/overlays 层级，保持扁平结构。项目规模小，过度分层反而增加认知负担。

## FluxCD 资源

### Kustomization（声明式同步）

**data-layer**：watch `./k8s/data-layer`
- `prune: true` — Git 删除的资源自动从集群删除
- `healthChecks` — 等待 Redis/Sentinel/ProxySQL/Orchestrator 全部健康
- 无 `dependsOn` — 基础层，最先应用

**app-layer**：watch `./k8s/app-layer`
- `dependsOn: data-layer` — 确保 MySQL/Redis 就绪后再部署应用
- `healthChecks` — 等待 shortlink Deployment 健康
- 镜像 tag 由 ImageUpdateAutomation 自动更新

### Image Automation（镜像自动更新）

```
ACR (public)  →  ImageRepository (每5min扫描)
                     ↓
                ImagePolicy (semver >=1.0.0)
                     ↓
                ImageUpdateAutomation (commit newTag → GitHub)
                     ↓
                SourceController (检测新commit)
                     ↓
                KustomizeController (滚动更新)
```

**命名说明**：ImageRepository 用 ACR **公网**域名（GitHub Actions 在 VPC 外推送），Kustomize `images.name` 用 **VPC** 域名（集群拉取）。FluxCD 只更新 tag，不碰域名——两者不冲突。

## CI/CD 流程

```
git push main (app/ or Dockerfile changed)
    │
    ▼ (GitHub Actions)
go vet → go test → docker build → push ACR (v1.0.N)
    │
    ▼ (FluxCD, <5min)
ImageReflector 发现 v1.0.N → ImagePolicy 选择最新
    │
    ▼ (FluxCD)
ImageUpdateAutomation: commit newTag → k8s/app-layer/kustomization.yaml
    │
    ▼ (FluxCD, <1min)
SourceController 检测新 commit → KustomizeController 滚动更新
    │
    ▼
Traefik → shortlink:8080 (新版本)
```

## 镜像 tag 策略

- CI tag 格式：`v1.0.{github.run_number}`（semver）
- FluxCD ImagePolicy：`semver: ">=1.0.0"`（自动选最高版本）
- 同时推送 `latest` tag（方便手动调试）

## Secrets 管理

secrets **不**纳入 GitOps（secret.yaml 继续 gitignore）：

| Secret | 命名空间 | 内容 | 管理方式 |
|--------|---------|------|---------|
| `mysql-credentials` | data-layer | MySQL 密码 | 手动 `kubectl create` |
| `shortlink-secrets` | app-layer | 应用数据库密码 | 手动 `kubectl create` |
| `acr-credentials` | flux-system | ACR Docker 密码 | 手动 `kubectl create` |

## 回滚

| 场景 | 操作 |
|------|------|
| 镜像回滚 | `git revert` FluxCD 自动 commit → push → 5min 内自动同步 |
| 配置回滚 | `git revert` 错误 commit → push → FluxCD 自动 reconcile |
| 漂移纠正 | FluxCD 检测到集群与 Git 不一致 → 自动纠正（`prune: true`） |
| FluxCD 卸载 | `flux uninstall`（不影响已部署 Pod） |

## 新增文件

```
.github/workflows/build-deploy.yml        # CI pipeline
clusters/production/
  ├── data-layer.yaml                      # FluxCD Kustomization (data-layer)
  ├── app-layer.yaml                       # FluxCD Kustomization (app-layer)
  ├── image-repo.yaml                      # ImageRepository (watch ACR)
  ├── image-policy.yaml                    # ImagePolicy (semver)
  └── image-update.yaml                    # ImageUpdateAutomation (commit tag)
k8s/data-layer/kustomization.yaml          # Kustomize base template
k8s/app-layer/kustomization.yaml           # Kustomize base + image marker
```

## 验证

```bash
# 1. FluxCD 状态
flux get all -A

# 2. 端到端测试：修改 app/main.go → git push → 等待
curl http://116.62.168.245/health

# 3. 漂移纠正
kubectl -n app-layer scale deployment shortlink --replicas=5
# 等待 5min，确认自动恢复 2

# 4. 回滚
git revert HEAD~1 && git push
# 确认部署回退
```

## 关键踩坑

### 1. GitHub HTTPS 超时 → SSH Bootstrap 绕过

`flux bootstrap github` 需要用 HTTPS (443) 向 GitHub 写入 deploy key。从阿里云（杭州）到 github.com:443 **TCP 连接超时**（约 120s），无法完成 bootstrap。

**解决方案**：
- 使用 `flux install --components-extra="image-reflector-controller,image-automation-controller"` 在集群内安装控制器
- 手动创建 SSH deploy key（`ssh-keygen -t ed25519`）+ GitHub API 创建 deploy key
- 配置 GitRepository 使用 SSH URL（`git@github.com:`）
- 手动创建 image automation 相关 CRD

> **教训**：国内环境部署 Kubernetes 时，HTTPS 到 GitHub 可能不通但 SSH (22) 通。FluxCD 官方教程默认使用 `flux bootstrap`，但在国内需要理解其内部机制后手动组装。

### 2. FluxCD Controller Pod 调度到错误节点

FluxCD 镜像托管在 ghcr.io，只有 node-01 能通过代理隧道访问。但默认调度器可能将 controller pods 调度到 node-02/03 导致 `ImagePullBackOff`。

**解决方案**：
```bash
kubectl patch deployment -n flux-system <controller> \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"node-01"}}}}}'
```
6 个 controller（source、kustomize、helm、image-reflector、image-automation、notification）全部固定到 node-01。

### 3. FluxCD Image CRD apiVersion 变更

FluxCD v2.9.2 中 ImageRepository、ImagePolicy、ImageUpdateAutomation 的 apiVersion 已从 `image.toolkit.fluxcd.io/v1beta2` 迁移到 `image.toolkit.fluxcd.io/v1`。使用旧版本会导致 CRD 校验错误。

**错误信息**：`no matches for kind "ImageRepository" in version "image.toolkit.fluxcd.io/v1beta2"`

**修复**：3 个文件全部改为 `v1`。

### 4. go.sum 必须提交到 Git

CI 中 `go vet` 需要完整的 `go.sum` 文件。之前 `go.sum` 只存在于构建镜像内部，未提交到 Git —— CI checkout 后 `go vet` 直接失败。

**生成方法**：在 node-01 上下载 Go 1.22.12 二进制，设置 `GOPROXY=https://goproxy.cn,direct`，运行 `go mod tidy` 生成完整 go.sum（103 行）。

> **注意**：不能直接查询 `sum.golang.org`（返回的哈希不全），也不能在 nerdctl 构建容器中运行（容器网络不通代理）。必须在有代理的主机上下载 Go 二进制直接执行。

### 5. Go 语法错误：const 必须在 import 之后

添加 `AppVersion` 常量时误放在 `import` 块之前：
```go
// ❌ 错误
const AppVersion = "v1.0.1"
import (...)

// ✅ 正确
import (...)
const AppVersion = "v1.0.1"
```
Go 编译器报错：`imports must appear before other declarations`。

### 6. nerdctl + buildkitd: sudo PATH 不包含 /usr/local/bin

`sudo nerdctl build` 调用的 `buildctl` 安装在 `/usr/local/bin`，但 sudo 的 secure_path 默认不包含此路径。

**解决方案**：`sudo PATH="/usr/local/bin:$PATH" nerdctl build ...`

### 7. nerdctl 构建容器内网络隔离

`nerdctl build` 内部运行 `go mod tidy` 时容器无法访问外网（HTTP_PROXY 未传递给 build 容器）。即使设置了 `--build-arg HTTP_PROXY=...`，`go mod tidy` 仍然超时。

**解决方案**：不在构建容器内运行 `go mod tidy`，而是在主机上下载 Go 二进制直接执行，将生成的 `go.sum` 一起提交。

### 8. ImageUpdateAutomation Commit 模板变量变迁

FluxCD v2.9.2 的 commit template 变量与旧版不同：

| 变量 | 状态 | 说明 |
|------|------|------|
| `{{ .New.Tag }}` | ❌ 不存在 | `can't evaluate field New in type source.TemplateData` |
| `{{ .Updated }}` | ❌ 已移除 | `template uses removed '.Updated' field. Please use '.Changed' instead` |
| `{{ .Changed }}` | ⚠️ 复杂 map | 类型为 `map[string]map[string][]map[string]string`，无法在 commit template 中 range |

**最终方案**：放弃动态模板，使用固定文本 `[ci] update shortlink-app image`。

> **教训**：FluxCD 版本间 template 变量变化大，升级时要查对应版本的文档/GitHub 源码。固定 commit message 在单镜像场景下足够。

### 9. VPC vs 公网 ACR 域名不匹配（Setters 策略）⚠️ 待修复

**问题根因**：
- `k8s/app-layer/kustomization.yaml` 中 `images.name` 使用 **VPC 域名**：`crpi-xxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com/...`（集群内免流量拉取）
- `clusters/production/image-repo.yaml` 中 `image` 使用 **公网域名**：`crpi-xxx.cn-hangzhou.personal.cr.aliyuncs.com/...`（考虑到 GitHub Actions 在 VPC 外）

当 ImageUpdateAutomation 的 Setters 策略执行时，它尝试通过 `images.name` 匹配 ImagePolicy 解析的镜像引用。由于 name 使用 VPC 域名但 ImageRepository 返回公网域名的 tag，导致 Setters 无法正确提取 tag，将整个公网镜像引用作为 `newTag` 写入：

```yaml
# ❌ 错误结果（IUA 写入）
name: crpi-xxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app
newTag: crpi-xxx.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1.0.6

# ✅ 正确结果（期望）
name: crpi-xxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app
newTag: v1.0.6
```

**解决方案**：将 `image-repo.yaml` 的 `image` 改为 VPC 域名，使 ImageRepository 扫描到的镜像名与 kustomization.yaml 的 `images.name` 一致。node-01 在 VPC 内，可以访问 VPC ACR 域名。

### 10. GitHub PAT scope 限制

Classic PAT 如果没有 `workflow` scope，无法通过 API 修改 `.github/workflows/*` 文件。Git 命令行 push 不受影响，但 GitHub Actions 的某些自动化操作需要此 scope。

### 11. 代理隧道管理

SSH 反向隧道（本机:7897 → node-01:8888）用于在开发环境与集群之间建立稳定通道：

- 断线自动恢复：~95s（ServerAliveInterval 30s × ServerAliveCountMax 3 + 重试间隔 5s）
- 线性退避重连：连续失败时等待间隔递增（5s → 10s → ... → 最大 60s）
- 同一个 RemoteForward 端口只能有一个 SSH 连接，后续连接会报错退出
- 使用 `autossh-tunnel.sh start|stop|restart|status` 管理生命周期
