# Phase 8：生产级加固（HTTPS + 密钥外置 + 巡检自动化）

## 1. 概述

将 `docs/project-future-expansion.md` 中标记为「✅ 已做」的 3 个规划项正式落地为 Phase 8，覆盖**传输安全**、**密钥管理**、**运维自动化**三大生产级能力：

| 模块 | 来源规划 | 原 P 级 | 核心价值 |
|------|---------|--------|---------|
| Phase 8.1 | HTTPS + cert-manager | P0 | 全链路加密，自动续签，消除"学生玩具"观感 |
| Phase 8.2 | External Secrets Operator | P0 | Secrets 纳入 GitOps，补齐全声明式最后一块拼图 |
| Phase 8.3 | 数据库自动巡检脚本 | P1 | 日常运维自动化意识，可展示的结构化巡检报告 |

**状态：计划已就绪，待执行**（本文档仅规划，不实际修改集群）

## 2. 三模块架构总览

```
┌──────────────────────────────────────────────────────────────────────┐
│                          外部用户 / 面试官                              │
│                (浏览器 → https://shortlink.example.com)                │
└───────────────────────────┬──────────────────────────────────────────┘
                            │  DNS A → 116.62.168.245:443
                ┌───────────▼────────────┐
                │  L7: Traefik (websecure) │  Ingress :443 + TLS
                │  cert-manager 注入证书    │
                └───────────┬────────────┘
                            │
        ┌───────────────────┼───────────────────────────┐
        │                   │                            │
┌───────▼──────┐   ┌────────▼─────────┐         ┌────────▼────────┐
│  app-layer   │   │  cert-manager    │         │ external-secrets│
│ shortlink    │   │  (cert-manager   │         │  (data-layer    │
│ (:8080 TLS)  │   │   ns, Cluster-   │         │   SecretStore + │
│              │   │   Issuer, Cert)  │         │   ExternalSecret)│
└───────┬──────┘   └────────┬─────────┘         └────────┬────────┘
        │                   │                            │
        │           ┌───────▼────────┐          ┌────────▼────────┐
        │           │ Let's Encrypt  │          │ 阿里云 Secrets  │
        │           │  (ACME HTTP-01)│          │  Manager (云上) │
        │           └────────────────┘          └─────────────────┘
        │
        ▼  MySQL 访问
┌──────────────────────────────────┐
│  物理机 MySQL (node-02/03)         │  ◄── Phase 8.3 巡检脚本 (cron, node-03)
│  脚本输出报告 → ossutil → OSS      │
└──────────────────────────────────┘
```

**三模块关系**：cert-manager 解决"传输加密"；external-secrets 解决"密钥来源外置"；巡检脚本解决"数据库日常可观测"。三者互不依赖，可独立部署，但均纳入 GitOps 体系管理。

## 3. 现状分析（增强前）

| # | 模块 | 当前状态 | 缺口 |
|---|------|---------|------|
| 1 | 传输安全 | 仅 HTTP `:80` 暴露，Ingress 无 TLS | 明文传输，无证书管理 |
| 2 | 密钥管理 | 手动 `kubectl create secret` + `.gitignore` 屏蔽 secret.yaml | Secrets 不在 GitOps 内，重建易丢 |
| 3 | 数据库运维 | 无自动巡检，靠人工排查 | 无趋势数据、无告警基线 |

**关键约束**：
- K3s 内置 Traefik 默认有 `web` (`:80`) 和 `websecure` (`:443`) 两个 entrypoint；`websecure` 需证书才能生效。
- Let's Encrypt HTTP-01 验证要求 `:80` 公网可达——当前 Traefik 已监听 `:80`，天然满足。
- 需申请一个廉价域名（约 20-30 元/年），A 记录指向 EIP `116.62.168.245`。
- ESO 云上后端选**阿里云 Secrets Manager**（免费额度足够，与现有 ACR/OSS 同账号体系）。
- 巡检脚本复用 Phase 7 已安装的 `ossutil`，报告推送同一 OSS bucket。

---

## 4. 实施计划

### 4.1 Phase 8.1 — HTTPS + cert-manager

**目标**：为短链服务启用 HTTPS（TLS 1.2+），证书由 cert-manager 自动向 Let's Encrypt 申请并续签（90 天有效期，到期前 30 天自动 Renew）。

#### 4.1.1 安装 cert-manager（GitOps 优先）

