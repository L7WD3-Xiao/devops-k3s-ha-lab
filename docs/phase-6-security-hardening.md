# Phase 6：安全加固

## 1. 概述

对 K3s 集群进行纵深防御安全加固，覆盖身份认证（RBAC）、网络隔离（NetworkPolicy）、容器安全（SecurityContext + PSS）、CI 镜像扫描（Trivy）、密钥管理（Secret 迁移）、资源配额（ResourceQuota）六大领域。

## 2. 安全分层架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        外部流量                                  │
│                    (Internet → EIP:80)                          │
└───────────────────────┬─────────────────────────────────────────┘
                        │
                ┌───────▼────────┐
                │  L7: Traefik   │  Ingress Controller (kube-system)
                │  Ingress :80   │  hostNetwork: true
                └───────┬────────┘
                        │  NetworkPolicy: allow-from-traefik
        ┌───────────────┼───────────────┐
        │               │               │
┌───────▼──────┐ ┌──────▼──────┐ ┌──────▼───────┐
│  app-layer   │ │  data-layer │ │  flux-system │
│  restricted  │ │  baseline   │ │  (自带 NP)    │
│  PSS 级别     │ │  PSS 级别   │ │              │
├──────────────┤ ├─────────────┤ ├──────────────┤
│ shortlink    │ │ Redis x3    │ │ source-ctrl  │
│ (UID 10001)  │ │ Sentinel x3 │ │ kustomize    │
│ drop ALL caps│ │ ProxySQL    │ └──────────────┘
│ readOnlyRoot │ │ Orchestrator│
│ seccomp:Def  │ │ (root,drop) │
├──────────────┤ ├─────────────┤
│ RBAC:        │ │ RBAC:       │
│  developer   │ │  view (CR)  │
│  viewer      │ │             │
│  shortlink   │ │             │
├──────────────┤ ├─────────────┤
│ Quota:       │ │ Quota:      │
│  2CPU/1Gi    │ │  3CPU/2Gi   │
├──────────────┤ ├─────────────┤
│ NetworkPolicy│ │NetworkPolicy│
│  deny ingress│ │ deny all    │
│ allow traefik│ │ allow app   │
│  allow data  │ │ allow redis │
│  allow dns   │ │ allow mysql │
└──────┬───────┘ └──────┬──────┘
       │                │
       │    ┌───────────▼───────────┐
       │    │  物理机 MySQL          │
       └───►│  192.168.1.230:3306   │ (Master)
            │  192.168.1.229:3306   │ (Slave)
            └───────────────────────┘
```

**防御纵深 5 层**：

| 层 | 技术手段 | 防护目标 |
|----|---------|---------|
| L1 网络隔离 | NetworkPolicy 白名单 | 限制 Pod 间流量，防止横向移动 |
| L2 容器安全 | SecurityContext + PSS | 非 root 运行、drop capabilities、seccomp |
| L3 身份认证 | RBAC (Role/RoleBinding) | 最小权限，避免 default SA 滥用 |
| L4 资源限制 | ResourceQuota + LimitRange | 防止资源耗尽型攻击 |
| L5 CI 安全 | Trivy 镜像扫描 | 阻断含 HIGH/CRITICAL 漏洞的镜像部署 |

## 3. 安全现状分析（加固前）

### 3.1 问题清单

| # | 问题 | 风险等级 | 影响范围 |
|---|------|---------|---------|
| 1 | 所有 Pod 使用 `default` ServiceAccount，无 RBAC | 高 | app-layer + data-layer |
| 2 | 无 NetworkPolicy（除 flux-system 自带），Pod 间无网络隔离 | 高 | 全集群 |
| 3 | 无 SecurityContext，容器默认拥有全部 capabilities | 高 | 全部 5 个 workload |
| 4 | Namespace 无 PSS 标签，不限制特权容器 | 中 | app-layer + data-layer |
| 5 | Orchestrator ConfigMap 中 ProxySQLPassword 明文 | 中 | data-layer/orchestrator.yaml |
| 6 | 无 ResourceQuota/LimitRange，无资源总量限制 | 中 | app-layer + data-layer |
| 7 | 3 个 init container 无 resources 字段 | 低 | sentinel/proxysql/orchestrator |
| 8 | CI 无镜像安全扫描 | 中 | GitHub Actions |

### 3.2 镜像用户模型分析

| 镜像 | 默认用户 | 非 root UID | 写入路径 | PSS 适配策略 |
|------|---------|------------|---------|-------------|
| shortlink (自建) | appuser | 10001 (Dockerfile USER) | 无 | restricted ✅ |
| redis:7-alpine | root | 999 (redis 用户) | /data (PVC) | baseline (非 root 可行) |
| proxysql:2.7.2 | root | 无预置 | /var/lib/proxysql (emptyDir) | baseline (root) |
| orchestrator:latest | root | 无预置 | 无持久写入 | baseline (root) |

## 4. 实施步骤（7 步）

> 执行顺序严格按依赖关系排列：SecurityContext 必须在 PSS 之前部署，否则 Pod 会被 PSS 拒绝调度。

```
Step 1: ServiceAccounts ──────► 创建 6 个命名 SA
    │
    ▼
