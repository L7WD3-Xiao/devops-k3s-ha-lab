# Phase 8：生产级加固（HTTPS + 巡检自动化）

## 1. 概述

Phase 8，该部分供拓展阅读，覆盖**传输安全**、**运维自动化**两大生产级能力：

| 模块 | 来源规划 | 原 P 级 | 核心价值 |
|------|---------|--------|---------|
| Phase 1 | HTTPS + cert-manager | P0 | 全链路加密，自动续签，消除"学生玩具"观感 |
| Phase 2 | 数据库自动巡检脚本 | P1 | 日常运维自动化意识，可展示的结构化巡检报告 |

> **原规划的 ESO（External Secrets Operator）模块已移除**：ESO 官方支持的 48 个 provider 中不包含阿里云（Alibaba/AliCloud），无法直接对接阿里云 Secrets Manager。当前 `secret.yaml` 已 gitignored + `.example` 模板入库，安全性已满足项目要求，故放弃 ESO 模块。

## 2. 两模块架构总览

```
┌──────────────────────────────────────────────────────────────────────┐
│                          内网客户端                                    │
│                (浏览器 → https://shortlink.internal)                  │
└───────────────────────────┬──────────────────────────────────────────┘
                            │  内网 DNS → 192.168.1.228:443
                ┌───────────▼────────────┐
                │  L7: Traefik (websecure) │  Ingress :443 + TLS
                │  cert-manager 注入证书    │
                └───────────┬────────────┘
                            │
        ┌───────────────────┼───────────────────────────────┐
        │                   │                               │
┌───────▼──────┐   ┌────────▼─────────┐              ┌──────▼──────────┐
│  app-layer   │   │  cert-manager    │              │ Phase 2 巡检脚本 │
│ shortlink    │   │  (selfSigned →   │              │ (cron, node-03) │
│ (:8080 TLS)  │   │   根CA → CA      │              │                 │
│              │   │   Issuer → Cert) │              │                 │
└───────┬──────┘   └────────┬─────────┘              └──────┬──────────┘
        │                   │                               │
        │           ┌───────▼────────┐                      │
        │           │ 自签根 CA       │                      │
        │           │ (10年/公钥分发) │                       │
        │           └────────────────┘                      │
        │                                                   │
        ▼  MySQL 访问                                        ▼
┌──────────────────────────────────┐               ┌───────────────────┐
│  物理机 MySQL (node-02/03)        │◄──────────────│ 巡检报告 → ossutil │
│                                  │    只读查询     │ → OSS (趋势留存)   │
└──────────────────────────────────┘               └───────────────────┘
```

**两模块关系**：cert-manager（自签 CA 两阶段签发）解决"传输加密"；巡检脚本解决"数据库日常可观测"。两者互不依赖，可独立部署，但均纳入 GitOps 体系管理。

> **与原计划的关键差异**：因域名仅用于内网验证，不使用公网 CA（Let's Encrypt ACME 需公网 DNS + `:80` 可达，内网无法满足），改用 cert-manager selfSigned Issuer 签发私有根 CA，再由 CA Issuer 签发服务证书。客户端需手动导入根 CA 公钥以建立信任链。

## 3. 现状分析（增强前）

| # | 模块 | 当前状态 | 缺口 |
|---|------|---------|------|
| 1 | 传输安全 | 仅 HTTP `:80` 暴露，Ingress 无 TLS | 明文传输，无证书管理 |
| 2 | 数据库运维 | 无自动巡检，靠人工排查 | 无趋势数据、无告警基线 |

**关键约束**：
- K3s 内置 Traefik 默认有 `web` (`:80`) 和 `websecure` (`:443`) 两个 entrypoint；`websecure` 需证书才能生效。
- **域名仅用于内网验证**，不对外提供服务，无需 ICP 备案、无需公网 DNS。使用内网域名 `shortlink.internal`，通过客户端 `/etc/hosts` 或 CoreDNS hosts 插件解析到 `192.168.1.228`（node-01 内网 IP）。
- **不使用公网 CA**：Let's Encrypt ACME 验证要求公网 DNS + `:80` 公网可达，内网域名无法满足。改用 cert-manager selfSigned Issuer 签发私有根 CA（10 年），再由 CA Issuer 签发服务证书（1 年，自动续签）。
- 客户端需手动导入根 CA 公钥到系统信任存储，否则浏览器/curl 报「不信任」错误。
- 巡检脚本复用 Phase 7 已安装的 `ossutil`，报告推送同一 OSS bucket。

---

## 4. 实施步骤

### 4.1 Phase 1 — HTTPS + cert-manager

