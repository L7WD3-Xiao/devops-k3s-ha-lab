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

1. **ghcr.io 从国内直接可达**：FluxCD 镜像托管在 ghcr.io，从 node-01（阿里云杭州）可以直接拉取，走 HTTP/2，约 1.2s 完成 35MB 下载。**不需要代理隧道**。
2. **node-02/03 无公网不能拉 ghcr.io**：通过 node affinity 将所有 FluxCD controller pod 固定到 node-01。
3. **GitHub Releases 下载慢**：flux CLI 二进制从 GitHub Releases 直连只有 ~45 KB/s，通过 `gh-proxy.com` 加速到 ~1.2 MB/s（16s 完成）。
4. **Secrets 不纳入 GitOps**：secret.yaml 继续 gitignore，手动创建。生产环境推荐 Sealed Secrets 或 SOPS。