Step 2: SecurityContext ──────► 为 5 个 workload 添加 SC（触发滚动重建）
    │
    ▼
Step 3: Pod Security Standards ► namespace 打 PSS label
    │                            （依赖 Step 2，否则 Pod 被拒）
    ▼
Step 4: RBAC ─────────────────► 3 层角色模型 + RoleBinding
    │
    ▼
Step 5: ResourceQuota ────────► 配额 + LimitRange + init container resources
    │
    ▼
Step 6: NetworkPolicy ────────► 白名单网络隔离（最后部署，避免阻断启动流量）
    │
    ▼
Step 7: Trivy CI ─────────────► GitHub Actions 镜像扫描
```

---

### Step 1: ServiceAccounts

**目标**：为每个 workload 创建专用 SA，替换 `default`。

**新建文件**：

| 文件 | SA 列表 |
|------|--------|
| `k8s/app-layer/sa.yaml` | `shortlink-app`（workload）、`developer`（开发者）、`viewer`（只读） |
| `k8s/data-layer/sa.yaml` | `redis`、`proxysql`、`orchestrator` |

**修改文件**（添加 `serviceAccountName` 字段）：

| 文件 | 资源 | SA |
|------|------|----|
| `k8s/app-layer/shortlink.yaml` | Deployment | `shortlink-app` |
| `k8s/data-layer/redis-statefulset.yaml` | StatefulSet | `redis` |
| `k8s/data-layer/sentinel-statefulset.yaml` | StatefulSet | `redis`（复用） |
| `k8s/data-layer/proxysql.yaml` | Deployment | `proxysql` |
| `k8s/data-layer/orchestrator.yaml` | Deployment | `orchestrator` |

**kustomization.yaml 更新**：两个 namespace 的 `resources` 列表各添加 `- sa.yaml`。

**验证**：
```bash
kubectl get sa -n app-layer    # 应有 shortlink-app, developer, viewer
kubectl get sa -n data-layer   # 应有 redis, proxysql, orchestrator
kubectl get pod -n app-layer -o jsonpath='{.items[0].spec.serviceAccountName}'  # shortlink-app
```

---

### Step 2: SecurityContext

**目标**：为所有容器添加安全上下文，限制权限。

> ⚠️ **必须在 Step 3 (PSS) 之前执行**。否则 restricted PSS 会拒绝不符合要求的 Pod。

#### 2.1 shortlink (app-layer → restricted)

```yaml
# spec.template.spec.containers[name=shortlink]
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

- Dockerfile 已有 `USER appuser (UID 10001)`，SC 与之一致
- `readOnlyRootFilesystem: true`：Go 应用无文件写入，Gin ReleaseMode 不写临时文件
- preStop hook `sh -c "sleep 5"` 使用 shell built-in，不需要写文件

#### 2.2 Redis (data-layer → baseline, 非 root)