**目标**：为短链服务全量启用 HTTPS（TLS 1.2+），证书由 cert-manager 通过 selfSigned → CA Issuer 两阶段签发（私有根 CA 10 年，服务证书 90 天自动 Renew）。因域名仅内网使用，不依赖公网 CA。

#### ⚠️ 与原计划的差异

> 因 Phase 6 在  2C2G node-01 上 OOM 了，这部分没用 FluxCD 控制，内容仅供参考

| 原计划 | 实际 | 原因 |
|--------|------|------|
| FluxCD HelmRelease 安装 | **手动 Helm install** | Phase-7 演练后 FluxCD 缩到 0 未恢复 |
| `clusters/production/cert-manager-install.yaml` | **未创建** | 未使用 FluxCD，无需 HelmRelease CR |
| `clusters/production/cert-manager.yaml` | **未创建** | 未使用 FluxCD，无需 Kustomization CR |
| `charts.jetstack.io` 通过 HelmRepository 访问 | **节点直接 helm repo add** | node-01 可直连 charts.jetstack.io（HTTP 200） |
| `image.repository` 覆盖为 d.m.daocloud.io | **quay.m.daocloud.io** | daocloud 提供 quay.io 镜像代理 |
| cert-manager 由调度器分配节点 | **nodeSelector=node-01** | node-02/03 无外网访问，拉取失败 |

#### 实际安装步骤

##### Step 1 安装 Helm CLI（node-01 缺少 Helm）

```bash
curl -sL https://get.helm.sh/helm-v3.16.0-linux-amd64.tar.gz -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp/
sudo mv /tmp/linux-amd64/helm /usr/local/bin/helm
rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
```

##### Step 2 安装 cert-manager

```bash
# 创建 namespace（需 disable-validation 注解避免自举死锁）
kubectl create ns cert-manager
kubectl annotate ns cert-manager cert-manager.io/disable-validation=true

# 添加 Helm repo
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

# 安装 cert-manager（v1.21.0，daocloud 镜像代理，nodeSelector=node-01）
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true \
  --set image.repository=quay.m.daocloud.io/jetstack/cert-manager-controller \
  --set image.tag=v1.16.0 \
  --set webhook.image.repository=quay.m.daocloud.io/jetstack/cert-manager-webhook \
  --set webhook.image.tag=v1.16.0 \
  --set cainjector.image.repository=quay.m.daocloud.io/jetstack/cert-manager-cainjector \
  --set cainjector.image.tag=v1.16.0 \
  --set startupapicheck.image.repository=quay.m.daocloud.io/jetstack/cert-manager-startupapicheck \
  --set startupapicheck.image.tag=v1.16.0 \
  --set 'nodeSelector.kubernetes\.io/hostname=node-01' \
  --set 'webhook.nodeSelector.kubernetes\.io/hostname=node-01' \
  --set 'cainjector.nodeSelector.kubernetes\.io/hostname=node-01' \
  --set 'startupapicheck.nodeSelector.kubernetes\.io/hostname=node-01' \
  --wait --timeout=5m
```

> **关键陷阱**：首次安装未设置 `nodeSelector`，3 个 cert-manager pod + startupapicheck job 全部调度到 **node-02**，因 node-02 无外网，镜像拉取超时（`ImagePullBackOff` → `i/o timeout`）。必须强制调度到 node-01。

##### Step 3 创建两阶段 ClusterIssuer + 根 CA

**阶段 1：selfSigned Issuer → 根 CA**
```yaml
# k8s/cert-manager/clusterissuer-selfsigned.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: k3s-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: k3s-internal-ca
  duration: 87600h              # 10 年
  secretName: k3s-root-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
```

**阶段 2：CA Issuer（引用根 CA 签发服务证书）**
```yaml
# k8s/cert-manager/clusterissuer-ca.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ca-issuer
spec:
  ca:
    secretName: k3s-root-ca-secret
```

应用：
```bash
kubectl apply -f k8s/cert-manager/clusterissuer-selfsigned.yaml
kubectl apply -f k8s/cert-manager/clusterissuer-ca.yaml
```

##### Step 4 修改 Ingress 添加 TLS

拆分为两个 Ingress 资源（`k8s/app-layer/ingress.yaml`）：

1. **主服务 Ingress**（`shortlink`）：绑定域名 `shortlink.internal`，`websecure` entrypoint + TLS，cert-manager 自动签发。
2. **健康检查 Ingress**（`shortlink-health`）：无 host、`web` entrypoint、仅 `/health` 路径，保留 IP 直接访问。

```bash
kubectl apply -f k8s/app-layer/ingress.yaml
```

##### Step 5 验证 HTTPS

