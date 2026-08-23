# Phase 5: FluxCD GitOps + GitHub Actions CI/CD

## 1. 概述

Phase 5 实现短链服务的完整 CI/CD 流水线：

- **CI (GitHub Actions)**：push to main 触发，Go vet → Docker build → push ACR
- **CD (FluxCD GitOps)**：watch GitHub repo → Kustomize 同步 → 自动漂移纠正
- **镜像自动更新**：FluxCD ImageReflector 检测 ACR 新 tag → 自动 commit → 滚动更新

---

## 2. 新增文件

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

## 3. 核心组件

### 3.1 K3s 集群侧
| 组件 | 命名空间 | 功能 |
|------|---------|------|
| source-controller | flux-system | 轮询 GitHub 仓库，拉取 manifests |
| kustomize-controller | flux-system | 应用 Kustomize manifests 到集群 |
| helm-controller | flux-system | Helm Release 管理（预留） |
| image-reflector-controller | flux-system | 扫描 ACR 镜像仓库，发现新 tag |
| image-automation-controller | flux-system | 将新 tag 写入 Git repo |
| notification-controller | flux-system | 事件通知（预留） |

> FluxCD 6 个 controller 镜像已搬运至 ACR VPC 域名，3 节点均可免费内网拉取。
>
> **网络需求**：`source-controller`（git clone）和 `image-automation-controller`（push commit）需外网访问，仍固定到 node-01（有 SSH 隧道代理）。其余 4 个 controller 仅需集群内网和 ACR VPC 通信，可调度到任意节点。

### 3.2 GitHub 侧
- **仓库**：`k3s-shortlink`（Private）
- **CI Workflow**：`.github/workflows/build-deploy.yml`
- **Secrets**：ACR 凭证（`ACR_REGISTRY`, `ACR_NAMESPACE`, `ACR_REPOSITORY`, `ACR_USERNAME`, `ACR_PASSWORD`）

## 4. 实施步骤（7 步）

> 执行顺序严格按依赖关系排列：先完成基础设施和仓库准备，再重组 Kustomize 结构，部署 FluxCD CR，最后配置 CI 流水线并端到端验证。

```
Step 0: 前置准备 ─────────► FluxCD 安装 + GitHub 仓库 + SSH remote + go.sum
    │
    ▼
Step 1: Kustomize 结构 ──► data-layer + app-layer kustomization.yaml
    │                    扁平结构，不引入 base/overlays
    ▼
Step 2: Kustomization CR ─► data-layer + app-layer Kustomization
    │                     dependsOn + prune + healthChecks
    ▼
Step 3: 镜像自动发现 ────► ImageRepository + ImagePolicy（VPC ACR，semver）
    │                     ⚠️ IUA 已 SUSPEND（Setters 策略 bug）
    ▼
Step 4: CI 流水线 ──────► GitHub Actions: vet → test → build → push → 更新 tag
    │                     ldflags 注入版本号，CI 标签 v1.0.{run_number}
    ▼
Step 5: ACR 凭证 Secret ─► acr-credentials（flux-system，手动创建）
    │
    ▼
Step 6: 端到端验证 ──────► FluxCD 状态 → 触发 CI → 漂移纠正 → 回滚测试
```

---

### Step 0: 前置基础设施准备

**目标**：完成 FluxCD 安装、GitHub 仓库配置、go.sum 生成，为后续步骤奠定基础。

**涉及项目**：

| 项目 | 说明 | 对应清单 |
|------|------|---------|
| FluxCD 安装（6 controllers） | 含 image-reflector + image-automation 扩展组件 | #2 |
| GitHub 仓库创建 + SSH remote | Private repo，SSH deploy key | #1 |
| `go.sum` 生成并提交 | `go mod tidy` 在 node-01 上执行 | #7 |
| Dockerfile 多阶段构建 | 详见 [phase-4-app-deploy.md Step 2](phase-4-app-deploy.md) | #11 |

---

#### 0.1 安装 FluxCD + 镜像搬运至 ACR（验证清单 #2）

FluxCD 官方镜像托管在 ghcr.io，国内 3 节点中仅 node-01 能通过代理隧道访问。如果直接使用官方镜像地址，controller pod 调度到 node-02/03 时会因 `ImagePullBackOff` 无法启动。

**解决方案**：将 6 个 controller 镜像搬运到 ACR（VPC 域名），3 节点均可免费内网拉取。

> ⚠️ **网络约束**：`source-controller`（git clone GitHub）和 `image-automation-controller`（push commit）需外网访问，必须固定到 node-01。其余 4 个 controller 仅需集群内网和 ACR VPC 通信，可调度到任意节点。

**各 controller 版本**（FluxCD v2.9.x 发布对应的实际镜像 tag）：