```yaml
# Pod 级别
securityContext:
  fsGroup: 999       # PVC /data 权限

# Container 级别
securityContext:
  runAsNonRoot: true
  runAsUser: 999      # redis:7-alpine 内置 redis 用户
  runAsGroup: 999
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

- redis:7-alpine 内置 redis 用户 (UID 999)，支持非 root 运行
- `fsGroup: 999` 确保 PVC `/data` 可写（RDB/AOF 持久化）
- 不设 `readOnlyRootFilesystem`（Redis 需写入 /data）

#### 2.3 Sentinel (data-layer → baseline, 非 root)

同 Redis 配置，Pod 级别 `fsGroup: 999`，container 级别 `runAsUser: 999`。

- Init container 写 `/sentinel-data`（emptyDir），fsGroup 保证可写
- Sentinel 运行时动态修改 `sentinel.conf`（failover 时），需可写

#### 2.4 ProxySQL (data-layer → baseline, root)

```yaml
# Pod 级别
securityContext:
  runAsUser: 0
  runAsGroup: 0
  fsGroup: 0

# Container 级别
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

- `proxysql/proxysql:2.7.2` 官方镜像以 root 运行，无预置非 root 用户
- `runAsUser: 0` 明确声明 root 意图；baseline PSS 允许 root
- 防御：drop ALL caps + 禁止提权 + seccomp RuntimeDefault
- `/var/lib/proxysql` (emptyDir) 需可写

#### 2.5 Orchestrator (data-layer → baseline, root)

同 ProxySQL 配置模式。`openarkcode/orchestrator:latest` 以 root 运行，无预置非 root 用户。

**验证**：

```bash
kubectl get pod -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].securityContext.runAsUser}{"\n"}{end}'
kubectl get pods -A  # 全部 Running
```

---

### Step 3: Pod Security Standards

**目标**：为 namespace 添加 PSS 标签，强制安全基线。

| Namespace | Enforce | Audit | Warn | 说明 |
|-----------|---------|-------|------|------|
| app-layer | restricted | restricted | restricted | 短链应用已非 root，可强制最高级别 |
| data-layer | baseline | restricted | restricted | ProxySQL/Orchestrator 需 root，baseline 兼容 |

**修改文件**：

`k8s/app-layer/namespace.yaml` — labels 添加：
```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

`k8s/data-layer/namespace.yaml` — labels 添加：
```yaml
pod-security.kubernetes.io/enforce: baseline
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

**data-layer 选择 baseline 的原因**：ProxySQL 和 Orchestrator 镜像以 root 运行，无法通过 restricted 标准。`audit/warn: restricted` 会在审计日志中提示偏离 restricted 的行为，为未来升级留记录。

**验证**：
```bash
kubectl label ns app-layer --show-labels
kubectl get events -n app-layer --field-selector reason=FailedCreate   # 无事件
kubectl get events -n data-layer --field-selector reason=FailedCreate  # 无事件
```

---

### Step 4: RBAC（三层角色模型）

**目标**：建立 admin / developer / viewer 三层权限模型。

#### 4.1 角色模型

| 层级 | 账号 | 权限范围 | 实现方式 |
|------|------|---------|---------|
| admin | K3s 集群管理员 | cluster-admin | K3s 默认 k3s.yaml 证书 |
| developer | SA: `developer` | app-layer 内 CRUD | Role `app-developer` |
| viewer | SA: `viewer` | app-layer 内只读 | Role `app-viewer` |

Workload SA（shortlink-app, redis, proxysql, orchestrator）不调用 K8s API（使用 secretKeyRef 注入），绑定最小只读权限用于审计。

#### 4.2 新建文件

| 文件 | 内容 |
|------|------|
| `k8s/app-layer/rbac.yaml` | Role `app-developer`（CRUD）+ Role `app-viewer`（只读）+ 3 个 RoleBinding |
| `k8s/data-layer/rbac.yaml` | 3 个 RoleBinding（redis/proxysql/orchestrator → view ClusterRole） |

**app-developer Role 权限**：

- `""`: pods, pods/log, pods/exec, services, configmaps, secrets, serviceaccounts — CRUD
- `apps`: deployments, replicasets — CRUD
- `networking.k8s.io`: ingresses, networkpolicies — CRUD
- `autoscaling`: horizontalpodautoscalers — CRUD
- `policy`: poddisruptionbudgets — CRUD

**app-viewer Role 权限**：上述资源的 get/list/watch。

**验证**：
```bash
kubectl auth can-i get pods -n app-layer --as=system:serviceaccount:app-layer:developer   # yes
kubectl auth can-i delete pods -n app-layer --as=system:serviceaccount:app-layer:viewer    # no
kubectl auth can-i get pods -n data-layer --as=system:serviceaccount:data-layer:redis      # yes
```