```bash
# 1. 确认 cert-manager Pod 就绪
kubectl get pods -n cert-manager
# cert-manager-xxx              1/1 Running  node-01
# cert-manager-cainjector-xxx   1/1 Running  node-01
# cert-manager-webhook-xxx      1/1 Running  node-01

# 2. 确认 Issuer + 根 CA
kubectl get clusterissuer
# selfsigned-issuer   READY=True
# ca-issuer           READY=True
kubectl get certificate -n cert-manager k3s-root-ca
# READY=True  (10年有效期)

# 3. 确认服务证书签发（由 ingress-shim 自动创建）
kubectl get certificate -n app-layer
# shortlink-tls  READY=True  issuer=ca-issuer
kubectl get secret -n app-layer shortlink-tls
# kubernetes.io/tls  3 data

# 4. 导出根 CA 公钥
kubectl get secret k3s-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > k3s-ca.pem

# 5. HTTPS 访问验证（需绕过 DNS 或加 hosts）
curl -I --resolve shortlink.internal:443:127.0.0.1 \
  --cacert k3s-ca.pem https://shortlink.internal/health
# HTTP/2 404（shortlink app 返回 404，但 TLS 握手成功）

# 6. 健康检查 Ingress 仍可用
curl -I http://192.168.1.228/health
# HTTP/1.1 404（健康检查虽 404，但流量经 HTTP :80 到达短链服务）
```

##### 根 CA 指纹

```
SHA256 Fingerprint=8B:2C:5C:4E:C4:CF:2E:2B:D9:11:6D:39:43:6F:81:E3:AA:27:74:83:D9:2F:F6:CC:15:93:B9:C2:19:A2:01:B5
```

##### 文件影响

| 类型 | 文件 | 说明 |
|------|------|------|
| 新建 | `k8s/cert-manager/namespace.yaml` | cert-manager namespace（含 disable-validation 注解） |
| 新建 | `k8s/cert-manager/clusterissuer-selfsigned.yaml` | selfSigned ClusterIssuer + 根 CA Certificate（ECDSA, 10 年） |
| 新建 | `k8s/cert-manager/clusterissuer-ca.yaml` | CA ClusterIssuer（用根 CA 签服务证书） |
| 修改 | `k8s/app-layer/ingress.yaml` | 拆分为主 Ingress（TLS）+ 健康检查 Ingress（HTTP） |
| 未创建 | ~~`clusters/production/cert-manager-install.yaml`~~ | FluxCD 未恢复，手动 Helm 安装替代 |
| 未创建 | ~~`clusters/production/cert-manager.yaml`~~ | FluxCD 未恢复，手动 kubectl apply 替代 |

#### 内网 DNS 配置

`shortlink.internal` 域名需解析到集群入口。按场景选一种方案：

| 方案 | 适用场景 | 配置 |
|------|---------|------|
| 客户端 `/etc/hosts` | 单机演示 | 追加 `192.168.1.228 shortlink.internal` |
| CoreDNS hosts 插件 | 集群内 Pod 访问 | K3s CoreDNS ConfigMap 加 hosts 段 |
| 内网自建 DNS（dnsmasq） | 多客户端长期使用 | 指向 node-01 内网 IP `192.168.1.228` |

客户端信任根 CA 后，即可用 `curl https://shortlink.internal/health` 访问。

> **可选增强**：配置 Traefik `middlewares.traefik.io` 的 `redirectscheme` 中间件，将 HTTP `:80` 自动 301 跳转到 HTTPS。当前两套 Ingress 并存，HTTP 和 HTTPS 均可访问。

---

### 4.2 Phase 2 — 数据库自动巡检脚本

**目标**：在 MySQL Slave（node-03）上以 cron 每周执行一次结构化巡检，覆盖空间/碎片/慢查询/复制/连接/性能/错误日志 7 个维度，报告经 `ossutil` 推送 OSS，形成可对比的趋势基线。

#### Step 1 新建巡检脚本

**新建文件**：`scripts/db-inspect.sh`

脚本遵循 `scripts/xtrabackup-backup.sh` 的约定（`#!/usr/bin/env bash` + `set -euo pipefail` + 段注释 + `${VAR:-default}`），核心逻辑：