推荐用 FluxCD `HelmRelease` 安装（与项目 GitOps-first 理念一致），与现有 `clusters/production/*.yaml` 模式对齐。

**新建文件**：

| 文件 | 内容 |
|------|------|
| `clusters/production/cert-manager-install.yaml` | `HelmRepository`（jetstack  chart repo）+ `HelmRelease`（cert-manager，安装 CRD，`installCRDs: true`） |
| `k8s/cert-manager/namespace.yaml` | `cert-manager` namespace（带 `cert-manager.io/disable-validation: true` 避免自举死锁） |
| `k8s/cert-manager/clusterissuer-prod.yaml` | `ClusterIssuer` `letsencrypt-prod`（ACME 生产环境） |
| `k8s/cert-manager/clusterissuer-staging.yaml` | `ClusterIssuer` `letsencrypt-staging`（测试用，限流宽松，避免压爆生产 API） |
| `clusters/production/cert-manager.yaml` | FluxCD `Kustomization`（path `./k8s/cert-manager`，`dependsOn` cert-manager-install） |

**ClusterIssuer（prod）关键字段**：
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@example.com          # ← 替换为真实邮箱
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: traefik
```

> 备选方案：若暂不强求 GitOps，可手动 `helm install cert-manager jetstack/cert-manager --set installCRDs=true -n cert-manager`。但本计划采用 GitOps 方案以保持一致。

#### 4.1.2 修改 Ingress 添加 TLS

**修改文件**：`k8s/app-layer/ingress.yaml`

拆分为两个 Ingress 资源：
1. **主服务 Ingress**（`shortlink`）：绑定域名 `shortlink.example.com`，`websecure` entrypoint + TLS，cert-manager 自动签发。
2. **健康检查 Ingress**（`shortlink-health`）：无 host、`web` entrypoint、仅 `/health` 路径，保留 IP 直接访问能力（如 `http://116.62.168.245/health` 仍可裸 IP 健康检查）。

```yaml
# 主服务 Ingress（修改后）
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - shortlink.example.com
      secretName: shortlink-tls
  rules:
    - host: shortlink.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: shortlink, port: { number: 8080 } }
---
# 健康检查 Ingress（新增，保留 IP 访问）
metadata:
  name: shortlink-health
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
    - http:
        paths:
          - path: /health
            pathType: Exact
            backend:
              service: { name: shortlink, port: { number: 8080 } }
```

> 可选增强：配置 Traefik `middlewares.traefik.io` 的 `redirectscheme` 中间件，将 HTTP `:80` 自动 301 跳转到 HTTPS。本计划作为可选步骤列出，默认先保两套 Ingress 并存。

**Go 镜像适配**：Dockerfile 已包含 `ca-certificates` 包（phase-4 已验证），301 重定向目标若为 HTTPS 站点，Go 标准库可验证目标 TLS 证书，无需额外改动。

#### 4.1.3 验证

```bash
# cert-manager Pod 就绪
kubectl get pods -n cert-manager

# ClusterIssuer Ready
kubectl get clusterissuer letsencrypt-prod    # READY=True

# 证书签发（首次约 10-30s）
kubectl get certificate -n app-layer          # READY=True
kubectl get secret shortlink-tls -n app-layer # 存在

# HTTPS 访问
curl -vI https://shortlink.example.com/health # 200, 含 TLS 握手
curl -I  http://116.62.168.245/health          # 仍可用（健康检查 Ingress）

# 续签验证（调到 staging 签发后观察 Certificate 状态）
kubectl describe certificate shortlink-tls -n app-layer | grep "Renewal"
```

#### 4.1.4 文件影响

| 类型 | 文件 |
|------|------|
| 新建 | `clusters/production/cert-manager-install.yaml`、`k8s/cert-manager/namespace.yaml`、`k8s/cert-manager/clusterissuer-prod.yaml`、`k8s/cert-manager/clusterissuer-staging.yaml`、`clusters/production/cert-manager.yaml` |
| 修改 | `k8s/app-layer/ingress.yaml` |

---

### 4.2 Phase 8.2 — External Secrets Operator

**目标**：将 K8s Secret 的真正内容外置到**阿里云 Secrets Manager**，Git 仓库仅保留 `ExternalSecret` CR（声明"同步哪些密钥"），ESO 控制器负责拉取并渲染为 K8s Secret。补齐 GitOps 全声明式的最后一块拼图。

#### 4.2.1 安装 ESO（GitOps 优先）