---

### Step 5: ResourceQuota + LimitRange

**目标**：限制 namespace 资源总量，为 init container 补充资源限制。

#### 5.1 ResourceQuota

| Namespace | pods | req CPU | req Mem | lim CPU | lim Mem | PVC |
|-----------|------|---------|---------|---------|---------|-----|
| app-layer | 10 | 2 | 1Gi | 4 | 2Gi | 0 |
| data-layer | 20 | 3 | 2Gi | 6 | 4Gi | 6 |

#### 5.2 LimitRange（默认值）

| Namespace | default CPU | default Mem | defaultRequest CPU | defaultRequest Mem | max CPU | max Mem |
|-----------|-------------|-------------|--------------------|--------------------|---------|---------|
| app-layer | 200m | 128Mi | 100m | 64Mi | 1 | 512Mi |
| data-layer | 200m | 256Mi | 50m | 64Mi | 1 | 512Mi |

#### 5.3 Init Container Resources

为 3 个 init container 添加 `resources` 字段（requests: 10m/16Mi, limits: 100m/64Mi）：

| 文件 | Init Container |
|------|---------------|
| `k8s/data-layer/sentinel-statefulset.yaml` | `init-sentinel` |
| `k8s/data-layer/proxysql.yaml` | `render-config` |
| `k8s/data-layer/orchestrator.yaml` | `render-config` |

**验证**：
```bash
kubectl describe resourcequota -n app-layer
kubectl describe resourcequota -n data-layer
kubectl describe limitrange -n app-layer
kubectl describe limitrange -n data-layer
```

---

### Step 6: NetworkPolicy（白名单网络隔离）

**目标**：default deny + 白名单 allow，实现 Pod 间最小网络访问。

#### 6.1 网络流量矩阵

| # | 源 | 目标 | 端口 | 用途 |
|---|----|------|------|------|
| 1 | kube-system (Traefik) | app-layer/shortlink | 8080/TCP | Ingress 流量 |
| 2 | app-layer/shortlink | data-layer/proxysql | 6033/TCP | MySQL 读写分离 |
| 3 | app-layer/shortlink | data-layer/sentinel | 26379/TCP | Redis 服务发现 |
| 4 | app-layer/shortlink | data-layer/redis | 6379/TCP | Redis 直连 |
| 5 | data-layer/sentinel | data-layer/redis | 6379/TCP | Sentinel 监控 |
| 6 | data-layer/redis | data-layer/redis | 6379/TCP | 主从复制 |
| 7 | data-layer/sentinel | data-layer/sentinel | 26379/TCP | quorum 通信 |
| 8 | data-layer/proxysql | 192.168.1.0/24 | 3306/TCP | 外部 MySQL |
| 9 | data-layer/orchestrator | 192.168.1.0/24 | 3306/TCP | 外部 MySQL |
| 10 | data-layer/orchestrator | data-layer/proxysql | 6032/TCP | admin（故障切换） |
| 11 | kube-system (Traefik) | data-layer/orchestrator | 3000/TCP | Web UI（可选） |
| 12 | 所有 Pod | kube-system/coredns | 53/UDP+TCP | DNS |

#### 6.2 新建文件

| 文件 | 策略数 | 说明 |
|------|--------|------|
| `k8s/app-layer/networkpolicy.yaml` | 4 | deny-all-ingress + allow-from-traefik + allow-dns-egress + allow-to-data-layer |
| `k8s/data-layer/networkpolicy.yaml` | 7 | deny-all + allow-from-app-layer + allow-redis-internal + allow-orchestrator-to-proxysql + allow-dns-egress + allow-proxysql-to-mysql + allow-orchestrator-to-mysql + allow-traefik-to-orchestrator |

#### 6.3 关键设计决策