| Controller | 镜像版本 |
|-----------|---------|
| source-controller | v1.9.3 |
| kustomize-controller | v1.9.3 |
| helm-controller | v1.6.2 |
| image-reflector-controller | v1.2.3 |
| image-automation-controller | v1.2.3 |
| notification-controller | v1.9.2 |

```bash
# ──────────────────────────────────────────────────
# 1. 安装 FluxCD（在 node-01 上执行）
# ──────────────────────────────────────────────────
flux install \
  --components-extra="image-reflector-controller,image-automation-controller" \
  --namespace=flux-system

# ──────────────────────────────────────────────────
# 2. 将 6 个 controller 镜像搬运到 ACR
#    （一次搬运，后续升级时重复；用 crane 而非 nerdctl pull，
#     因为 node-01 容器运行时无外网代理，详见下方备注）
# ──────────────────────────────────────────────────
ACR_PUBLIC="${ACR_REGISTRY_PUBLIC}/shortlink123"
ACR_VPC="${ACR_REGISTRY}/shortlink123"

# 每个 controller 有自己的版本（不是统一 FLUX_TAG）
declare -A TAGS=(
  [source-controller]=v1.9.3
  [kustomize-controller]=v1.9.3
  [helm-controller]=v1.6.2
  [image-reflector-controller]=v1.2.3
  [image-automation-controller]=v1.2.3
  [notification-controller]=v1.9.2
)

for img in "${!TAGS[@]}"; do
  tag="${TAGS[$img]}"
  # crane copy 直接从 ghcr.io 复制到 ACR，无需 Docker daemon
  crane copy "ghcr.io/fluxcd/$img:$tag" "$ACR_PUBLIC/fluxcd-$img:$tag"
done

# ──────────────────────────────────────────────────
# 3. 修改 deployment image 为 ACR VPC 域名
# ──────────────────────────────────────────────────
for img in "${!TAGS[@]}"; do
  tag="${TAGS[$img]}"
  # container 统一为 "manager"（FluxCD 规范）
  kubectl set image deployment/$img -n flux-system \
    manager="$ACR_VPC/fluxcd-$img:$tag"
done

# ──────────────────────────────────────────────────
# 4. 移除 nodeSelector 固定，再按需添加回网络受限的 controller
# ──────────────────────────────────────────────────
# 全部移除：
for deploy in "${!TAGS[@]}"; do
  kubectl patch deployment $deploy -n flux-system --type=json \
    -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname"}]'
done

# 恢复需要外网的 controller 到 node-01：
kubectl patch deployment source-controller -n flux-system --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname", "value": "node-01"}]'
kubectl patch deployment image-automation-controller -n flux-system --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname", "value": "node-01"}]'

# 扩容（如果当前 replica=0）
for deploy in "${!TAGS[@]}"; do
  kubectl scale deployment $deploy -n flux-system --replicas=1
done
```