```bash
#!/usr/bin/env bash
# db-inspect.sh -- MySQL 自动巡检 (在 node-03 / Slave 执行)
# 输出结构化报告 → ossutil 推送 OSS
# Cron: 0 2 * * 0 /usr/local/bin/db-inspect.sh >> /var/log/db-inspect.log 2>&1

set -euo pipefail

MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"   # 密码由 /root/.my.cnf [client] 提供
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
#  错误:     grep -i error /var/log/mysql/*.err (近 7 天)

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

#### 实际部署

**部署方式**：由于 Ansible 控制节点不在开发机上，脚本通过 SSH jump 直接拷贝到 node-03：

```bash
# 拷贝脚本
cat scripts/db-inspect.sh | ssh -J k3s-node-01 ops@192.168.1.229 \
  "sudo tee /usr/local/bin/db-inspect.sh > /dev/null && sudo chmod 755 /usr/local/bin/db-inspect.sh"

# 注册 cron（每周日 02:00）
ssh -J k3s-node-01 ops@192.168.1.229 \
  'sudo crontab -l 2>/dev/null | grep -q db-inspect || \
    (sudo crontab -l 2>/dev/null; echo "0 2 * * 0 /usr/local/bin/db-inspect.sh >> /var/log/db-inspect.log 2>&1") | \
    sudo crontab -'
```

**Ansible playbook** `ansible/playbooks/08-db-inspect.yml` 已编写完成，当 Ansible 控制节点可用时可直接使用，功能一致。

> 巡检脚本的 OSS 配置（bucket/prefix/endpoint）均通过 `${VAR:-default}` 内置默认值，与 Phase 7 xtrabackup 脚本复用同一套 OSS 参数，无需额外修改 `all.yml.example`。

#### 验证结果

```bash
# 手动执行（dry-run）
sudo /usr/local/bin/db-inspect.sh --dry-run

# 手动执行（仅生成报告，不推送 OSS）
sudo /usr/local/bin/db-inspect.sh --local
# Output:
#   Report generated (local-only): /var/log/mysql-inspect/mysql-inspect-20260728-134605.txt
#   101 /var/log/mysql-inspect/mysql-inspect-20260728-134605.txt

# 手动执行（全量，含 OSS 推送）
sudo /usr/local/bin/db-inspect.sh
# Output:
#   --- Pushing report to OSS: k3s-backup-velero/mysql-inspect/ ---
#   Succeed: Total num: 1, size: 6,767. OK num: 1(upload 1 files).
#   OSS location: oss://k3s-backup-velero/mysql-inspect/mysql-inspect-20260728-134749.txt

# 检查报告内容
cat /var/log/mysql-inspect/mysql-inspect-20260728-134605.txt | head -30

# 检查 OSS 文件
ossutil ls oss://k3s-backup-velero/mysql-inspect/

# 检查 cron
sudo crontab -l | grep db-inspect
# 0 2 * * 0 /usr/local/bin/db-inspect.sh >> /var/log/db-inspect.log 2>&1
```

**实际输出示例**（2026-07-28 巡检报告摘要）：

| 检测项 | 结果 |
|--------|------|
| MySQL 版本 | 8.0.46 |
| 运行时间 | 20 小时 |
| 复制状态 | ✅ IO/SQL Running, 延迟 0s |
| 主库地址 | 192.168.1.230 (node-02) |
| 总数据量 | 1.36 MB |
| 最大表 | orchestrator.topology_recovery (0.13 MB) |
| 碎片 >30% | 无 ✅ |
| Buffer Pool 命中率 | 99.99% |
| 活跃连接 | 8 / 100 |
| 近 7 天 ERROR 日志 | 3 条（均为历史复制错误，已恢复） |
| 告警 | 无 ✅ |

#### 文件影响

| 类型 | 文件 | 说明 |
|------|------|------|
| 新建 | `scripts/db-inspect.sh` | 7 维度巡检脚本（101 行报告输出） |
| 新建 | `ansible/playbooks/08-db-inspect.yml` | Ansible 部署 playbook（待接入 Ansible 控制节点后使用） |

---

## 5. 受影响文件总览

### 新建文件（5 个）

| 文件路径 | 模块 | 说明 |
|---------|------|------|
| `k8s/cert-manager/namespace.yaml` | 1 | cert-manager namespace（含 disable-validation 注解） |
| `k8s/cert-manager/clusterissuer-selfsigned.yaml` | 1 | selfSigned ClusterIssuer + 根 CA Certificate（ECDSA, 10 年） |
| `k8s/cert-manager/clusterissuer-ca.yaml` | 1 | CA ClusterIssuer（用根 CA 签服务证书） |
| `scripts/db-inspect.sh` | 2 | 数据库巡检脚本 |
| `ansible/playbooks/08-db-inspect.yml` | 2 | Ansible 部署 playbook |

> **相比原计划减少 2 个文件**：`clusters/production/cert-manager-install.yaml` 和 `clusters/production/cert-manager.yaml` 因 FluxCD 已缩至 0 未创建，改用手动 Helm install + kubectl apply。

### 修改文件（1 个）

| 文件路径 | 模块 | 变更内容 |
|---------|------|---------|
| `k8s/app-layer/ingress.yaml` | 1 | 拆分为短链主 Ingress（TLS + shortlink.internal）+ 健康检查 Ingress（HTTP IP 访问） |

> **README.md**：状态标记已在 Phase 7 提交时更新为「进行中」，本次完成后需手动标记为「已发布」。

## 6. 实际部署顺序与回滚

### 实际执行顺序

```
Phase 1 (HTTPS):
  1. 安装 Helm CLI → helm repo add jetstack → helm install cert-manager
  2. kubectl apply ClusterIssuer (selfsigned-issuer → k3s-root-ca → ca-issuer)
  3. 修改 ingress.yaml (TLS + ca-issuer annotation)
  4. 验证证书签发 + HTTPS 访问
  5. 导出根 CA 公钥 (k3s-ca.pem) → 分发到客户端信任存储