**新建文件**：

| 文件 | 内容 |
|------|------|
| `clusters/production/external-secrets-install.yaml` | `HelmRepository`（external-secrets chart repo）+ `HelmRelease`（external-secrets） |
| `k8s/external-secrets/namespace.yaml` | `external-secrets` namespace |
| `k8s/external-secrets/secretstore-aliyun.yaml` | `SecretStore`（alibaba provider，指向 Secrets Manager，region `cn-hangzhou`） |
| `k8s/external-secrets/externalsecret-mysql.yaml` | `ExternalSecret` `mysql-credentials`（映射 5 个 key → data-layer/mysql-credentials） |
| `clusters/production/external-secrets.yaml` | FluxCD `Kustomization`（path `./k8s/external-secrets`，`dependsOn` external-secrets-install） |

#### 4.2.2 SecretStore 与 ExternalSecret 关键字段

```yaml
# SecretStore — 阿里云认证（ESO 自身 bootstrap 密钥）
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aliyun-secretstore
  namespace: data-layer
spec:
  provider:
    alibaba:
      region: cn-hangzhou
      auth:
        secretRef:
          accessKeyID:
            name: aliyun-eso-auth        # ← 手动创建的 bootstrap Secret
            key: accessKeyID
          accessKeySecret:
            name: aliyun-eso-auth
            key: accessKeySecret
---
# ExternalSecret — 同步 MySQL 凭证
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mysql-credentials
  namespace: data-layer
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aliyun-secretstore
    kind: SecretStore
  target:
    name: mysql-credentials             # 渲染出的 K8s Secret 名（与现有引用一致）
  data:
    - secretKey: monitor-password
      remoteRef: { key: /k3s/mysql/monitor-password }
    - secretKey: shortlink-password
      remoteRef: { key: /k3s/mysql/shortlink-password }
    - secretKey: orchestrator-password
      remoteRef: { key: /k3s/mysql/orchestrator-password }
    - secretKey: proxysql-admin-password
      remoteRef: { key: /k3s/mysql/proxysql-admin-password }
    - secretKey: proxysql-radmin-password
      remoteRef: { key: /k3s/mysql/proxysql-radmin-password }
```

#### 4.2.3 密钥迁移步骤

1. **创建 RAM 子账号**：仅授予 Secrets Manager 读权限（`AliyunRAMReadOnlyAccess` 不必要，用自定义策略限定 `kms:Decrypt` + `secretsmanager:GetSecretValue`）。
2. **在 Secrets Manager 写入 5 个密钥**：路径 `/k3s/mysql/*`，值来自 `group_vars/all.yml`（gitignored）的现有密码。
3. **手动创建 bootstrap Secret** `aliyun-eso-auth`（ESO 自身认证用，不能由 ESO 管理）：
   ```bash
   kubectl create secret generic aliyun-eso-auth -n data-layer \
     --from-literal=accessKeyID='<RAM_AK>' \
     --from-literal=accessKeySecret='<RAM_SK>'
   ```
4. **从 GitOps 移除静态 secret.yaml**：删除 `k8s/data-layer/kustomization.yaml` 中 `- secret.yaml` 引用，避免与 ESO 渲染的 Secret 冲突（`prune: true` 会误删）。保留 `secret.yaml.example` 作为模板参考。
5. **部署 ESO + ExternalSecret**，验证 `mysql-credentials` 被自动重建。

**修改文件**：
- `k8s/data-layer/kustomization.yaml` — 移除 `secret.yaml` 资源引用
- `ansible/group_vars/all.yml`（gitignored）+ `all.yml.example` — 新增 `aliyun_esm_access_key_id` / `aliyun_esm_access_key_secret` 变量（供文档与 RAM 配置参考）

#### 4.2.4 验证

```bash
# ESO 控制器就绪
kubectl get pods -n external-secrets

# ExternalSecret 同步成功
kubectl get externalsecret -n data-layer    # READY=True
kubectl get secret mysql-credentials -n data-layer   # 被 ESO 重建

# 破坏性验证：删除 Secret → ESO 自动重建
kubectl delete secret mysql-credentials -n data-layer
sleep 10
kubectl get secret mysql-credentials -n data-layer   # 已重建

# 业务功能不受影响
curl http://116.62.168.245/health   # {"status":"ok"}
```

#### 4.2.5 文件影响