- **Redis Sentinel 完整流程覆盖**：短链应用 → Sentinel (26379) 获取 Master IP → 直连 Redis (6379)；Sentinel → Redis (6379) 监控；Sentinel ↔ Sentinel (26379) quorum。全部在 `allow-redis-internal` 和 `allow-to-data-layer` 中覆盖。
- **外部 MySQL 访问**：使用 `ipBlock: cidr: 192.168.1.0/24` 允许 VPC 子网内 3306 端口。额外允许 `10.43.0.0/16`（K3s Pod CIDR）以兼容 Service ClusterIP 访问。
- **Traefik hostNetwork 兼容**：K3s Traefik 使用 `hostNetwork: true`，通过 `namespaceSelector` 匹配 kube-system。如果源 IP 识别异常，备用方案为添加 `ipBlock: 192.168.1.0/24`。
- **部署顺序**：deny-all 和 allow-* 策略应在同一次 `kubectl apply` 中部署，避免中间状态阻断流量。

**验证**：
```bash
kubectl get networkpolicy -n app-layer
kubectl get networkpolicy -n data-layer

# 验证 DNS 正常
kubectl exec -n app-layer deploy/shortlink -- nslookup kubernetes.default.svc.cluster.local

# 验证 ProxySQL admin 端口被隔离（app-layer 不应能访问 6032）
kubectl exec -n app-layer deploy/shortlink -- wget -qO- --timeout=3 http://proxysql.data-layer.svc:6032 || echo "Blocked: expected"

# 验证数据连接正常
curl http://116.62.168.245/health   # {"status":"ok"}
```

---

### Step 7: Trivy CI 镜像扫描

**目标**：在 GitHub Actions CI 中集成 Trivy，阻断含 HIGH/CRITICAL 漏洞的镜像。

**修改文件**：`.github/workflows/build-deploy.yml`

**插入位置**：在 "Build and push Docker image" 之后、"Update Kustomization tag" 之前。

**新增步骤**：

```yaml
      - name: Trivy image scan
        uses: aquasecurity/trivy-action@0.29.0
        with:
          image-ref: ${{ steps.meta.outputs.full }}
          format: 'table'
          exit-code: 1
          ignore-unfixed: true
          vuln-type: 'os,library'
          severity: 'HIGH,CRITICAL'
        env:
          TRIVY_DB_REPOSITORY: ghcr.io/aquasecurity/trivy-db,public.ecr.aws/aquasecurity/trivy-db

      - name: Trivy scan (SARIF)
        if: always()
        uses: aquasecurity/trivy-action@0.29.0
        with:
          image-ref: ${{ steps.meta.outputs.full }}
          format: 'sarif'
          output: 'trivy-results.sarif'
          ignore-unfixed: true
          severity: 'HIGH,CRITICAL'

      - name: Upload Trivy SARIF results
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: 'trivy-results.sarif'
          category: trivy
```

**配置说明**：

| 参数 | 值 | 说明 |
|------|-----|------|
| exit-code | 1 | 发现漏洞时 CI 失败，阻止部署 |
| ignore-unfixed | true | 只报有修复版本的漏洞，减少噪音 |
| vuln-type | os,library | 扫描 OS 包 + Go 模块依赖 |
| severity | HIGH,CRITICAL | 仅高危级别触发失败 |
| TRIVY_DB_REPOSITORY | 双源 fallback | public.ecr.aws（国内无需代理）+ ghcr.io |

**CI 步骤序列**（更新后）：
1. Checkout → 2. Go vet/test → 3. Docker Buildx → 4. ACR Login → 5. Image tag → 6. Build & push → **7. Trivy scan (table)** → **8. Trivy SARIF + Upload** → 9. Update Kustomization → 10. Summary

---

## 5. 受影响文件总览

### 新建文件（7 个）

| 文件路径 | 步骤 | 说明 |
|---------|------|------|
| `k8s/app-layer/sa.yaml` | Step 1 | ServiceAccounts |
| `k8s/app-layer/rbac.yaml` | Step 4 | Roles + RoleBindings |
| `k8s/app-layer/networkpolicy.yaml` | Step 6 | NetworkPolicy |
| `k8s/data-layer/sa.yaml` | Step 1 | ServiceAccounts |
| `k8s/data-layer/rbac.yaml` | Step 4 | RoleBindings |
| `k8s/data-layer/networkpolicy.yaml` | Step 6 | NetworkPolicy |

### 修改文件（13 个）

