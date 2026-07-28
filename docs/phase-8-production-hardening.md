# Phase 8：生产级加固（HTTPS + 巡检自动化）

## 1. 概述

将 `docs/project-future-expansion.md` 中标记为「✅ 已做」的规划项正式落地为 Phase 8，覆盖**传输安全**、**运维自动化**两大生产级能力：

| 模块 | 来源规划 | 原 P 级 | 核心价值 |
|------|---------|--------|---------|
| Phase 1 | HTTPS + cert-manager | P0 | 全链路加密，自动续签，消除"学生玩具"观感 |
| Phase 2 | 数据库自动巡检脚本 | P1 | 日常运维自动化意识，可展示的结构化巡检报告 |

> **原规划的 ESO（External Secrets Operator）模块已移除**：ESO 官方支持的 48 个 provider 中不包含阿里云（Alibaba/AliCloud），无法直接对接阿里云 Secrets Manager。当前 `secret.yaml` 已 gitignored + `.example` 模板入库，安全性已满足项目要求，故放弃 ESO 模块。

## 2. 两模块架构总览

```
┌──────────────────────────────────────────────────────────────────────┐
│                          内网客户端                                  │
│                (浏览器 → https://shortlink.internal)                │
└───────────────────────────┬──────────────────────────────────────────┘
                            │  内网 DNS → 192.168.1.228:443
                ┌───────────▼────────────┐
                │  L7: Traefik (websecure) │  Ingress :443 + TLS
                │  cert-manager 注入证书    │
                └───────────┬────────────┘
                            │
        ┌───────────────────┼───────────────────────────────┐
        │                   │                                │
┌───────▼──────┐   ┌────────▼─────────┐              ┌──────▼──────────┐
│  app-layer   │   │  cert-manager    │              │ Phase 2 巡检脚本 │
│ shortlink    │   │  (selfSigned →   │              │ (cron, node-03)  │
│ (:8080 TLS)  │   │   根CA → CA      │              │                  │
│              │   │   Issuer → Cert) │              │                  │
└───────┬──────┘   └────────┬─────────┘              └──────┬───────────┘
        │                   │                               │
        │           ┌───────▼────────┐                     │
        │           │ 自签根 CA       │                     │
        │           │ (10年/公钥分发) │                     │
        │           └────────────────┘                     │
        │                                                  │
        ▼  MySQL 访问                                       ▼
┌──────────────────────────────────┐               ┌───────────────────┐
│  物理机 MySQL (node-02/03)         │◄──────────────│ 巡检报告 → ossutil │
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

## 4. 实施计划

### 4.1 Phase 1 — HTTPS + cert-manager

**目标**：为短链服务全量启用 HTTPS（TLS 1.2+），证书由 cert-manager 通过 selfSigned → CA Issuer 两阶段签发（私有根 CA 10 年，服务证书 1 年，到期前 30 天自动 Renew）。因域名仅内网使用，不依赖公网 CA。

#### Step 1 安装 cert-manager（GitOps 优先）

推荐用 FluxCD `HelmRelease` 安装（与项目 GitOps-first 理念一致），与现有 `clusters/production/*.yaml` 模式对齐。

**新建文件**：

| 文件 | 内容 |
|------|------|
| `clusters/production/cert-manager-install.yaml` | `HelmRepository`（jetstack chart repo）+ `HelmRelease`（cert-manager，`installCRDs: true`，**覆盖镜像源为国内镜像**） |
| `k8s/cert-manager/namespace.yaml` | `cert-manager` namespace（带 `cert-manager.io/disable-validation: true` 避免自举死锁） |
| `k8s/cert-manager/clusterissuer-selfsigned.yaml` | `ClusterIssuer` `selfsigned-issuer`（selfSigned）+ `Certificate` `k3s-root-ca`（isCA: true，10 年） |
| `k8s/cert-manager/clusterissuer-ca.yaml` | `ClusterIssuer` `ca-issuer`（引用根 CA Secret 签发服务证书） |
| `clusters/production/cert-manager.yaml` | FluxCD `Kustomization`（path `./k8s/cert-manager`，`dependsOn` cert-manager-install） |

> **镜像可达性**：cert-manager 镜像 `quay.io/jetstack/cert-manager-*` 国内不稳定。HelmRelease 的 `values` 段需覆盖 `image.repository` 为国内镜像（如 `docker.m.daocloud.io/jetstack/cert-manager-controller`）。jetstack chart 仓库 `charts.jetstack.io` 若不可达，HelmRepository 可配置 daocloud 代理或手动 `helm pull` airgap 安装。

**两阶段签发配置**（selfSigned → 根 CA → CA Issuer → 服务证书）：
```yaml
# 阶段1：selfSigned Issuer 签发根 CA 证书
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
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
---
# 阶段2：CA Issuer 用根 CA 签发服务证书
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ca-issuer
spec:
  ca:
    secretName: k3s-root-ca-secret
```

> 备选方案：若暂不强求 GitOps，可手动 `helm install cert-manager jetstack/cert-manager --set installCRDs=true -n cert-manager`，再 `kubectl apply -f` 上述 Issuer/Certificate。但本计划采用 GitOps 方案以保持一致。

#### Step 2 修改 Ingress 添加 TLS

**修改文件**：`k8s/app-layer/ingress.yaml`

拆分为两个 Ingress 资源：
1. **主服务 Ingress**（`shortlink`）：绑定域名 `shortlink.internal`，`websecure` entrypoint + TLS，cert-manager 自动签发。
2. **健康检查 Ingress**（`shortlink-health`）：无 host、`web` entrypoint、仅 `/health` 路径，保留 IP 直接访问能力（如 `http://192.168.1.228/health` 仍可裸 IP 健康检查）。

```yaml
# 主服务 Ingress（修改后）
metadata:
  annotations:
    cert-manager.io/cluster-issuer: ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - shortlink.internal
      secretName: shortlink-tls
  rules:
    - host: shortlink.internal
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

#### Step 3 内网 DNS 解析

内网域名 `shortlink.internal` 需解析到集群入口。三种方案按场景选用：

| 方案 | 适用场景 | 配置 |
|------|---------|------|
| 客户端 `/etc/hosts` | 单机演示 | 追加 `192.168.1.228 shortlink.internal` |
| CoreDNS hosts 插件 | 集群内 Pod 访问 | K3s CoreDNS ConfigMap 加 hosts 段 |
| 内网自建 DNS（dnsmasq） | 多客户端长期使用 | 指向 node-01 内网 IP `192.168.1.228` |

> Traefik Ingress 按 HTTP `Host` 头路由，DNS 必须正确解析。若通过 EIP `116.62.168.245` 访问，hosts 也指向 EIP。

#### Step 4 客户端 CA 信任分发

自签根 CA 证书默认不受任何客户端信任，需手动导入根 CA 公钥：

```bash
# 1. 从集群导出根 CA 公钥
kubectl get secret k3s-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > k3s-ca.pem

# 2. 分发到客户端信任存储
#    Windows: certutil -addstore -f Root k3s-ca.pem
#    Linux:   cp k3s-ca.pem /etc/pki/ca-trust/source/anchors/ && update-ca-trust
#    macOS:   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain k3s-ca.pem

# 3. 验证信任链（不再需要 --insecure）
curl -vI https://shortlink.internal/health    # TLS 握手成功，无证书警告
```

#### Step 5 验证

```bash
# cert-manager Pod 就绪
kubectl get pods -n cert-manager

# 两阶段 Issuer Ready
kubectl get clusterissuer selfsigned-issuer   # READY=True
kubectl get clusterissuer ca-issuer           # READY=True
kubectl get certificate k3s-root-ca -n cert-manager  # READY=True（根 CA）

# 服务证书签发（首次约 10-30s）
kubectl get certificate -n app-layer          # READY=True
kubectl get secret shortlink-tls -n app-layer # 存在

# HTTPS 访问（需已导入 CA 公钥，或用 --cacert）
curl -vI https://shortlink.internal/health                     # 200, 含 TLS 握手
curl -vI --cacert k3s-ca.pem https://shortlink.internal/health  # 或指定 CA 文件
curl -I  http://192.168.1.228/health                           # 仍可用（健康检查 Ingress）

# 续签验证
kubectl describe certificate shortlink-tls -n app-layer | grep "Renewal"
```

#### Step 6 文件影响

| 类型 | 文件 |
|------|------|
| 新建 | `clusters/production/cert-manager-install.yaml`、`k8s/cert-manager/namespace.yaml`、`k8s/cert-manager/clusterissuer-selfsigned.yaml`、`k8s/cert-manager/clusterissuer-ca.yaml`、`clusters/production/cert-manager.yaml` |
| 修改 | `k8s/app-layer/ingress.yaml` |

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

#### Step 2 新建 Ansible 部署 playbook

**新建文件**：`ansible/playbooks/08-db-inspect.yml`

职责：
1. 将 `scripts/db-inspect.sh` 拷贝到 node-03 `/usr/local/bin/`，`mode: 0755`
2. 确保 node-03 上 `/root/.my.cnf` 存在（MySQL 客户端凭证，`[client]` 段）
3. 确保 `ossutil` 已安装（Phase 7 已装，playbook 用 `command: which ossutil` 幂等检查）
4. 添加 cron：`0 2 * * 0 /usr/local/bin/db-inspect.sh >> /var/log/db-inspect.log 2>&1`（`ansible.builtin.cron` 模块，`name: mysql-inspect`）

遵循现有 playbook 约定（`become: true`、`serial: 1`、幂等 `changed_when`/`when` 守卫）。

> 巡检脚本的 OSS 配置（bucket/prefix/endpoint）均通过 `${VAR:-default}` 内置默认值，与 Phase 7 xtrabackup 脚本复用同一套 OSS 参数，无需额外修改 `all.yml.example`。

#### Step 3 验证

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

#### Step 4 文件影响

| 类型 | 文件 |
|------|------|
| 新建 | `scripts/db-inspect.sh`、`ansible/playbooks/08-db-inspect.yml` |

---

## 5. 受影响文件总览

### 新建文件（7 个）

| 文件路径 | 模块 | 说明 |
|---------|------|------|
| `clusters/production/cert-manager-install.yaml` | 1 | HelmRepository + HelmRelease 安装 cert-manager（镜像源覆盖为国内镜像） |
| `k8s/cert-manager/namespace.yaml` | 1 | cert-manager namespace |
| `k8s/cert-manager/clusterissuer-selfsigned.yaml` | 1 | selfSigned ClusterIssuer + 根 CA Certificate（10 年） |
| `k8s/cert-manager/clusterissuer-ca.yaml` | 1 | CA ClusterIssuer（用根 CA 签服务证书） |
| `clusters/production/cert-manager.yaml` | 1 | FluxCD Kustomization |
| `scripts/db-inspect.sh` | 2 | 数据库巡检脚本 |
| `ansible/playbooks/08-db-inspect.yml` | 2 | Ansible 部署 playbook |

### 修改文件（2 个）

| 文件路径 | 模块 | 变更内容 |
|---------|------|---------|
| `k8s/app-layer/ingress.yaml` | 1 | 拆分主/健康 Ingress，添加 TLS + cert-manager annotation |
| `README.md` | 全 | Phase 8 路线图状态更新 |

## 6. 部署顺序与回滚

### 推荐部署顺序

```
Phase 1 (HTTPS):
  1. 部署 cert-manager-install (HelmRelease) → 等待 CRD + Pod Ready
  2. 部署 cert-manager Kustomization (namespace + selfSigned Issuer + 根 CA Cert + CA Issuer)
  3. 修改 ingress.yaml (TLS + ca-issuer annotation) → 验证证书签发
  4. 配置内网 DNS 解析 (hosts / CoreDNS)
  5. 导出根 CA 公钥并分发到客户端信任存储
  6. 验证 HTTPS 访问 + 健康检查 Ingress 仍可用 (IP 裸访问)

Phase 2 (巡检):
  7. 编写 db-inspect.sh + 08-db-inspect.yml
  8. Ansible 部署到 node-03 + 注册 cron
  9. 手动执行验证报告生成 + OSS 推送
```

> 两个模块无相互依赖，可单独执行、单独回滚。

### 回滚策略

| 模块 | 回滚方式 |
|------|---------|
| 1 cert-manager | `kubectl delete -f` 安装资源 + 还原 ingress.yaml 为 HTTP-only；证书 Secret 残留无副作用 |
| 2 巡检 | `ansible` 删除 cron + 脚本；或停用 cron 任务 `crontab -r`（针对性） |

## 7. 风险与注意事项

| 模块 | 风险 | 影响 | 缓解措施 |
|------|------|------|---------|
| 1 | 自签 CA 证书默认不受客户端信任 | 浏览器/curl 报「不安全」 | Step 4 导出根 CA 公钥并分发到客户端信任存储 |
| 1 | 内网域名无法公网解析 | Traefik Host 路由失效 | Step 3 配置 hosts / CoreDNS / dnsmasq 内网解析 |
| 1 | cert-manager 镜像 `quay.io` 国内不可达 | 安装失败 | HelmRelease values 覆盖 image 为国内镜像源（daocloud） |
| 1 | cert-manager 自举死锁（webhook 校验自身） | 安装卡住 | namespace 加 `cert-manager.io/disable-validation: true` |
| 1 | 主 Ingress 加 host 后裸 IP 无法访问 | `curl <EIP>` 失效 | 保留独立健康检查 Ingress（`/health`，无 host） |
| 1 | 根 CA 到期需手动更换（10 年） | 所有客户端需重新导入 CA | 文档记录 CA 指纹；到期前手动续签并重新分发 |
| 2 | 巡检脚本在 Master 跑占用资源 | 影响写入 | 固定 node-03（Slave，只读）执行 |

## 8. 增强前后对比

| 维度 | 增强前 | 增强后 |
|------|--------|--------|
| 传输安全 | HTTP 明文 `:80` | HTTPS `:443` + cert-manager 自动续签 |
| 证书管理 | 无 | selfSigned 根 CA（10 年）+ CA Issuer 签服务证书（1 年自动 Renew） |
| 数据库可观测 | 人工排查 | 每周结构化巡检报告 + OSS 趋势留存 |
| 域名访问 | 仅 IP | 内网域名 + 自签证书（需导入 CA 公钥后可演示 https） |