| 类型 | 文件 |
|------|------|
| 新建 | `clusters/production/external-secrets-install.yaml`、`k8s/external-secrets/namespace.yaml`、`k8s/external-secrets/secretstore-aliyun.yaml`、`k8s/external-secrets/externalsecret-mysql.yaml`、`clusters/production/external-secrets.yaml` |
| 修改 | `k8s/data-layer/kustomization.yaml`、`ansible/group_vars/all.yml.example` |
| 移除（出 GitOps） | `k8s/data-layer/secret.yaml`（保留 `.example`） |

---

### 4.3 Phase 8.3 — 数据库自动巡检脚本

**目标**：在 MySQL Slave（node-03）上以 cron 每周执行一次结构化巡检，覆盖空间/碎片/慢查询/复制/连接/性能/错误日志 7 个维度，报告经 `ossutil` 推送 OSS，形成可对比的趋势基线。

#### 4.3.1 新建巡检脚本

**新建文件**：`scripts/db-inspect.sh`

脚本遵循 `scripts/xtrabackup-backup.sh` 的约定（`#!/usr/bin/env bash` + `set -euo pipefail` + 段注释 + `${VAR:-default}`），核心逻辑：

```bash
#!/usr/bin/env bash
# db-inspect.sh -- MySQL 自动巡检 (在 node-03 / Slave 执行)
# 输出结构化报告 → ossutil 推送 OSS
# Cron: 0 2 * * 0 /usr/local/bin/db-inspect.sh >> /var/log/db-inspect.log 2>&1

set -euo pipefail

MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-CHANGE_ME}"   # 从 /root/.my.cnf 读取
OSS_BUCKET="${OSS_BUCKET:-k3s-backup-velero}"
OSS_PREFIX="${OSS_PREFIX:-mysql-inspect}"
OSSUTIL_BIN="${OSSUTIL_BIN:-/usr/local/bin/ossutil}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-hangzhou-internal.aliyuncs.com}"
REPORT_DIR="${REPORT_DIR:-/var/log/mysql-inspect}"
DATE="$(date +%Y%m%d)"
REPORT="${REPORT_DIR}/mysql-inspect-${DATE}.txt"

mkdir -p "${REPORT_DIR}"

# ── 巡检函数（每个维度一个 section）──────────────
# 1. 基础信息: SELECT VERSION(); Uptime; SHOW REPLICA STATUS (IO/SQL 线程 + Seconds_Behind_Source)
# 2. 空间概览: 总数据量 + TOP10 表 (DATA_LENGTH 排序) + 最大表
# 3. 碎片率:   DATA_FREE/DATA_LENGTH > 0.3 的表
# 4. 慢查询:   mysqldumpslow -s t -t 10 /var/lib/mysql/*-slow.log
# 5. 复制延迟: SHOW REPLICA STATUS → Seconds_Behind_Source
# 6. 连接:     SHOW PROCESSLIST → 活跃连接数 + 来源 IP
# 7. 性能:     SHOW STATUS LIKE 'innodb_buffer_pool_read%' → 命中率 = (1 - reads/reads_total)*100
# 8. 错误:     grep -i error /var/log/mysql/*.err (近 7 天)

# 每个 section 写入 $REPORT, 打印分隔线 + 标题

# ── 推送 OSS ───────────────────────────────────────
"${OSSUTIL_BIN}" cp "${REPORT}" "oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${REPORT}")" -e "${OSS_ENDPOINT}"
echo "Inspection report pushed: oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${REPORT}")"
```

**巡检输出格式**（与 future-expansion 规划一致）：
```
========================================
 MySQL 巡检报告
 时间: 2026-07-25 02:00
 节点: k3s-node-03 (Slave)
========================================
[基础信息]
 MySQL 版本: 8.0.46
 运行时间: 30 天 4 小时
 复制状态: ✅ IO 线程 Running, SQL 线程 Running
 复制延迟: 0 秒
[空间概览]
 总数据量: 771 MB
 最大表: shortlink.url_mapping (520 MB)
 碎片率 >30% 的表: 无 ✅
[性能]
 Buffer Pool 命中率: 99.7%
 慢查询 (上周): 3 条
 活跃连接: 2
[告警]
 无
========================================
```

#### 4.3.2 新建 Ansible 部署 playbook

**新建文件**：`ansible/playbooks/08-db-inspect.yml`