> **备注：为什么不在 node-01 上用 `nerdctl pull ghcr.io`？**
> node-01 的 SSH 隧道为 kubectl 访问提供代理，但容器运行时（nerdctl/containerd）不走该隧道，无法直连 ghcr.io。
> `crane`（[google/go-containerregistry](https://github.com/google/go-containerregistry)）是轻量级镜像搬运工具，单二进制、无守护进程依赖，在有外网的开发机上运行。使用 `crane copy` 直接从 ghcr.io 复制到 ACR，绕过本地 Docker daemon。
>
> **镜像命名说明**：ACR 个人版路径为 `registry/namespace/repo:tag`，这里 namespace 复用 `shortlink123`，repo 用 `fluxcd-{controller}` 前缀以示区分。container 统一为 `manager`。

**验证**：
```bash
# 确认 6 个 controller 全部 Running
kubectl get pods -n flux-system -o wide | grep -c Running   # → 6

# 确认镜像来源为 ACR VPC 域名
kubectl describe pod -n flux-system -l app=source-controller | grep Image:

# 确认节点分布
kubectl get pods -n flux-system -o wide | awk '{print $1, $7}'
```

---

#### 0.2 配置 GitHub 仓库与 SSH remote（验证清单 #1）

```bash
# 1. 在 GitHub 创建 Private 仓库 k3s-shortlink

# 2. 本地添加 SSH remote（如已用 HTTPS clone，需修改 remote）
git remote set-url origin git@github.com:{your-repo-url}

# 3. 生成 deploy key（用于 CI push tag 更新）
ssh-keygen -t ed25519 -f ~/.ssh/github-actions -C "github-actions[bot]"

# 4. 将公钥添加到 GitHub Deploy keys（Settings → Deploy keys → Add deploy key）
cat ~/.ssh/github-actions.pub
#    粘贴到 GitHub，勾选 "Allow write access"
```

**验证**：
```bash
# SSH 连接测试
ssh -T git@github.com   # → "Hi L7WD3! You've successfully authenticated"
```

---

#### 0.3 生成并提交 go.sum（验证清单 #7）

CI 中 `go vet` 需要完整的 `go.sum` 文件。不能在 nerdctl 构建容器内执行（网络不通），也不能直接查询 `sum.golang.org`（返回的哈希不全）。必须在有代理的主机上用 Go 二进制直接生成：

```bash
# 在 node-01 上执行（node-01 有 SSH 隧道代理）
cd /path/to/repo
# 确保已安装 Go 1.22+（下载二进制即可，无需安装包）
wget -q https://go.dev/dl/go1.22.12.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.22.12.linux-amd64.tar.gz
export PATH="/usr/local/go/bin:$PATH"
export GOPROXY=https://goproxy.cn,direct
cd app && go mod tidy && cd ..
git add app/go.sum && git commit -m "chore: add go.sum"
git push
```

详见 §6.4。

**验证**：
```bash
# 确认 go.sum 已提交
git log --oneline | head -3   # 应看到 go.sum 的 commit
```

---
### Step 1: Kustomize 结构重组

**目标**：为 data-layer 和 app-layer 创建 kustomization.yaml，聚合 K8s 资源清单。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `k8s/data-layer/kustomization.yaml` | 新建 | data-layer 资源聚合（namespace + 各 StatefulSet/Deployment） |
| `k8s/app-layer/kustomization.yaml` | 新建 | app-layer 资源聚合 + `images.newTag` 占位符（CI 自动更新） |

**目录结构**（扁平，不引入 base/overlays 层级——项目规模小，过度分层反而增加认知负担）：

```
k8s/
├── data-layer/
│   ├── kustomization.yaml          # 仅资源聚合，无 image marker
│   ├── namespace.yaml
│   ├── redis-configmap.yaml
│   ├── redis-statefulset.yaml
│   ├── sentinel-statefulset.yaml
│   ├── orchestrator.yaml
│   └── proxysql.yaml
└── app-layer/
    ├── kustomization.yaml          # 资源聚合 + images.newTag 占位
    ├── namespace.yaml
    ├── configmap.yaml
    ├── shortlink.yaml
    ├── ingress.yaml
    └── hpa.yaml
```

**`k8s/app-layer/kustomization.yaml`** 关键内容（data-layer 版本仅 resources 列表，无 images 段）：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: app-layer
resources:
  - namespace.yaml
  - configmap.yaml
  - secret.yaml
  - shortlink.yaml
  - ingress.yaml
  - hpa.yaml
images:
  - name: crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app
    newTag: v1.0.0   # ← CI 通过 sed 自动更新此行
```

> ⚠️ `images.name` 必须使用包含 VPC 域名的完整三段路径（`domain/namespace/repo`），短格式 `namespace/repo` 无法匹配 Deployment 中的 image 字段。

**验证**：
```bash
# 确认 kustomize build 正确渲染
kubectl kustomize k8s/app-layer --enable-helm 2>/dev/null | grep -c "^apiVersion:"   # 应 > 0
kubectl kustomize k8s/data-layer --enable-helm 2>/dev/null | grep -c "^apiVersion:"  # 应 > 0
```

---

### Step 2: 部署 FluxCD Kustomization CR

**目标**：在 `clusters/production/` 中创建 Kustomization 自定义资源，FluxCD KustomizeController 据此将 manifests 同步到集群。

**涉及文件**：

| 文件 | 说明 |
|------|------|
| `clusters/production/data-layer.yaml` | data-layer Kustomization（无 dependsOn，最先应用） |
| `clusters/production/app-layer.yaml` | app-layer Kustomization（dependsOn: data-layer） |

**关键配置**：

| 字段 | data-layer | app-layer |
|------|-----------|-----------|
| path | `./k8s/data-layer` | `./k8s/app-layer` |
| dependsOn | 无 | data-layer |
| prune | `true` | `true` |
| healthChecks | Redis/Sentinel/ProxySQL/Orchestrator | shortlink Deployment |

```yaml
# clusters/production/app-layer.yaml 示例
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: app-layer
  namespace: flux-system
spec:
  interval: 1m
  path: ./k8s/app-layer
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system          # 复用 FluxCD 默认的 GitRepository
  dependsOn:
    - name: data-layer
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: shortlink
      namespace: app-layer
```

**data-layer 无 dependsOn**——作为基础层，最先被 KustomizeController 应用。

**验证**：
```bash
# 确认 Kustomization 已同步
flux get ks -A

# 查看同步状态
flux get kustomization app-layer --show-ready

# 手动触发立即同步（不等待轮询间隔）
flux reconcile kustomization app-layer
flux reconcile kustomization data-layer
```

---

### Step 3: 配置镜像自动发现

**目标**：部署 ImageRepository + ImagePolicy，使 FluxCD 能自动扫描 ACR 中的新镜像 tag。

**涉及文件**：

| 文件 | 说明 |
|------|------|
| `clusters/production/image-repo.yaml` | ImageRepository（VPC ACR，每 5min 扫描） |
| `clusters/production/image-policy.yaml` | ImagePolicy（semver `>=1.0.0`，自动选最高版本） |
| `clusters/production/image-update.yaml` | ImageUpdateAutomation（**已 SUSPEND**） |

**ImageRepository**：
```yaml
spec:
  image: crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app
  interval: 5m
```

**ImagePolicy**：
```yaml
spec:
  policy:
    semver:
      range: ">=1.0.0"
```

> **ImageUpdateAutomation 已 SUSPEND**（验证清单 #13）：FluxCD v2.9.2 的 Setters 策略存在 bug——无论 `images.name` 使用完整域名还是短格式，都会将完整镜像引用（`domain/ns/repo:tag`）写入 `newTag`，而非仅 tag 部分，导致 Kustomize 渲染出 `domain:domain:tag` 的损坏镜像。
>
> **解决方案**：将 `image-update.yaml` 的 `spec.suspend: true`，ImageRepository + ImagePolicy 保留用于监控。CI 流水线直接更新 `k8s/app-layer/kustomization.yaml` 的 `newTag`。
>
> ```bash
> # 暂停 IUA（验证清单 #13）
> kubectl patch imageupdateautomation shortlink-app -n flux-system \
>   -p '{"spec":{"suspend":true}}' --type=merge
> ```
>
> 详见 §6.9 关键踩坑。

**验证**：
```bash
# 确认 ImageRepository 扫描到最新 tag
flux get image repository

# 查看 ImagePolicy 选中的版本
flux get image policy
kubectl -n flux-system describe imagepolicy shortlink-app-policy
```

---

### Step 4: 配置 GitHub Actions CI 流水线

**目标**：创建 CI workflow，推送代码后自动执行 Go 检查、构建镜像、推送 ACR、更新 Kustomization tag。

**涉及文件**：

| 文件 | 操作 | 说明 |
|------|------|------|
| `.github/workflows/build-deploy.yml` | 新建 | 完整 CI pipeline |

**CI 触发条件**：`git push main` 且 `app/**` 或 `Dockerfile` 变更。

**步骤序列**：

```
git push (app/** or Dockerfile)
    │
    ▼
① Checkout ──────────────► 拉取代码
② Go vet + test ─────────► go vet ./... + go test ./... -v -count=1
③ Docker Buildx ─────────► 设置 BuildKit（含 gha 缓存）
④ ACR Login ─────────────► docker login 公网域名（GitHub Secrets）
⑤ Image tag ─────────────► v1.0.{github.run_number}（+ latest）
⑥ Build & push ─────────► docker/build-push-action@v6
⑦ Trivy scan ───────────► HIGH/CRITICAL 阻断 + SARIF 上传（Phase 6）
⑧ Update newTag ────────► sed -i 更新 kustomization.yaml
⑨ Git commit + push ────► SSH push 回 GitHub
```

**镜像 tag 策略**（验证清单 #9）：

| Tag | 格式 | 用途 |
|-----|------|------|
| 版本 tag | `v1.0.{run_number}` | semver，ImagePolicy 自动选最高 |
| latest | `latest` | 手动调试 |

**版本注入**（验证清单 #9）：通过 Docker ARG + `-ldflags` 将版本号编译进 binary。

Go 代码要求（`app/main.go`）：
```go
// 必须是 var 而非 const——ldflags -X 只对 var 生效
var AppVersion = "dev"
```

Dockerfile 需接收 build-arg：
```dockerfile
ARG VERSION=dev
RUN go build -ldflags="-s -w -X main.AppVersion=${VERSION}" -o shortlink .
```

CI workflow 中 `steps.meta.outputs.tag` 传递 run_number 作为 VERSION：
```yaml
- name: Docker meta
  id: meta
  uses: docker/metadata-action@v5
  with:
    images: ${{ env.ACR_REGISTRY_PUBLIC }}/${{ env.ACR_NAMESPACE }}/${{ env.ACR_REPOSITORY }}
    tags: |
      type=raw,value=v1.0.${{ github.run_number }}
      type=raw,value=latest
```
`/health` 端点最终返回 `{"status":"ok","version":"v1.0.123"}`。

**构建缓存**（验证清单 #8）：使用 `docker/build-push-action@v6` 的 gha 缓存加速重复构建。
```yaml
- name: Build and push
  uses: docker/build-push-action@v6
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

**GitHub Secrets 配置**（验证清单 #1, #7, #10）：

| Secret | 用途 |
|--------|------|
| `ACR_REGISTRY_PUBLIC` | ACR 公网域名 |
| `ACR_NAMESPACE` | 命名空间 `shortlink123` |
| `ACR_REPOSITORY` | 仓库 `shortlink-app` |
| `ACR_USERNAME` | ACR 登录用户名 |
| `ACR_PASSWORD` | ACR 固定密码 |
| `SSH_PRIVATE_KEY` | SSH 私钥（用于 push tag 更新 commit） |

**SSH key 配置**：
```bash
# 1. 在开发机生成 deploy key（已有可复用）
ssh-keygen -t ed25519 -f ~/.ssh/github-actions -C "github-actions[bot]"

# 2. 将公钥添加到 GitHub 仓库：Settings → Deploy keys → Add
#    勾选 Allow write access

# 3. 将私钥内容添加到 GitHub Actions Secrets：
#    Settings → Secrets and variables → Actions → New repository secret
#    Name: SSH_PRIVATE_KEY
#    Value: cat ~/.ssh/github-actions （粘贴完整内容）
```

> 使用 SSH 而非 HTTPS+PAT 的原因（验证清单 #1）：Classic PAT 无 `workflow` scope 时无法修改 `.github/workflows/` 文件。SSH git remote 无此限制。

**go.sum 要求**（验证清单 #7）：CI 中 `go vet` 需要完整的 `go.sum` 文件，必须已提交到 Git。如果缺失，在 node-01 上用 Go 1.26+ 直接运行 `go mod tidy` 生成（详见 §6.4）。

**验证**：
```bash
# 手动触发一次 CI
git commit --allow-empty -m "[ci] test pipeline" && git push

# 在 GitHub Actions 页面检查 workflow 执行进度
# ✓ go vet + go test   → 无错误
# ✓ Docker build + push → ACR 出现新 tag
# ✓ Update newTag       → kustomization.yaml 已更新
# ✓ Git push            → 新 commit 出现在 GitHub
```

---

### Step 5: 创建 ACR 凭证 Secret

**目标**：在 flux-system namespace 中创建 ACR 凭证，供 ImageRepository 扫描 VPC 域名镜像仓库。

**Secrets 不纳入 GitOps**（`secret.yaml` 继续 gitignore），手动创建：

| Secret | 命名空间 | 内容 | 管理方式 |
|--------|---------|------|---------|
| `acr-credentials` | flux-system | ACR Docker 凭证 | 手动 `kubectl create` |
| `mysql-credentials` | data-layer | MySQL 密码 | Phase 3 已创建 |
| `shortlink-secrets` | app-layer | 应用数据库密码 | Phase 4 已创建 |

```bash
# 创建 ACR 凭证（使用公网域名）
kubectl create secret docker-registry acr-credentials \
  --docker-server=crpi-{id}.cn-hangzhou.personal.cr.aliyuncs.com \
  --docker-username=<ACR_USERNAME> \
  --docker-password=<ACR_PASSWORD> \
  -n flux-system
```

> ⚠️ 此 Secret **仅供 ImageRepository 的 VPC 域名扫描使用**。K3s containerd 拉取镜像的认证由 `registries.yaml`（Phase 4）管理，Deployment 无需配置 `imagePullSecrets`。

**验证**：
```bash
kubectl get secret acr-credentials -n flux-system
```

---

### Step 6: 端到端验证

**目标**：验证 CI/CD 全链路——从代码 push 到新版本自动上线，以及回滚和漂移纠正能力。

```bash
# 1. FluxCD 组件健康状态
flux get all -A

# 2. GitRepository 同步状态
flux get sources git

# 3. Kustomization 同步状态
flux get kustomizations

# 4. 端到端功能测试
curl -s http://<集群公网入口IP>/health
# → {"status":"ok","version":"v1.0.N"}

# 5. 确认版本号与 CI run_number 一致（验证清单 #9）
#    在 GitHub Actions 页面找到最近一次 workflow run 的编号 N，
#    对比 /health 返回的 version 字段，应匹配 "v1.0.N"

# 6. 漂移纠正测试：手动改 replicas，确认 FluxCD 自动恢复
kubectl -n app-layer scale deployment shortlink --replicas=5
kubectl get deploy shortlink -n app-layer -w
# 等待约 5min → 自动恢复为 2

# 7. 回滚测试
git revert HEAD~1 && git push
# 等待 CI/CD 执行，确认部署回退
curl -s http://<集群公网入口IP>/health   # 版本号应回退
```

**验证指标**：

| 检查项 | 预期结果 | 验证方式 | 对应清单 |
|--------|---------|---------|---------|
| FluxCD controllers | 6 个全部 Running（flux-system ns） | `flux get all -A` | #2 |
| Kustomization | data-layer + app-layer Ready | `flux get ks` | #4 |
| ImageRepository | 扫描到最新 tag | `flux get image repository` | #6 |
| ImagePolicy | 选出最新 semver 版本 | `flux get image policy` | #6 |
| CI pipeline | ✓ vet ✓ test ✓ build ✓ push ✓ tag update | GitHub Actions 页面 | #7, #8, #10 |
| CI tag 更新 | kustomization.yaml 的 newTag 已更新 | GitHub 仓库 commit 记录 | #10 |
| 版本一致性 | `/health` 返回的 version 与 CI run_number 一致 | `curl <IP>/health` | #9 |
| 代码 push → Pod 更新 | < 3min（SourceController 1min + 滚动更新） | `kubectl get pods -n app-layer -w` | — |
| 漂移纠正 | 手动改 replicas 后自动恢复 | `kubectl get deploy -n app-layer` | #12 |
| IUA 暂停 | image-update 的 suspend: true | `flux get image update` | #13 |

**回滚策略参考**：

| 场景 | 操作 |
|------|------|
| 镜像回滚 | `git revert` CI 自动 commit → push → 5min 内自动同步 |
| 配置回滚 | `git revert` 错误 commit → push → FluxCD 自动 reconcile |
| 漂移纠正 | FluxCD 检测到集群与 Git 不一致 → 自动纠正（`prune: true`） |
| FluxCD 卸载 | `flux uninstall`（不影响已部署 Pod） |

## 5. 验证清单

| 项目                           | 状态 | 说明                                                    |
| ------------------------------ | ---- | ------------------------------------------------------- |
| GitHub 仓库创建 & 代码推送     | ✅    | `k3s-shortlink` Private repo，SSH push                  |
| FluxCD 安装（6 controllers）   | ✅    | 镜像已搬运至 ACR VPC 域名（详见 §6.2 版本列表）         |
| 网络约束                       | ✅    | source-controller + image-automation 固定 node-01，其余 4 个浮在其他节点 |
| Kustomize 结构重组             | ✅    | data-layer + app-layer，扁平结构                        |
| FluxCD Kustomization CR        | ✅    | data-layer + app-layer，prune + dependsOn               |
| ACR Secret（flux-system）      | ✅    | 含公网 + VPC 双域名凭证                                 |
| ImageRepository + ImagePolicy  | ✅    | 监控用，VPC 域名，每 5min 扫描                          |
| CI：go vet + go test           | ✅    | `go.sum` 已提交，CI 通过                                |
| CI：docker build + push ACR    | ✅    | `docker/build-push-action@v6`，含 gha 缓存              |
| CI：ldflags 注入版本号         | ✅    | `VERSION=${{ github.run_number }}` → `/health` 返回版本 |
| CI：自动更新 Kustomization tag | ✅    | 替代 IUA，CI 推送后直接 commit tag 更新                 |
| Dockerfile：多阶段构建         | ✅    | golang:1.22-alpine → alpine:3.20，非 root 运行          |
| 漂移纠正                       | ✅    | FluxCD 检测到手动改 replicas 后自动恢复                 |
| IUA 永久暂停                   | ✅    | Setters 策略 bug（v2.9.2），由 CI 替代                  |

## 6. 关键踩坑

### 6.1 GitHub HTTPS 超时 → SSH Bootstrap 绕过

`flux bootstrap github` 需要用 HTTPS (443) 向 GitHub 写入 deploy key。从阿里云（杭州）到 github.com:443 **TCP 连接超时**（约 120s），无法完成 bootstrap。

**解决方案**：
- 使用 `flux install --components-extra="image-reflector-controller,image-automation-controller"` 在集群内安装控制器
- 手动创建 SSH deploy key（`ssh-keygen -t ed25519`）+ GitHub API 创建 deploy key
- 配置 GitRepository 使用 SSH URL（`git@github.com:`）
- 手动创建 image automation 相关 CRD

> **教训**：国内环境部署 Kubernetes 时，HTTPS 到 GitHub 可能不通但 SSH (22) 通。FluxCD 官方教程默认使用 `flux bootstrap`，但在国内需要理解其内部机制后手动组装。

### 6.2 FluxCD Controller 镜像搬运到 ACR（替代 nodeSelector 固定）

FluxCD 镜像托管在 ghcr.io，仅 node-01 能通过代理隧道访问。如果直接使用官方镜像地址，controller pod 调度到 node-02/03 时会因 `ImagePullBackOff` 无法启动。

**初始方案**：用 `nodeSelector` 将 6 个 controller 全部固定到 node-01。缺点：node-01 仅 2C2G，运行 K3s server（etcd + apiserver + 多个 agent 进程）后资源紧张，6 个 controller 进一步挤占内存；node-02/03 资源闲置。

**优化方案**：将 6 个 controller 镜像搬运到 ACR VPC 域名，3 节点均可免费内网拉取。

> ⚠️ **网络约束提醒**：`source-controller`（git clone GitHub）和 `image-automation-controller`（push commit）仍必须通过 `nodeSelector: hostname=node-01` 固定到 node-01，因为 node-02/03 无外网代理。其余 4 个 controller 仅需 ACR VPC 通信（内网免费）和集群内通信，可调度到任意节点。

**各 controller 版本**（FluxCD v2.9.x 发布）：

| Controller | 镜像版本 |
|-----------|---------|
| source-controller | v1.9.3 |
| kustomize-controller | v1.9.3 |
| helm-controller | v1.6.2 |
| image-reflector-controller | v1.2.3 |
| image-automation-controller | v1.2.3 |
| notification-controller | v1.9.2 |

**搬运脚本**（用 `crane` 在本地开发机执行，而非 node-01 的 nerdctl）：

```bash
# 一次搬运，后续升级 FluxCD 时重复
ACR_PUBLIC="crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123"
ACR_VPC="crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123"

declare -A TAGS=(
  [source-controller]=v1.9.3
  [kustomize-controller]=v1.9.3
  [helm-controller]=v1.6.2
  [image-reflector-controller]=v1.2.3
  [image-automation-controller]=v1.2.3
  [notification-controller]=v1.9.2
)

# crane copy: 直接从 ghcr.io 复制到 ACR，无需 Docker daemon
for img in "${!TAGS[@]}"; do
  tag="${TAGS[$img]}"
  crane copy "ghcr.io/fluxcd/$img:$tag" "$ACR_PUBLIC/fluxcd-$img:$tag"
done

# 切换 deployment image
for img in "${!TAGS[@]}"; do
  tag="${TAGS[$img]}"
  kubectl set image deployment/$img -n flux-system \
    manager="$ACR_VPC/fluxcd-$img:$tag"
done

# 移除 nodeSelector，再恢复需要外网的 controller
kubectl patch deployment source-controller -n flux-system --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname"}]'
kubectl patch deployment image-automation-controller -n flux-system --type=json \
  -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname"}]'
# 继续移除其余 4 个（它们本来就没有 nodeSelector，但确保一致性）
for deploy in kustomize-controller helm-controller \
              image-reflector-controller notification-controller; do
  kubectl patch deployment $deploy -n flux-system --type=json \
    -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname"}]'
done

# 恢复外网受限的 controller 到 node-01
kubectl patch deployment source-controller -n flux-system --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname", "value": "node-01"}]'
kubectl patch deployment image-automation-controller -n flux-system --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1hostname", "value": "node-01"}]'

# 扩容（如果当前 replica=0）
for deploy in "${!TAGS[@]}"; do
  kubectl scale deployment $deploy -n flux-system --replicas=1
done
```

> **为什么用 `crane` 而非 `nerdctl pull`？** node-01 的 SSH 隧道为 kubectl 代理，但容器运行时（nerdctl/containerd）不走该代理，无法直连 ghcr.io。`crane` 是单二进制工具，在本地开发机上运行，直接从 ghcr.io 复制到 ACR。详见 [google/go-containerregistry](https://github.com/google/go-containerregistry)。
>
> **container 名**：FluxCD deployment 中 container 统一命名为 `manager`，不能使用 deployment 名称。`kubectl set image deployment/$name manager=...` 才是正确的。

**效果对比**：

| 方案 | node-01 负担 | node-02/03 利用 | GitHub 可达性 |
|------|-------------|-----------------|--------------|
| 6 全部固定在 node-01 | K3s server + 6 controller → 吃紧 | 仅跑应用，空闲 | ✅ source-controller 可 git clone |
| ACR 搬运 + 选择性固定 | K3s server + 2 controller（source + image-automation） | 4 controller + 应用 | ✅ 外网 controller 仍在 node-01 |
| 全部浮动 | K3s server 仅自身 | 全部浮到非 node-01 | ❌ source-controller 无法 git clone |

### 6.3 FluxCD Image CRD apiVersion 变更

FluxCD v2.9.2 中 ImageRepository、ImagePolicy、ImageUpdateAutomation 的 apiVersion 已从 `image.toolkit.fluxcd.io/v1beta2` 迁移到 `image.toolkit.fluxcd.io/v1`。使用旧版本会导致 CRD 校验错误。

**错误信息**：`no matches for kind "ImageRepository" in version "image.toolkit.fluxcd.io/v1beta2"`

**修复**：3 个文件全部改为 `v1`。

### 6.4 go.sum 必须提交到 Git

CI 中 `go vet` 需要完整的 `go.sum` 文件。之前 `go.sum` 只存在于构建镜像内部，未提交到 Git —— CI checkout 后 `go vet` 直接失败。

**生成方法**：在 node-01 上下载 Go 1.22.12 二进制，设置 `GOPROXY=https://goproxy.cn,direct`，运行 `go mod tidy` 生成完整 go.sum（103 行）。

> **注意**：不能直接查询 `sum.golang.org`（返回的哈希不全），也不能在 nerdctl 构建容器中运行（容器网络不通代理）。必须在有代理的主机上下载 Go 二进制直接执行。

### 6.5 Go 语法错误：const 必须在 import 之后

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

### 6.6 nerdctl + buildkitd: sudo PATH 不包含 /usr/local/bin

`sudo nerdctl build` 调用的 `buildctl` 安装在 `/usr/local/bin`，但 sudo 的 secure_path 默认不包含此路径。

**解决方案**：`sudo PATH="/usr/local/bin:$PATH" nerdctl build ...`

### 6.7 nerdctl 构建容器内网络隔离

`nerdctl build` 内部运行 `go mod tidy` 时容器无法访问外网（HTTP_PROXY 未传递给 build 容器）。即使设置了 `--build-arg HTTP_PROXY=...`，`go mod tidy` 仍然超时。

**解决方案**：不在构建容器内运行 `go mod tidy`，而是在主机上下载 Go 二进制直接执行，将生成的 `go.sum` 一起提交。

### 6.8 ImageUpdateAutomation Commit 模板变量变迁

FluxCD v2.9.2 的 commit template 变量与旧版不同：

| 变量 | 状态 | 说明 |
|------|------|------|
| `{{ .New.Tag }}` | ❌ 不存在 | `can't evaluate field New in type source.TemplateData` |
| `{{ .Updated }}` | ❌ 已移除 | `template uses removed '.Updated' field. Please use '.Changed' instead` |
| `{{ .Changed }}` | ⚠️ 复杂 map | 类型为 `map[string]map[string][]map[string]string`，无法在 commit template 中 range |

**最终方案**：放弃动态模板，使用固定文本 `[ci] update shortlink-app image`。

> **教训**：FluxCD 版本间 template 变量变化大，升级时要查对应版本的文档/GitHub 源码。固定 commit message 在单镜像场景下足够。

### 6.9 VPC vs 公网 ACR 域名不匹配 & IUA Setters 策略 Bug ✅ 已解决

这是 Phase 5 最棘手的 bug。经过多轮排查，最终通过**废弃 IUA、改由 CI 直接更新 tag** 的方案解决。

#### 问题根因

FluxCD v2.9.2 的 ImageUpdateAutomation Setters 策略无论 `images.name` 使用完整域名还是短格式，都会将完整镜像引用写入 `newTag`：

```yaml
# IUA 写入（错误）
newTag: crpi-xxx-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1.0.7

# 期望
newTag: v1.0.7
```

#### 尝试过的修复

| 尝试 | 结果 |
|------|------|
| 统一 ImageRepository 和 kustomization 域名 | ❌ 仍然写入全量引用 |
| 使用短格式 `images.name`（如 `shortlink123/shortlink-app`） | ❌ 仍写入全量引用，且 Kustomize 不匹配 |
| 恢复完整 VPC 域名 | ✅ Kustomize 正确匹配，但 IUA 仍写入全量引用 |

#### 最终方案：废弃 IUA，CI 直接更新 tag

在 GitHub Actions CI workflow 中添加步骤，每次构建后直接更新 `k8s/app-layer/kustomization.yaml` 的 `newTag` 并 push：

```yaml
- name: Update Kustomization tag
  run: |
    sed -i "s/^    newTag: .*/    newTag: ${TAG}/" k8s/app-layer/kustomization.yaml
    git config user.name "github-actions[bot]"
    git commit -m "[ci] update shortlink-app image to ${TAG}"
    git push
```

IUA 永久暂停（`spec.suspend: true`），ImageRepository + ImagePolicy 保留用于监控。

### 6.10 GitHub PAT scope 限制

Classic PAT 如果没有 `workflow` scope，无法通过 API 修改 `.github/workflows/*` 文件。Git 命令行 push 不受影响，但 GitHub Actions 的某些自动化操作需要此 scope。
