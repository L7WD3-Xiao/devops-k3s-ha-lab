# 项目拓展方向规划（中厂 SRE 校招视角）

> 本文档从**面试信号强度 × 校招生可操作性 × 中厂生产贴合度**三维评估坐标系出发，对项目后续拓展方向进行分级规划。每个方向附带面试 Q&A，已按实操程度区分回答口径。

---

## 评估框架

| 维度 | 权重 | 含义 |
|------|------|------|
| 面试信号强度 | ★★★★★ | 面试官多大概率会追问、追问后能展示什么能力 |
| 校招生可操作性 | ★★★★★ | 一台 2C2G 虚拟机能否实现、时间/预算/技术储备门槛 |
| 中厂生产贴合度 | ★★★★★ | 中厂 SRE 实际工作中会不会遇到这个问题 |

**回答口径说明：**

| 可操作性评分 | 面试回答策略 | 文档标注 |
|------------|-------------|---------|
| ★★★★~★★★★★ | 按**已实施**回答，含配置细节、踩坑修复、验证数据 | ✅ 已做 |
| ★★~★★★ | 按**了解流程但未落地**回答，含架构理解、实施规划、与当前方案的对比分析 | 📖 了解 |

---

## 目录

1. [HTTPS + cert-manager（P0）](#1-https--cert-manager)
2. [External Secrets Operator（P0）](#2-external-secrets-operator)
3. [数据库自动巡检脚本（P1）](#3-数据库自动巡检脚本)
4. [Kyverno 策略即代码（P1）](#4-kyverno-策略即代码)
5. [Canary 灰度发布 Flagger（P1）](#5-canary-灰度发布-flagger)
6. [Longhorn 分布式存储（P2）](#6-longhorn-分布式存储)
7. [自定义指标 HPA（P2）](#7-自定义指标-hpa)
8. [暂不推荐的方向](#8-暂不推荐的方向)

---

## ⭐ P0 — 优先投入

### 1. HTTPS + cert-manager ✅ 已做

#### 为什么是 P0

当前集群使用 HTTP 暴露服务，面试官第一反应是"没有 HTTPS 的生产集群不算生产"。加上 HTTPS 后项目直接从"学生玩具"升级为"生产级别"，而且 cert-manager 的自动化续签机制保证了证书运维成本几乎为零。

> **与原始规划的关键差异**：因集群仅在内网演示（通过 `shortlink.internal` 域名），无法满足 Let's Encrypt ACME 验证所需的公网 DNS + `:80` 公网可达条件，改用 cert-manager selfSigned Issuer 签发私有根 CA（10 年），再由 CA Issuer 签发服务证书（1 年，到期前 30 天自动 Renew）。

#### 实施思路

| 组件 | 方案 |
|------|------|
| 证书管理 | cert-manager v1.16+（Helm 安装，镜像源覆盖为国内镜像） |
| 证书签发 | selfSigned → CA Issuer 两阶段签发（私有根 CA 10 年，服务证书 1 年自动续签） |
| 验证方式 | 内网自签 CA，无需公网验证 |
| 域名 | 内网域名 `shortlink.internal`（客户端 hosts / CoreDNS 解析），无需公网域名 |

**实施步骤：**
1. Helm 安装 cert-manager（注意 `installCRDs: true`，镜像源覆盖为 daocloud 国内镜像）
2. 创建 `selfSigned` ClusterIssuer + 根 CA Certificate（`isCA: true`，10 年）
3. 创建 `ca` ClusterIssuer（引用根 CA Secret 签发服务证书）
4. 修改 Ingress：添加 TLS（`cert-manager.io/cluster-issuer: ca-issuer`），同时保留独立健康检查 Ingress（`/health`，无 host，保留 IP 裸访问能力）
5. 配置内网 DNS 解析（客户端 `/etc/hosts` 或 CoreDNS hosts 插件）
6. 导出根 CA 公钥并分发到客户端信任存储（否则浏览器/curl 报「不安全」错误）

**配置关键片段（两阶段签发）：**
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

Ingress annotation 修改（主服务 Ingress）：
```yaml
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
      ...
```

#### 面试 Q&A

**Q：你们集群的 HTTPS 是怎么做的？**

我们用 cert-manager 做自动化证书管理。由于集群部署在内网，域名 `shortlink.internal` 无法通过公网 DNS 解析，也就无法使用 Let's Encrypt ACME 验证。所以我们采用了一套两阶段自签方案：先通过 selfSigned ClusterIssuer 签发一个 10 年期的私有根 CA 证书，再以该根 CA 为基础创建一个 CA ClusterIssuer，由它签发一年期的服务证书注入到 Ingress 的 TLS Secret。到期前 30 天 cert-manager 自动 Renew 服务证书，整个流程是自动化的。

**Q：自签证书客户端不是会报「不安全」吗？**

确实会。解决方案是导出根 CA 公钥并导入到客户端的系统信任存储。我们在 cert-manager 部署完成后，从 `k3s-root-ca-secret` Secret 中提取 `ca.crt`，分发给演示用的客户端——Windows 用 `certutil -addstore -f Root`，Linux 用 `update-ca-trust`，macOS 用 `security add-trusted-cert`。导入后浏览器/curl 就能正常信任，不再报安全警告。

**Q：为什么不用 Let's Encrypt 公网 CA？**

集群域名 `shortlink.internal` 是内网域名，仅供面试演示时在局域网内访问。Let's Encrypt HTTP-01 验证需要域名解析到公网 IP 且 `:80` 公网可达——内网域名无法满足。如果申请公网域名（如 `shortlink.example.com`）并解析到集群 EIP，HTTP-01 验证理论上可行，但会引入额外的域名成本（约 20-30 元/年）和安全暴露面。当前自签方案在内网场景下更合理。

**Q：你们的镜像里需要做什么适配吗？**

需要在 Go 镜像中安装 ca-certificates 包（已经在 Dockerfile 里了），因为短链的 301 重定向目标可能是 HTTPS 站点（如 `https://kubernetes.io`），Go 标准库需要 CA 证书来验证目标站点的 TLS 证书。这里 CA 用的是操作系统的根证书存储，和集群的自签根 CA 是两个不同的信任链——互不影响。

**Q：在国内公网环境向用户提供服务，你们的 HTTPS 方案需要改什么？**

如果要把这套方案迁移到公网生产环境，从流程到架构都需要调整，我分几个层面说：

**前置合规（国内特有）：**
1. **ICP 备案**——服务器在大陆境内提供 Web 服务必须完成 ICP 备案（工信部）。阿里云 ECS 控制台直接提交材料，一般 10-20 个工作日。备案成功后会得到一个 ICP 号，必须在网站页面底部展示。**这是硬性门槛，没有备案会被 ISP 封堵 80/443 端口。** 香港或海外节点可绕过 ICP 备案，但延迟会高。
2. **域名实名认证**——`.com`/`.cn` 等域名在中国大陆运营必须完成实名认证（提交身份证/营业执照），通过后才能设置 DNS 解析指向服务器 IP。
3. **等保 2.0**——如果是对公网的正式生产业务，需要按等级保护制度做安全评估。对于中小型 Web 服务，等保二级是常见要求（约 5-10 万/年的第三方测评费用），但校招项目不涉及。

**架构调整：**
4. **公网 CA 替换自签 CA**——公网访问必须使用受信任的公共 CA（Let's Encrypt、DigiCert、阿里云 SSL 证书服务）。自签 CA 在浏览器里会直接拦截，用户不可能手动导入 CA。cert-manager 可以配置 Let's Encrypt ACME HTTP-01 验证——需要域名 A 记录指向服务器公网 IP、`:80` 公网可达。阿里云 SSL 证书服务也提供免费 DV 证书（1 年，自动续签），通过 DNS-01 验证，不需要开放 `:80`。
5. **SLB（Server Load Balancer）替换直连 EIP**——当前 SSH 隧道 + 直连 EIP 的方式不适合公网生产。阿里云 SLB 提供四层 TCP/UDP 或七层 HTTP/HTTPS 负载均衡，可以在 SLB 上终结 HTTPS（SSL offloading），后端用 HTTP 传给 Traefik。SLB 自带 DDoS 基础防护。
6. **CDN + WAF**——公网服务建议在前面加一层 CDN（阿里云 CDN 或 CloudFront），静态资源缓存、动态请求回源，同时吸收突发流量。WAF（Web 应用防火墙）可以过滤 SQL 注入、XSS 等常见攻击。cert-manager 的证书可以和 CDN 集成（CDN 上配 HTTPS，源站用内部 CA 或 HTTP）。

**CI/CD 调整：**
7. **镜像拉取无需 VPC 域名**——公网环境下 GitHub Actions push 和集群 pull 都走公网 ACR 域名即可，不需要 VPC 内网域名策略。但如果集群在阿里云 VPC 内且 ACR 也在同地域，VPC 域名仍然有速度优势（内网传输免费、快速）。
8. **Webhook 回调可达**——公网服务的 CI/CD 如果需要 Webhook 回调（如 GitHub webhook 触发灰度发布），需要集群入站公网可达，或采用 polling 模式（FluxCD 默认 polling GitHub）。

**成本变化：**
> 公网 ECS 实例仅带宽费用约 100-200 元/月（5Mbps 按固定带宽），SLB 实例费约 0.1-0.2 元/小时，SSL 证书免费（Let's Encrypt 或阿里云免费 DV）。整体增加约 300-500 元/月。如果接受初期不加 SLB 直接用节点 EIP 暴露（对学生项目可接受），仅带宽费即可。

---

### 2. External Secrets Operator 📖 了解

#### 为什么是 P0

当前项目的 Secrets 管理方式是"手动 kubectl create + .gitignore 屏蔽"，这是 GitOps 流程的明显缺口。面试官一定会追问"你们 Secrets 怎么管理的？"ESO 原本定位为补齐"全声明式"的最后一块拼图。

> ⚠️ **ESO 模块已移除**：调查发现 ESO 官方支持的 48 个 provider 中不包含阿里云（Alibaba/AliCloud），无法直接对接阿里云 Secrets Manager。当前 `secret.yaml` 已 gitignored + `.example` 模板入库，安全性已满足项目要求，故放弃 ESO 模块。

#### 实施思路（规划但未落地）

如果使用 ESO，推荐的方案是：

| 组件 | 方案 |
|------|------|
| 后端存储 | 阿里云 Secrets Manager（免费额度足够） |
| 同步工具 | External Secrets Operator v0.14+ |
| 集成方式 | GitOps 管理 ExternalSecret CR，密钥存储在云上 |

**实施步骤：**
1. Helm 安装 ESO（需要为 ESO 创建 RAM 子账号 + 授权读取 Secrets Manager）
2. 创建 SecretStore（指向阿里云 Secrets Manager，配置认证信息）
3. 将现有 Secret 迁移到 Aliyun Secrets Manager
4. 编写 ExternalSecret CR（声明要同步的密钥及其到 K8s Secret 的映射）
5. 验证：删除集群中的 Secret → ESO 自动重建

#### 面试 Q&A

**Q：你们 Secrets 怎么管理的？GitOps 下 Secrets 算不算配置？**

当前的管理方式是手动 `kubectl create secret` + `.gitignore` 屏蔽 Secret 文件 + `secret.yaml.example` 模板入库。这样做的好处是简单可靠，不会把明文密码提交到 Git。我了解过 External Secrets Operator 的方案——它可以把密钥存在阿里云 Secrets Manager 上，Git 里只放 ExternalSecret CR 声明。但调研后发现 ESO 官方支持的 48 个 provider 中并不包含阿里云，所以暂时没有落地。如果云厂商切换到 AWS/Azure/GCP，ESO 会是首选的 Secrets 管理方案。（可以通过web hook方式）

**Q：如果 Secrets Manager 本身挂了，K8s 里的 Secret 还能用吗？**

可以。ESO 同步过来的 Secret 是持久化的 K8s Secret 对象，即使 Secrets Manager 暂时不可用，已有 Secret 不受影响，Pod 正常运行。只是无法刷新新的 Secret 版本。恢复后 ESO 自动重新同步。

**Q：为什么不直接用 sealed-secrets？**

sealed-secrets 的方案是把加密后的 Secret 放到 Git 里。问题在于密钥轮转时需要重新加密所有 Secret，且加密密钥的管理也是一个问题。ESO 的方式更"云原生"——密钥存在云上，有审计日志、版本管理、自动轮转。中厂生产环境 ESO 是更主流的选择，但前提是云厂商在 ESO 的 provider 支持列表中。

---

## ⭐ P1 — 推荐投入

### 3. 数据库自动巡检脚本 ✅ 已做

#### 为什么是 P1

数据库是 SRE 重点关注对象。写一个自动化巡检脚本展示的是**日常运维自动化意识**——面试官会觉得"这个人有 DBA 意识"。而且这个方向实现成本极低（纯脚本，不占集群资源），面试时可以直接展示输出报告。

#### 实施思路

用 Shell 脚本（`scripts/db-inspect.sh`） + 系统 cron（`0 2 * * 0`，每周日凌晨 2:00），在 MySQL Slave（node-03）上执行。通过 Ansible playbook（`ansible/playbooks/08-db-inspect.yml`）部署脚本 + 注册 cron，报告经 `ossutil` 推送到 OSS（复用 Phase 7 已安装的工具和 bucket）形成趋势基线。

**巡检项：**

| 类别 | 检查项目 | 命令/方式 |
|------|---------|-----------|
| 空间 | 表大小排名 TOP10 | `SELECT TABLE_NAME, ROUND(DATA_LENGTH/1024/1024) ... ORDER BY DATA_LENGTH DESC` |
| 碎片 | 碎片率超过 30% 的表 | `SELECT TABLE_NAME, DATA_FREE/DATA_LENGTH ... WHERE DATA_FREE/DATA_LENGTH > 0.3` |
| 慢查询 | 慢查询日志统计 | `mysqldumpslow /var/lib/mysql/*-slow.log` |
| 复制 | 复制延迟 + 线程状态 | `SHOW REPLICA STATUS\G` 解析 `Seconds_Behind_Source` |
| 连接 | 活跃连接数 + 来源 IP | `SHOW PROCESSLIST` |
| 性能 | InnoDB buffer pool 命中率 | `SHOW STATUS LIKE 'innodb_buffer_pool_read%'` |
| 错误 | 最近 7 天的 MySQL 错误日志 | `grep -i error /var/log/mysql/*.err` |

**输出格式：**
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

#### 面试 Q&A

**Q：你们有没有做数据库的日常巡检？**

做了。写了一个巡检脚本在 MySQL Slave 节点上每周跑一次，输出结构化报告。检查内容包括表空间和碎片率（`DATA_FREE/DATA_LENGTH`）、TOP 10 慢查询（用 `mysqldumpslow` 解析）、复制延迟（`Seconds_Behind_Source`）、Buffer Pool 命中率（低于 95% 告警）、以及错误日志中的异常。报告结果通过 ossutil 推送到 OSS，方便对比趋势变化。

**Q：巡检发现过什么问题吗？**

有两个发现值得一提。一是慢查询中发现了一条没有索引的 `SELECT original_url` 查询——但是我们的查询条件已经是 `short_code` 列（有索引），实际上不是问题，只是慢查询日志的误报，确认后加了注释说明。另一个是碎片率监测：短链服务有频繁 INSERT 和 UPDATE（短码生成是 INSERT 后 UPDATE），短期内就会有一定碎片。虽然不是紧急问题，但我们在巡检中记录了基线数据，未来如果碎片率超过 50% 可以考虑 `OPTIMIZE TABLE`。

**Q：为什么只在 Slave 上跑？Master 上跑有什么区别？**

Slave 是只读的，巡检查询（`SELECT TABLE_NAME`, `SHOW PROCESSLIST`）不会影响业务写入。而且 Slave 的数据和 Master 一致（GTID 同步），巡检结果能反映整体状态。Master 上跑的话，`SELECT COUNT(*)` 这种全表扫描会占用资源，在高写入场景下有性能影响。

---

### 4. Kyverno 策略即代码 📖 了解

#### 为什么是 P1

"策略即代码"是面试高频话题——面试官会问"除了 PSS 你还做了什么安全措施？"。Kyverno 比 OPA Gatekeeper 更友好（原生 K8s 资源语法，不用学 Rego），部署成本低，而且可以写出很具体的"治理"效果。中厂 SRE 团队一般都会用策略引擎做合规，校招能谈到这个话题说明有生产安全意识。

#### 实施规划

| 策略 | 规则简述 | 效果 |
|------|---------|------|
| 禁止 latest 标签 | 检查 Pod 镜像标签，拒绝 `:latest` 或无 tag | 强制不可变部署 |
| 强制 resources | 检查容器是否设置 `resources.requests` 和 `resources.limits` | 防止无限制 Pod 导致节点 OOM |
| 强制 registry | 检查镜像是否来自允许的 registry（ACR VPC 域名） | 防止拉取未经审核的外部镜像 |
| app-layer 非 root | 检查 `runAsNonRoot: true` | 强化 PSS restricted |

**Kyverno 与 PSS 的关系：**
PSS（Pod Security Standards）是 K8s 内置的准入控制，粒度较粗——只能按 namespace 设置 baseline/restricted 两个级别。Kyverno 可以写更精细的策略，比如"允许从哪些 registry 拉镜像"、"必须包含哪些 label"、"限制资源配比（limit/request 比值不超过 3）"。两者是互补关系：PSS 做基线，Kyverno 做个性化策略。

#### 面试 Q&A

**Q：你们 PSS 之外还有没有别的安全策略？**

我们当前用 PSS 做了 namespace 级别的基线——app-layer=restricted, data-layer=baseline。PSS 之外我了解过 Kyverno。它的设计比 OPA Gatekeeper 更原生——直接用 K8s 资源 YAML 写策略，不需要专门学一种新语言（Rego）。我规划过 3 条策略但没有落地：禁止 latest 镜像标签、强制所有 Pod 填写 resources、限制镜像只能从我们的 ACR 仓库拉取。没落地主要原因是时间，但逻辑上已经梳理清楚了——PSS 解决"安全基线"，Kyverno 解决"组织规范"，两者是互补的。

**Q：Kyverno 和 OPA Gatekeeper 你了解过区别吗？为什么选 Kyverno？**

了解过。Kyverno 的最大优势是**学习成本低**——策略本身是 K8s 资源（`ClusterPolicy` 是一种 CRD），会写 K8s YAML 就会写 Kyverno 策略。OPA Gatekeeper 需要学习 Rego 语言，是声明式查询语言，虽然表达力更强但初学者上手慢。中厂环境里两个都有用，但 Kyverno 更常见于"运维团队自己维护策略"的场景，Gatekeeper 更常见于"有专门安全平台团队"的大厂。

**Q：你可以举一个 PSS 覆盖不了但 Kyverno 可以覆盖的例子吗？**

PSS 只能检查 Pod Spec 本身的属性（`runAsUser`、`capabilities`、`seccompProfile` 等）。但"镜像必须从指定的 registry 拉取"——这个策略 PSS 做不了，但 Kyverno 可以通过检查 Pod 的 `image` 字段前缀来实现。另一个例子：PSS 不能要求 Deployment 必须有 `app.kubernetes.io/name` 标签，但 Kyverno 可以。这些是"组织规范"层面的策略，不是"安全基线"层面的。

---

### 5. Canary 灰度发布 Flagger 📖 了解

#### 为什么是 P1

从 GitOps 滚动升级到 Canary 发布是"SRE 高阶部署策略"的标配。面试官听到"我们用的 FluxCD 滚动更新"和"我们用了 Flagger 做灰度发布"的信号强度完全不同。Canary 发布涉及流量管理、指标监控、自动回滚——覆盖了网络（Traefik 权重路由）、监控（成功率/延迟指标）、自动化（Flagger 控制器编排）三方面能力。

#### 实施规划

**为什么现在没做：** 当前集群还没有部署 Prometheus（属于可观测性那个项目的范畴），Flagger 依赖 Prometheus 提供成功率/延迟/错误率指标来做 canary 的健康判定。

**如果实施的步骤：**
1. 部署 Flagger CRD（Helm 或 Kustomize）
2. 创建 Canary CR（目标是 `shortlink` Deployment，流量通过 Traefik Service）
3. 配置 step 权重：10% → 20% → 40% → 60% → 80% → 100%，每个 step 观察 2 分钟
4. 配置健康指标：HTTP 请求成功率（>99%）、P99 延迟（<500ms）、错误率（<1%）
5. 测试验证：push 一个带错误代码的新版本，观察 Flagger 自动回滚

**Flagger Canary CR 关键配置：**
```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: shortlink
  service:
    port: 8080
  ingressRef:
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    name: shortlink
  analysis:
    interval: 2m
    maxWeight: 100
    stepWeight: 10
    metrics:
      - name: request-success-rate
        threshold: 99
        interval: 1m
      - name: request-duration
        threshold: 500
        interval: 1m
```

#### 面试 Q&A

**Q：你们用 GitOps + FluxCD，发布策略是什么样的？**

当前是滚动更新（默认策略）。但我了解过 Flagger 的 canary 发布方案和我们环境集成的可行性。Flagger 通过调控 Service 的权重逐步切流量——新版本先接收 10% 流量，观察 2 分钟，检查 HTTP 成功率（>99%）和延迟（<500ms），通过后再切到 20%、40%...直到 100%。如果任何一个 Step 的指标超出阈值，Flagger 自动将 100% 流量切回旧版本、标记新版本为失败。

**Q：为什么没落地 Flagger？**

Flagger 需要 Prometheus 提供指标数据来做 canary 的健康判定。Prometheus 和相关告警规则我计划放在可观测性那个项目中做，和这个集群项目是分开设计的。从技术上来说，Flagger + Traefik 的集成方案我已经验证过可行（Flagger 官方提供了 Traefik 的 service mesh 配置），但受限于项目边界没有落地。

**Q：你们现在的滚动更新有什么问题？Canary 能解决什么？**

滚动更新的问题是**全有或全无**——新版本部署完成后才会发现异常，即使只有 1 个异常副本，也会影响部分用户。Canary 发布的核心价值是**风险前置**——在影响面还很小（10% 流量）的时候就发现异常，自动回滚。对于短链服务这种业务来说，滚动更新够了；但如果是有支付流程的关键业务，Canary 是必须的。

---

## ⭐ P2 — 有余力投入

### 6. Longhorn 分布式存储 📖 了解

#### 为什么是 P2

当前用 K3s 内置的 local-path-provisioner，数据存储在单节点磁盘上——有单点风险（如果该节点磁盘损坏，Redis PVC 数据丢失）。分布式存储能解决这个问题，但 Longhorn 对资源有额外消耗（每个 volume 的 replica 需要磁盘和内存），校招项目用 local-path 完全合理。有这个概念就好。

#### 实施规划

**为什么现在没做：** 3 个节点的数据盘都已经被 MySQL 数据占用（node-02/03 各约 771M），剩余磁盘空间有限。Longhorn 的 replica 机制要求每个 volume 有 2-3 个副本，需要额外的磁盘空间。

**如果实施的步骤：**
1. 在每个节点上预留一个未分区磁盘或目录（`/var/lib/longhorn/`）
2. 部署 Longhorn（Helm install）
3. 将 Redis 的 StorageClass 从 `local-path` 切换为 `longhorn`
4. 验证：删除一个节点上的 Redis Pod → Pod 调度到其他节点 → Longhorn 从 replica 自动恢复数据

**Longhorn 与 local-path 的对比：**

| 特性 | local-path (当前) | Longhorn |
|------|-------------------|----------|
| 跨节点高可用 | ❌ 单点 | ✅ 多 replica |
| 备份能力 | ❌ 无原生备份 | ✅ 内置快照 + 备份到 S3 |
| 资源消耗 | 几乎无 | ~每 volume 500MB 额外空间 |
| 安装复杂度 | K3s 内置 | 需要额外 3 个 Pod + CRD |
| 扩容 | ❌ 不支持 | ✅ 在线扩容 |
| 校招适配 | ✅ 完全够用 | ⚠️ 资源紧张 |

#### 面试 Q&A

**Q：你们的存储怎么做的？有没有单点风险？**

当前用的是 K3s 内置的 local-path-provisioner，Redis 的 PVC 数据存在本机磁盘上。严格来说有单点风险——如果节点磁盘损坏，local-path 没有跨节点副本，数据会丢失。但 Redis 本身是主从架构，一个节点的数据丢了可以从 Master 重新复制，所以风险可以接受。

**Q：考虑过 Longhorn 吗？**

了解过。Longhorn 是 CNCF 毕业项目，本质是把每个节点的磁盘池化成分布式存储池，给 volume 创建多份 replica 分布在不同节点上。如果替换，流程是：在 3 个节点上各部署一个 Longhorn agent → Helm 安装 Longhorn → 创建 StorageClass → 修改 Redis StatefulSet 的 PVC 模板引用新的 StorageClass。没有落地的主要原因是——3 个节点的磁盘资源已经很紧张（MySQL + 系统盘），Longhorn 每个 volume 默认 3 副本，磁盘压力会翻倍。在校招项目里，local-path + Redis 主从复制已经能覆盖数据安全需求。

**Q：Longhorn 的 rebuild 过程是怎样的？如果节点挂了数据恢复要多久？**

Longhorn 的 Engine 进程监控 volume 的 replica 健康状态。当一个 replica 所在的节点不可用时，Engine 标记该 replica 为 faulted，然后自动在其他健康节点的空闲磁盘上创建新的 replica，通过从其他健康 replica 同步数据来 rebuild。对于 512Mi 的 Redis PVC，rebuild 应该 <30 秒。这个过程不影响 volume 的读写——只要还有一个健康 replica，Engine 就可以继续提供服务。

---

### 7. 自定义指标 HPA 📖 了解

#### 为什么是 P2

CPU-based HPA 是最基础的弹性策略。面试官可能会追问"CPU 真的能准确反映你的业务负载吗？"。如果能提到自定义指标（Redis QPS、HTTP 请求速率），说明对 K8s 弹性伸缩的理解不止表面。但这个方向依赖 Prometheus（可观测性项目），而且短链场景请求量小，CPU HPA 已经够用。

#### 实施规划

**为什么现在没做：** 需要 Prometheus 采集指标 + Prometheus Adapter 转换为 K8s 自定义指标，与可观测性项目有边界重叠。而且短链服务当前请求量小（CPU 2%/70%），HPA 尚未触发过扩容，自定义指标的实际价值暂时不大。

**如果实施的步骤：**
1. 部署 Prometheus + kube-state-metrics
2. 部署 Prometheus Adapter（将 Prometheus 查询暴露为 K8s 自定义指标 API）
3. 配置指标规则：如 `http_requests_per_second`、`redis_qps`
4. 修改 HPA 引用自定义指标

**HPA 引用自定义指标示例：**
```yaml
metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: 100
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

#### 面试 Q&A

**Q：你们只有 CPU-based HPA？CPU 真的能反映业务负载吗？**

当前确实只有 CPU 70% 的 HPA。CPU 对短链服务来说是一个合理的弹性指标——请求量上升 → Go 应用处理请求 → CPU 升高。但我了解过 Prometheus Adapter 的方案。它的工作方式是：Prometheus 采集指标 → Prometheus Adapter 注册为 `custom.metrics.k8s.io` API → HPA 引用自定义指标。如果做的话，我会考虑用 `http_requests_per_second`（HTTP 请求速率）作为扩容指标，这对 Web 服务来说比 CPU 更直接。

**Q：自定义指标和 CPU 指标有什么本质区别？**

CPU 是 Resource 指标，由 metrics-server 提供，反映的是"Pod 用了多少 CPU"。自定义指标是业务指标，反映的是"Pod 在处理多少负载"。HTTP 请求速率就是典型的自定义指标——可能 CPU 才 30% 但请求量已经快到上限了（比如因为数据库连接池满了），CPU 不会触发扩容但自定义指标会。

---

## 8. 暂不推荐的方向

以下方向在校招阶段性价比偏低，不建议投入时间：

| 方向 | 不推荐理由 | 替代建议 |
|------|-----------|---------|
| **Service Mesh（Istio/Linkerd）** | 3 节点 2C2G 跑不动 Istio；中厂校招不指望你会 Service Mesh | 先做好 HTTPS + NetworkPolicy，安全基线到位更重要 |
| **多集群联邦（Karmada）** | 只有一个集群，没有联邦需求；面试问不出深度 | 把单集群做深比浅尝多集群更有价值 |
| **Cluster API（CAPI）** | 需要额外管理集群的基础设施；K3s 有自己的一套升级机制 | 先掌握 `system-upgrade-controller` 做 K3s 版本升级 |
| **IPv6 双栈** | 面试几乎不会问；中厂 IPv6 普及率不高 | 不如把 IPv4 层面的网络策略吃透 |
| **Gateway API** | 标准还在演进，中厂生产很少迁移到 Gateway API | Traefik Ingress 在当前场景完全够用 |
| **Karpenter/抢占式实例** | 云厂商绑定；校招面试官不一定熟悉具体云产品 | 先理解 HPA + PDB + 干扰预算这些 K8s 原生弹性机制 |
| **Renovate Bot 依赖更新** | 自动化价值高但面试信号弱（不同人问不出深度） | 有精力先做 Kyverno 策略，面试更能展示 |

---

## 投入路线图总结

```
现在 ───────────────────────────────────────────────► 面试前

第 1 周                    第 2 周                    第 3-4 周
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────────┐
│ HTTPS +          │    │ 数据库巡检脚本     │    │ Kyverno 研究         │
│ cert-manager     │    │ (脚本 + cron      │    │ + 策略编写           │
│ (1-2 天)         │    │  + OSS 推送)      │    │ (2-3 天)             │
│                  │    │ (1 天)            │    │                      │
│ 自签 CA 两阶段    │    │                  │    │ ESO 调研 (了解)       │
│ (selfSigned → CA)│    │ 调研 ESO 可行性   │    │ Flagger 调研          │
│ + Ingress TLS    │    │ (确认阿里云不在    │    │ Longhorn 调研         │
│ + CA 分发        │    │  provider 列表)   │    │ (了解即可, 面试       │
└──────────────────┘    └──────────────────┘    │  用"了解"口径)       │
                                                └──────────────────────┘
```

**最低配置（时间不够只做这些）：** HTTPS + cert-manager ✅ 仅此一项就能让项目从"可以"变成"不错"

**推荐配置（有时间）：** HTTPS + 自动巡检 + Kyverno 策略 + ESO/Flagger/Longhorn 调研 → 面试能讲的深度和广度都够了

**理想配置（时间充裕）：** 推荐配置 + 有选择地落地调研项（优先 Flagger canary，脱 Prometheus 依赖后实施）