职责：
1. 将 `scripts/db-inspect.sh` 拷贝到 node-03 `/usr/local/bin/`，`mode: 0755`
2. 确保 node-03 上 `/root/.my.cnf` 存在（MySQL 客户端凭证，`[client]` 段）
3. 确保 `ossutil` 已安装（Phase 7 已装，playbook 用 `command: which ossutil` 幂等检查）
4. 添加 cron：`0 2 * * 0 /usr/local/bin/db-inspect.sh >> /var/log/db-inspect.log 2>&1`（`ansible.builtin.cron` 模块，`name: mysql-inspect`）

遵循现有 playbook 约定（`become: true`、`serial: 1`、幂等 `changed_when`/`when` 守卫）。

**修改文件**：`ansible/group_vars/all.yml`（gitignored）+ `all.yml.example` — 若需新增巡检相关变量（如 `db_inspect_oss_prefix`），补充到 OSS 配置段。

#### 4.3.3 验证

```bash
# 手动执行（dry-run 不可用时直接跑一次）
ssh k3s-node-03 "sudo /usr/local/bin/db-inspect.sh"
# 或本地拷贝后执行
scp scripts/db-inspect.sh k3s-node-03:/tmp/ && ssh k3s-node-03 "sudo mv /tmp/db-inspect.sh /usr/local/bin/ && sudo chmod 755 /usr/local/bin/db-inspect.sh && sudo /usr/local/bin/db-inspect.sh"

# 检查报告生成
ssh k3s-node-03 "cat /var/log/mysql-inspect/mysql-inspect-*.txt | head -30"

# 检查 OSS 推送
ossutil ls oss://k3s-backup-velero/mysql-inspect/

# 检查 cron 注册
ssh k3s-node-03 "sudo crontab -l | grep db-inspect"
```

#### 4.3.4 文件影响

| 类型 | 文件 |
|------|------|
| 新建 | `scripts/db-inspect.sh`、`ansible/playbooks/08-db-inspect.yml` |
| 修改 | `ansible/group_vars/all.yml.example` |

---

## 5. 受影响文件总览

### 新建文件（11 个）

| 文件路径 | 模块 | 说明 |
|---------|------|------|
| `clusters/production/cert-manager-install.yaml` | 8.1 | HelmRepository + HelmRelease 安装 cert-manager |
| `k8s/cert-manager/namespace.yaml` | 8.1 | cert-manager namespace |
| `k8s/cert-manager/clusterissuer-prod.yaml` | 8.1 | ClusterIssuer（生产） |
| `k8s/cert-manager/clusterissuer-staging.yaml` | 8.1 | ClusterIssuer（测试） |
| `clusters/production/cert-manager.yaml` | 8.1 | FluxCD Kustomization |
| `clusters/production/external-secrets-install.yaml` | 8.2 | HelmRepository + HelmRelease 安装 ESO |
| `k8s/external-secrets/namespace.yaml` | 8.2 | external-secrets namespace |
| `k8s/external-secrets/secretstore-aliyun.yaml` | 8.2 | SecretStore（阿里云） |
| `k8s/external-secrets/externalsecret-mysql.yaml` | 8.2 | ExternalSecret（MySQL 凭证） |
| `clusters/production/external-secrets.yaml` | 8.2 | FluxCD Kustomization |
| `scripts/db-inspect.sh` | 8.3 | 数据库巡检脚本 |
| `ansible/playbooks/08-db-inspect.yml` | 8.3 | Ansible 部署 playbook |

### 修改文件（5 个）

| 文件路径 | 模块 | 变更内容 |
|---------|------|---------|
| `k8s/app-layer/ingress.yaml` | 8.1 | 拆分主/健康 Ingress，添加 TLS + cert-manager annotation |
| `k8s/data-layer/kustomization.yaml` | 8.2 | 移除 `secret.yaml` 引用（ESO 接管） |
| `ansible/group_vars/all.yml.example` | 8.2 / 8.3 | 新增 ESM + 巡检相关变量说明 |
| `k8s/data-layer/secret.yaml` | 8.2 | 移出 GitOps 管理（保留 `.example`） |
| `README.md` | 全 | Phase 8 路线图状态更新 |

## 6. 部署顺序与回滚

### 推荐部署顺序