| 文件路径 | 步骤 | 变更内容 |
|---------|------|---------|
| `k8s/app-layer/namespace.yaml` | 3, 5 | PSS labels + ResourceQuota + LimitRange |
| `k8s/app-layer/shortlink.yaml` | 1, 2 | serviceAccountName + securityContext |
| `k8s/app-layer/kustomization.yaml` | 1, 4, 6 | resources 添加 sa/rbac/networkpolicy |
| `k8s/data-layer/namespace.yaml` | 3, 5 | PSS labels + ResourceQuota + LimitRange |
| `k8s/data-layer/redis-statefulset.yaml` | 1, 2 | serviceAccountName + securityContext |
| `k8s/data-layer/sentinel-statefulset.yaml` | 1, 2, 5 | SA + SC + init container resources |
| `k8s/data-layer/proxysql.yaml` | 1, 2, 5 | SA + SC + init resources |
| `k8s/data-layer/orchestrator.yaml` | 1, 2, 5 | SA + SC + init resources |
| `k8s/data-layer/kustomization.yaml` | 1, 4, 6 | resources 添加 sa/rbac/networkpolicy |
| `.github/workflows/build-deploy.yml` | 7 | 插入 Trivy 扫描步骤 |

## 6. 部署顺序与回滚

### 推荐部署顺序

```
1. kustomization.yaml 更新（添加新文件引用）
2. 创建新文件（sa.yaml, rbac.yaml, networkpolicy.yaml）
3. Step 1: 部署 SA          → 验证 SA 创建
4. Step 2: 部署 SecurityContext → Pod 滚动重建 → 全部 Running
5. Step 3: 添加 PSS labels   → 确认无拒绝事件
6. Step 4: 部署 RBAC         → can-i 验证
7. Step 5: 部署 Quota        → describe 验证
8. Step 6: 部署 NetworkPolicy → 连通性测试
9. Step 7: 修改 CI workflow   → push 触发验证
```

### 回滚策略

| 步骤 | 回滚方式 |
|------|---------|
| SA/RBAC/PSS/Quota | `kubectl delete` 对应资源，或 git revert + FluxCD reconcile |
| SecurityContext | git revert，恢复 SC 为 null |
| NetworkPolicy | `kubectl delete networkpolicy --all -n app-layer; -n data-layer` |
| Trivy CI | git revert workflow |

## 7. 风险与注意事项

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|---------|
| 1 | SecurityContext 触发 Pod 重建 | Redis Master 轮换可能短暂影响服务 | 低流量时段执行；StatefulSet 逐个滚动 |
| 2 | NetworkPolicy deny-all 立即生效 | 中间状态可能阻断流量 | deny-all 和 allow-* 同一次 apply 部署 |
| 3 | ProxySQL 密码变更需同步 Orchestrator | Orchestrator 无法连接 ProxySQL | proxysql.yaml 和 orchestrator.yaml 同时修改 |
| 4 | readOnlyRootFilesystem 影响 shortlink | 未来 Go 应用需写 /tmp 时失败 | 需要时挂载 emptyDir 到 /tmp |
| 5 | Trivy DB 下载慢 | CI 耗时增加 | 双源 fallback（public.ecr.aws + ghcr.io） |
| 6 | Traefik hostNetwork 源 IP 问题 | allow-from-traefik 可能不生效 | 备用：添加 ipBlock 192.168.1.0/24 |
| 7 | Redis Sentinel 动态写 sentinel.conf | readOnlyRootFilesystem 会破坏 failover | 不对 Sentinel 设 readOnlyRootFilesystem |
| 8 | ProxySQL/Orchestrator root 运行 | 受限 PSS 无法通过 | data-layer 用 baseline；audit: restricted 留记录 |

## 8. 加固前后对比

| 安全维度 | 加固前 | 加固后 |
|---------|--------|--------|
| ServiceAccount | 全部 default | 6 个命名 SA |
| RBAC | 无 | 3 层角色模型（admin/developer/viewer） |
| NetworkPolicy | 无（flux-system 除外） | 白名单隔离，12 条 allow 规则 |
| SecurityContext | 无 | 非 root（app+redis）/ root+drop ALL（proxysql/orch） |
| PSS | 无标签 | app-layer=restricted, data-layer=baseline |
| 资源限制 | 无 | ResourceQuota + LimitRange + init container resources |
| CI 安全 | 无扫描 | Trivy HIGH/CRITICAL 阻断 + SARIF |