Phase 2 (巡检):
  6. 编写 scripts/db-inspect.sh + ansible/playbooks/08-db-inspect.yml
  7. SSH 部署到 node-03 + 注册 cron (每周日 02:00)
  8. 手动执行验证报告生成 + OSS 推送
```

> 两个模块无相互依赖，可单独执行、单独回滚。

### 回滚策略

| 模块 | 回滚方式 |
|------|---------|
| 1 cert-manager | `helm uninstall cert-manager -n cert-manager` + `kubectl delete -f k8s/cert-manager/` + 还原 ingress.yaml 为 HTTP-only；证书 Secret 残留无副作用 |
| 2 巡检 | 停止 cron：`crontab -l \| grep -v db-inspect \| crontab -`；删除脚本：`rm /usr/local/bin/db-inspect.sh` |

## 7. 实际风险与注意事项

| # | 模块 | 风险 | 影响 | 缓解措施 |
|---|------|------|------|---------|
| 1 | 1 | **cert-manager pod 调度到无网络的 node-02/03** | ImagePullBackOff，安装卡住 | 必须设置 `nodeSelector: kubernetes.io/hostname=node-01` |
| 2 | 1 | **daocloud quay.m.daocloud.io 超时**（从 node-02/03） | 镜像拉取失败 | 强制调度到 node-01 + 使用国内镜像 |
| 3 | 1 | 自签 CA 证书默认不受客户端信任 | 浏览器/curl 报「不安全」 | 导出根 CA 公钥并分发到客户端信任存储 |
| 4 | 1 | 内网域名无法公网解析 | Traefik Host 路由失效 | 配置 hosts / CoreDNS / dnsmasq 内网解析 |
| 5 | 1 | cert-manager 自举死锁（webhook 校验自身） | 安装卡住 | namespace 加 `cert-manager.io/disable-validation: true` |
| 6 | 1 | 主 Ingress 加 host 后裸 IP 无法访问 | `curl <EIP>` 失效 | 保留独立健康检查 Ingress（`/health`，无 host） |
| 7 | 1 | 根 CA 到期需手动续签（10 年） | 所有客户端需重新导入 CA | 文档记录 CA 指纹；到期前手动续签并重新分发 |
| 8 | 2 | **SHOW REPLICA STATUS\G 配合 mysql -N 丢失字段名** | 复制状态解析为空 | 改用 `${MYSQL_CMD} -e`（去掉 -N）查询，awk -F': ' 解析 \G 输出 |
| 9 | 2 | `column` 命令不存在 | TOP 10 大表格式化失败 | 脚本已用 `|| true` 容错 |
| 10 | 2 | 巡检脚本在 Master 跑占用资源 | 影响写入 | 固定 node-03（Slave，只读）执行 |

## 8. 增强前后对比

| 维度 | 增强前 | 增强后 |
|------|--------|--------|
| 传输安全 | HTTP 明文 `:80` | HTTPS `:443` + cert-manager 自动续签 |
| 证书管理 | 无 | selfSigned 根 CA（10 年）+ CA Issuer 签服务证书（90 天自动 Renew） |
| 数据库可观测 | 人工排查 | 每周结构化巡检报告 + OSS 趋势留存 (`oss://k3s-backup-velero/mysql-inspect/`) |
| 域名访问 | 仅 IP | 内网域名 + 自签证书（需导入 CA 公钥后可演示 https） |
| 集群入口 | 单一 HTTP Ingress | HTTP 健康检查 + HTTPS 服务共存 |

## 9. 拓展阅读

- [一篇文章让你彻底弄懂SSL/TLS协议 - 知乎](https://zhuanlan.zhihu.com/p/133375078)