```
Phase 8.1 (HTTPS):
  1. 部署 cert-manager-install (HelmRelease) → 等待 CRD + Pod Ready
  2. 部署 cert-manager Kustomization (namespace + ClusterIssuer ×2)
  3. 修改 ingress.yaml (TLS + annotation) → 验证证书签发 + HTTPS 访问
  4. 验证健康检查 Ingress 仍可用 (IP 裸访问)

Phase 8.2 (ESO):
  5. 创建 RAM 子账号 + Secrets Manager 写入 5 密钥
  6. 手动创建 bootstrap Secret aliyun-eso-auth
  7. 部署 external-secrets-install (HelmRelease)
  8. 部署 external-secrets Kustomization (SecretStore + ExternalSecret)
  9. 修改 data-layer/kustomization.yaml 移除 secret.yaml → 验证 ESO 重建 Secret

Phase 8.3 (巡检):
  10. 编写 db-inspect.sh + 08-db-inspect.yml
  11. Ansible 部署到 node-03 + 注册 cron
  12. 手动执行验证报告生成 + OSS 推送
```

> 三个模块无相互依赖，可单独执行、单独回滚；推荐顺序为先 8.1（传输安全最显眼）、再 8.2（密钥治理）、最后 8.3（运维自动化）。

### 回滚策略

| 模块 | 回滚方式 |
|------|---------|
| 8.1 cert-manager | `kubectl delete -f` 安装资源 + 还原 ingress.yaml 为 HTTP-only；证书 Secret 残留无副作用 |
| 8.2 ESO | `kubectl delete externalsecret`；还原 `data-layer/kustomization.yaml` 加回 `secret.yaml`；手动 `kubectl apply -f secret.yaml` 恢复静态 Secret |
| 8.3 巡检 | `ansible` 删除 cron + 脚本；或停用 cron 任务 `crontab -r`（针对性） |

## 7. 风险与注意事项

| # | 模块 | 风险 | 影响 | 缓解措施 |
|---|------|------|------|---------|
| 1 | 8.1 | Let's Encrypt 生产 API 限流（同一域名每周 50 张） | 证书签发失败 | 先用 staging Issuer 验证流程，再切 prod |
| 2 | 8.1 | HTTP-01 要求 `:80` 公网可达 | 验证失败 | Traefik 已监听 `:80`；确认安全组/防火墙放行 80/443 |
| 3 | 8.1 | cert-manager 自举死锁（webhook 校验自身） | 安装卡住 | namespace 加 `cert-manager.io/disable-validation: true` |
| 4 | 8.1 | 主 Ingress 加 host 后裸 IP 无法访问 | `curl <EIP>` 失效 | 保留独立健康检查 Ingress（`/health`，无 host） |
| 5 | 8.2 | ESO bootstrap Secret 与 ESO 管理的 Secret 同名冲突 | 循环依赖 | bootstrap `aliyun-eso-auth` 单独手动创建，不进 GitOps |
| 6 | 8.2 | 移除 secret.yaml 后 ESO 未同步成功 | Pod 启动缺 Secret | 先确认 ExternalSecret READY 再移除静态 Secret |
| 7 | 8.2 | Secrets Manager 不可用 | 无法刷新新版本 | 已有 K8s Secret 不受影响（Operator 缓存），业务无感知 |
| 8 | 8.3 | 巡检脚本在 Master 跑占用资源 | 影响写入 | 固定 node-03（Slave，只读）执行 |
| 9 | 8.3 | ossutil 未安装 | 报告推送失败 | playbook 幂等检查 `which ossutil`（Phase 7 已装） |

## 8. 增强前后对比

| 维度 | 增强前 | 增强后 |
|------|--------|--------|
| 传输安全 | HTTP 明文 `:80` | HTTPS `:443` + cert-manager 自动续签 |
| 证书管理 | 无 | ClusterIssuer + Certificate，90 天自动 Renew |
| 密钥来源 | 手动 `kubectl create` + gitignore | 阿里云 Secrets Manager + ExternalSecret 同步 |
| GitOps 完整性 | Secrets 不在 Git 内 | 全声明式（ExternalSecret CR 在 Git） |
| 数据库可观测 | 人工排查 | 每周结构化巡检报告 + OSS 趋势留存 |
| 域名访问 | 仅 IP | 域名 + 证书（面试可直接演示 https） |

## 9. 下一步

- 回顾 Phase 1-7 整体架构，编写 `README.md` 终版与架构图
- 可选：Kyverno 策略即代码（P1，当前为「📖 了解」）、Canary 灰度发布（依赖可观测性项目）
- 简历文档整理：将 Phase 1-8 统一沉淀为「项目经历」描述
