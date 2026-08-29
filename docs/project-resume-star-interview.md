# 简历项目 STAR + 面试项目拷打（含答案）

> 目标岗位：中厂 SRE / 运维开发 / 平台工程（校招）
> 项目：基于 K3s 的高可用短链服务集群设计与实现

---

## 一、STAR 简历版本

### 项目名称：基于 K3s 的高可用集群设计与实现

**技术栈：**K3s · Ansible · Terraform · FluxCD · GitHub Actions · MySQL 8.0 · Orchestrator · ProxySQL · Redis Sentinel · Go · Helm · Kustomize · cert-manager · Velero · Percona XtraBackup · Aliyun ACR · Trivy · NetworkPolicy · RBAC

---

**Situation**

在 3 台阿里云 ECS上独立设计并落地面向生产环境的高可用 K3s 集群。实践基础设施 IaC、数据高可用、GitOps CI/CD、安全纵深防御与备份容灾等运维全栈能力。

**Action**

- **IaC 与集群部署**。Terraform 分步创建 VPC、安全组、3 台 ECS 及 EIP，分步控制规避成本风险。Ansible 自动化部署 K3s 集群。
- **数据层高可用**。MySQL 物理机 GTID 主从复制，Orchestrator 自动检测故障并提升 Slave，ProxySQL 基于 read_only 变量实现读写分离。Redis 1 主 2 从 StatefulSet + 3 Sentinel 哨兵集群，防反亲和跨节点分布，RDB+AOF 双持久化。
- **CI/CD 与 GitOps**。Go 多阶段构建至 7.5MB 最终镜像，非 root 用户运行。GitHub Actions 全自动流水线：go vet/test、docker buildx、push ACR、Trivy 扫描 HIGH/CRITICAL 阻断、sed 更新 Kustomize newTag、git commit 回推。FluxCD 6 个 controller 同步 Git 状态，漂移自动纠正。
- **安全纵深**。6 个命名 ServiceAccount；三层 RBAC（admin/developer/viewer）；12 条 NetworkPolicy 白名单覆盖完整数据流；PSS 差异化——app-layer restricted（非 root + readOnlyRootFilesystem + drop ALL），data-layer baseline（兼容 root 镜像但 drop ALL + 禁止提权）；SecurityContext 覆盖全部 5 个 Workload；Trivy CI 集成，阻断含 HIGH/CRITICAL 漏洞的镜像入库。
- **备份容灾**。Velero FSB（kopia）每日备份 K8s 资源与 Redis PVC 至阿里云 OSS；xtrabackup 在 Slave 节点流式全量备份 MySQL（stream=xbstream | gzip），通过 ossutil 推送 OSS。双备份维度异地保留 7 天，OSS Lifecycle Rule 自动清理。
- **生产级加固**。cert-manager（selfSigned → CA Issuer 两阶段签发）实现 HTTPS 全链路加密，自签根 CA 10 年+ 服务证书 90 天自动续签。数据库 7 维度自动巡检（空间/碎片/慢查询/复制/连接/性能/错误日志），cron 每周推送报告至 OSS 形成趋势基线。

**Result**

- 任一节点故障控制面与业务均不中断。
- MySQL 复制延迟 < 1s，Orchestrator 自动切换；Redis failover < 10s，原 key 可读。
- CI/CD 全自动化，git push 到生产上线 ~ 4min。
- 双链路备份到 OSS，7 天保留；MySQL 全量备份窗口 ~ 6min（10GB 规模）、恢复演练 RTO ~ 25min。
- 全链路 IaC——Terraform 基础设施 + Ansible 集群部署 + FluxCD GitOps——环境可一键复现。
- 全站 HTTPS 加密，证书 90 天自动续签；数据库运维可观测，每周结构化巡检 + OSS 趋势留存。

---

## 二、面试项目拷打（含答案）

> 以下问题按面试常见度排列，涵盖中厂 SRE 校招的典型追问方向。

---

### 【架构设计类】

#### Q1: 为什么用 K3s 不用标准 K8s？

**回答要点：**

K3s 是经过 CNCF 认证的 K8s 发行版，API 完全兼容，写在简历上就是"K8s 体系"。选 K3s 的原因：

1. **资源友好**：3 节点中有一台仅 2C2G，标准 K8s 控制面组件（kube-apiserver、kube-controller-manager、kube-scheduler、etcd）占用 ~1GB+ 内存，K3s 单二进制整合全部控制面组件，实测 idle 时 ~400MB。相同硬件能跑业务 Pod。
2. **内置组件省心**：Flannel、CoreDNS、Traefik Ingress、local-path-provisioner 全部内建，无需额外安装。Metrics-server 也是内建可选。
3. **embedded etcd**：3 节点用嵌入 etcd 而非外部 etcd 集群，少维护一套 etcd 集群，降低复杂度。
4. **与 K8s 概念完全一致**：kubectl、Pod、Service、Deployment、CRD、Operator 完全兼容，学了 K3s 就是学 K8s，不存在迁移成本。

**追问：那你说说 embedded etcd 和外部 etcd 有什么区别？** 嵌入 etcd 是 K3s server 进程内启动的 etcd 实例，数据目录在 `/var/lib/rancher/k3s/server/db/etcd`。区别在于 embedded etcd 跟随 K3s 版本升级，无法独立升级 etcd；当 etcd 数据损坏时恢复也更复杂。中厂生产环境建议用外部 etcd 或 RDS，校招项目 embedded etcd 足够。

---

#### Q2: 3 节点 HA 是怎么保证的？一个节点挂了集群会怎么样？

**回答要点：**

K3s embedded etcd 使用 Raft 共识算法，需要多数节点存活。3 节点集群的 quorum = 2（N/2+1），允许 **1 台故障**。

- **单节点故障**：etcd 仍满足 quorum（2/3），控制面 API 正常，Pod 调度正常。如果故障节点是 Worker，Pod 被自动 reschedule。
- **双节点故障**：etcd 失去 quorum（1/3 < 2），控制面只读不可写，但已有 Pod 继续运行不会丢。
- **节点重启**：etcd 成员在重启后自动重连并追赶数据。

**实际踩坑**：EIP 绑定在 node-01，如果 node-01 挂了，外部无法通过 kubectl/EIP 访问 API Server。解决方案是 node-01 恢复后 EIP 自动重绑，或用 node-02/03 做 API Server 备用入口（加 tls-san）。

---

#### Q3: MySQL 为什么不放容器里，放物理机？Redis 为什么又放容器里？

**这是你项目最大的亮点问题，中厂面试官一定会问。**

**回答要点：**

核心原则：**有状态服务容器化与否取决于运维成本和收益的权衡。**

| 维度 | MySQL（物理机） | Redis（容器） |
|------|---------------|-------------|
| 数据重要性 | 核心业务数据，丢失不可接受 | 缓存数据，可重建 |
| I/O 要求 | 高（大量随机读写） | 中（内存操作为主） |
| 运维成熟度 | 第三方 Operator 不成熟 | Redis Operator 已经较成熟 |
| 备份方案 | xtrabackup 需要读数据目录 | 主从复制 + RDB/AOF 即可 |
| 故障恢复 | 数据修复时间长 | Pod 重建 + 从节点同步 |

MySQL 放物理机是中厂生产常见模式——核心数据需要可控的 I/O 性能、确定的备份路径、以及 DBA 熟悉的运维方式。Redis 容器化是因为它是无状态缓存层的语义（数据可重建），且容器化后便于利用 K8s 的滚动更新和健康检查做自动恢复。

**追问：如果 MySQL 数据量大到 100G 甚至 1T，物理机方案还成立吗？** 那时候物理机也会遇到单机瓶颈，会用 RDS 或者分布式数据库。校招项目里展示你在小规模下能按正确原则做决策就足够了。

---

#### Q4: 为什么用 FluxCD 而不是 ArgoCD？

**回答要点：**

1. **资源占用**：FluxCD 用自定义控制器而非 API Server 轮询，资源占用量更低（实测 6 个 controller 约 200MB）。ArgoCD 需要 Redis + Application Controller + API Server + Dex，资源消耗约 FluxCD 的 2-3 倍。对 2C2G 节点来说，这个差异很明显。
2. **更纯粹的 GitOps**：FluxCD 的设计哲学是"K8s 控制器被动监听 Git"，不需要手动点击 Sync 按钮。ArgoCD 更偏向"Web UI + 手动触发"，虽然也可以自动化但设计初衷不同。
3. **部署简单**：FluxCD 单二进制部署（flux install），ArgoCD 需要更多 CRD 和组件。

**选型文档也分析过（见 docs/技术选型/ArgoCD-vs-FluxCD.md），最后选了 FluxCD。但如果团队习惯 Web UI 操作，或需要多集群管理能力，ArgoCD 也是合理的选择。**

---

### 【数据层 HA 类】

#### Q5: ProxySQL 读写分离怎么做的？如果 Master 挂了，流量怎么切换？

**回答要点：**

ProxySQL 通过 `mysql_replication_hostgroups` 实现基于 **read_only 变量**的自动读写分组：

1. ProxySQL 的 Monitor 模块定期检查后端 MySQL 的 `read_only` 变量
2. `read_only=OFF` → 自动归入 HG1 (writer)
3. `read_only=ON` → 自动归入 HG2 (reader)
4. 查询规则：`SELECT...FOR UPDATE` 走 writer，普通 `SELECT` 走 reader，`INSERT/UPDATE/DELETE` 走 writer

**Master 故障切换流程：**

1. Orchestrator 检测到 Master 不可达（连续探测超时）
2. Orchestrator 自动提升 Slave 为新 Master（`SET GLOBAL read_only=OFF`）
3. ProxySQL Monitor 检测到原 Slave 的 `read_only` 由 ON→OFF，自动将其从 HG2 移到 HG1
4. 新 Master 出现后，Orchestrator 通知 ProxySQL 更新拓扑
5. 原 Master 恢复后以 Slave 身份加入（`read_only=ON` → 自动进入 HG2）

**踩过的坑**：一开始 Slave 忘记设 `read_only=ON`，结果 ProxySQL 把 Slave 同时放入 HG1 和 HG2，写请求可能路由到 Slave。Slave 上的本地写入与 Master binlog 复制产生 PRIMARY KEY 冲突，导致复制中断。修复后把 `read_only` + `super_read_only` 写入了 Ansible 模板，新部署的 Slave 自动配置。

---

#### Q6: Redis Sentinel 的故障切换流程具体是怎么实现的？

**回答要点：**

Sentinel 集群（3 个节点）通过 gossip 协议通信，quorum = 2。

**故障检测流程：**
1. 每个 Sentinel 每隔 1 秒向 Master 发送 PING
2. 如果 `down-after-milliseconds=5000`（5s）无响应，该 Sentinel 标记 Master 为 s_down（主观下线）
3. 该 Sentinel 向其他 Sentinel 询问 Master 状态（`SENTINEL is-master-down-by-addr`）
4. 当 ≥ 2 个 Sentinel（quorum）都认为 Master 不可用，标记为 o_down（客观下线）
5. 触发 failover 选举

**故障切换流程：**
1. **Leader 选举**：Sentinel 之间用 Raft 类似算法选举一个 Leader 执行切换
2. **挑选新 Master**：优先选 replication offset 最接近原 Master 的 Slave，忽略断线超过阈值的 Slave
3. **Slave 提升**：向选中的 Slave 发送 `SLAVEOF NO ONE`
4. **重新配置**：向其他 Slave 发送 `SLAVEOF <新Master>`，剩余 Sentinel 监视新 Master
5. **通知客户端**：应用连接 Sentinel 获取新 Master 地址

**我们测试结果**：failover 耗时 < 10 秒，切换后原 key 在迁移后的新 Master 上可读（Redis 主从复制不丢已同步数据）。

**追问：如果 Sentinel 本身挂了会怎么样？** 3 个 Sentinel 挂 1 个，quorum=2 仍然可以判定下线，不影响故障切换。挂 2 个 Sentinel 时无法触发切换，但 Redis Master 读写正常，只是失去自动切换能力。这就是为什么部署奇数个 Sentinel 节点。

---

#### Q7: 你们踩过 Sentinel DNS 解析的坑，详细说说。

**这是面试官最喜欢的"你遇到了什么困难"问题，要讲清楚根因和解决过程。**

**根因分析：**
- Redis Sentinel 配置文件中的 `sentinel monitor mymaster redis-0.redis-headless.data-layer.svc.cluster.local 6379 2`
- Sentinel 在解析配置文件时，通过 musl libc（Alpine 基础镜像）的 `getaddrinfo()` 解析 hostname
- musl 的 DNS 解析实现与 glibc 不同：glibc 会 fallback 到其他 DNS server，musl 一次解析失败就返回 error
- K8s DNS 在 Sentinel 启动时偶尔有延迟（CoreDNS 刚为 redis-0 注册 A 记录），musl 没有重试机制直接报 FATAL
- 但 BusyBox 的 `nslookup` 命令可以正常解析（nslookup 用不同的 DNS 查询机制）

**修复方式：**
```yaml
initContainers:
  - name: init-sentinel
    command:
      - /bin/sh
      - -c
      - |
        MASTER_IP=$(nslookup redis-0.redis-headless.data-layer.svc.cluster.local \
          | awk '/^Address: / && !/10.43.0.10/ {print $2}' | head -1)
        sed "s/redis-0.redis-headless.data-layer.svc.cluster.local/$MASTER_IP/g" \
          /etc/redis-config/sentinel.conf > /sentinel-data/sentinel.conf
```

**经验总结：** K8s 环境中，Alpine/musl 镜像做 DNS 解析时可能遇到 glibc 不存在的问题。遇到 DNS 解析失败，先确认是不是 musl vs glibc 问题（`ldd --version` 或者 `cat /etc/alpine-release`）。更通用的解法是用 `dig`/`nslookup` + `sed` 在 init container 中做运行时替换。

---

### 【CI/CD / GitOps 类】

#### Q8: 你们 GitOps 的完整流程是怎么样的？CI 推的镜像怎么更新到集群？

**完整流程：**

```
开发者 git push main (app/ 或 Dockerfile 变更)
    │
    ▼ GitHub Actions
    1. go vet + go test
    2. docker buildx (多架构)
    3. docker push ACR (tag: v1.0.{run_number})
    4. Trivy 镜像扫描 (HIGH/CRITICAL → 阻断)
    5. sed 更新 k8s/app-layer/kustomization.yaml newTag
    6. git add → git commit → git push
    │
    ▼ FluxCD
    7. SourceController (~1min) 检测到 Git 新 commit
    8. KustomizeController kustomize build → diff → apply
    9. 健康检查等待 Deployment Ready
    10. 滚动更新完成
```

**镜像更新策略：** 原先用 FluxCD ImageUpdateAutomation（IUA）自动扫描 ACR 新 tag，但 v2.9.2 的 Setters 策略有 Bug——把完整的镜像引用写成 newTag 而不是只写 tag，导致 Kustomize 渲染出损坏的镜像地址。最终改为 **CI 直接 sed 更新 newTag + git push**，IUA 永久暂停。

**追问：为什么不用 Kustomize 的 images 字段的 digest pinning？** digest pinning 的好处是不可变部署、防篡改。但我们的 CI workflow 已经是信任链的一部分（代码审查 + Trivy 扫描后才推送），用 semver tag + 滚动更新更符合我们的部署节奏。而且 CI 会处理新 tag 的注入，不需要人工操作。

---

#### Q9: 你们的回滚怎么做？FluxCD 怎么回滚？

**回答要点：**

| 场景 | 操作 | 耗时 |
|------|------|------|
| 代码回滚 | `git revert <commit>` → push | ~5min（FluxCD 自动同步） |
| 配置回滚 | `git revert` 配置 commit → push | ~5min |
| 镜像回滚 | `git revert` CI 的 tag commit → push | ~5min |
| 漂移纠正 | 手动改集群资源 → FluxCD 自动恢复 | ~5min（prune: true） |
| FluxCD 故障 | 手动 `flux reconcile kustomization app-layer` | 立即触发 |

GitOps 的核心优势：**回滚 = git revert**，不需要 kubectl rollout undo，不需要重新构建镜像。你只需要在 Git 里回退，FluxCD 会自动把集群恢复到上一个状态。

**追问：如果 git revert 之后 CI 又跑了怎么办？** 这是个好问题。我们的 CI 只会在 `app/` 或 `Dockerfile` 变更时触发。revert 操作修改的是 `k8s/app-layer/kustomization.yaml`，不会触发 CI。如果要回滚代码，revert 代码变更 + 修改 kustomization.yaml 的 tag 到旧版本，然后把这两个 commit push 上去。

---

### 【安全类】

#### Q10: 你们的安全怎么做？为什么 data-layer 和 app-layer 的 PSS 等级不一样？

**回答要点：**

六层纵深防御：

| 层 | 技术 | 防护 |
|----|------|------|
| L1 网络 | NetworkPolicy 白名单 | 限制 Pod 间流量 |
| L2 容器 | SecurityContext + PSS | 限制容器权限 |
| L3 身份 | RBAC 三层角色模型 | 最小权限 |
| L4 密钥 | Secret + init container | 消除 ConfigMap 明文 |
| L5 资源 | ResourceQuota + LimitRange | 防资源耗尽 |
| L6 CI | Trivy 镜像扫描 | 阻断高危漏洞镜像 |

**PSS 差异化原因：**
- **app-layer=restricted**：shortlink 是自建镜像，Dockerfile 就写了 `USER appuser (UID 10001)`，且 Go 应用不需要写文件系统（`readOnlyRootFilesystem: true`），完全符合 restricted 标准
- **data-layer=baseline**：ProxySQL 和 Orchestrator 的官方镜像以 root 运行，且上游没有提供非 root 变体。我们没有 fork 镜像的维护能力，所以 data-layer 用 baseline 兼容。但 audit/warn 设了 restricted，可以在审计日志中追踪偏离 restricted 的行为，为未来升级记录

**追问：你怎么知道 ProxySQL 必须以 root 运行？有没有尝试过改镜像？** 查看官方 Dockerfile，ProxySQL 启动时需要写 `/var/lib/proxysql` 和读取 `/etc/proxysql.cnf`，默认用户是 root。理论上可以 fork 镜像改 Dockerfile 加非 root 用户，但需要自己维护镜像更新。校招项目的原则是**不 fork 上游镜像**，因为多了镜像维护负担，且面试时会追问"你怎么保证镜像和上游同步安全"——反而挖坑。

---

#### Q11: NetworkPolicy 怎么设计的？有没有遇到阻断流量的情况？

**回答要点：**

设计原则：**default deny + 白名单 allow**。先不部署 NetworkPolicy（避免阻断初始部署流量），等所有 Pod 正常运行后一次性 apply 所有规则。

**流量矩阵（12 条规则）：**

| 源 | 目标 | 端口 | 理由 |
|----|------|------|------|
| Traefik | shortlink:8080 | 8080 | Ingress 流量 |
| shortlink | ProxySQL:6033 | 6033 | MySQL 读写 |
| shortlink | Sentinel:26379 | 26379 | Redis 服务发现 |
| shortlink | Redis:6379 | 6379 | Redis 数据直连 |
| Sentinel | Redis:6379 | 6379 | 监控 + 切换 |
| Redis↔Redis | Redis:6379 | 6379 | 主从复制 |
| Sentinel↔Sentinel | Sentinel:26379 | 26379 | 集群通信 |
| ProxySQL | 192.168.1.0/24:3306 | 3306 | MySQL 直连 |
| Orchestrator | 192.168.1.0/24:3306 | 3306 | MySQL 拓扑监控 |
| Orchestrator | ProxySQL:6032 | 6032 | 故障切换通知 |
| 所有 Pod | CoreDNS:53 | 53 UDP/TCP | DNS |
| (可选) Traefik | Orchestrator:3000 | 3000 | Web UI |

**踩过的坑**：deny-all 和 allow-* 必须同一次 apply 部署，否则 deny-all 先生效会阻断所有流量。还有就是 Traefik 使用 `hostNetwork: true`，源 IP 是节点 IP 而非 Pod IP，NetworkPolicy 需要用 `ipBlock` 而非 `podSelector` 来适配。

**追问：你们实际测试过 podSelector 还是 ipBlock 生效吗？** 对，测试后发现用 `namespaceSelector: kube-system` + `podSelector` 匹配 Traefik 有时不生效（因为 Traefik hostNetwork 模式下网络命名空间在主机层），最终用 `ipBlock: 192.168.1.0/24` 作为备用方案。

---

### 【生产运维类】

#### Q12: 你们怎么备份的？数据丢了怎么恢复？

**双维度备份策略：**

| 维度 | 工具 | 内容 | 方式 |
|------|------|------|------|
| 集群级 | Velero FSB (kopia) | K8s 资源 + Redis PVC | 每日 02:30，OSS |
| 数据级 | Percona XtraBackup | MySQL 全量数据 | 每日 02:00（比 Velero 早半小时），流式 gzip，OSS |

**设计理由：**
1. MySQL 在物理机不在 K8s 里，Velero 覆盖不到，必须用 xtrabackup
2. Velero 不能用 CSI 快照（local-path-provisioner 不支持 VolumeSnapshot），所以用 FSB 模式（文件级别备份，底层用 kopia）
3. Velero 的备份时间在 xtrabackup 之后半小时，确保 MySQL 备份先把数据送到 OSS，再备份 K8s 资源

**恢复流程：**

- **MySQL**：从 OSS 下载备份 → `xtrabackup --prepare`（应用 redo log）→ `xtrabackup --copy-back` → `chown mysql:mysql` → 启动 mysqld → GTID auto-positioning 重建复制。已写好 Ansible playbook 自动化
- **K8s + Redis**：`velero restore create` → 自动重建 PVC → node-agent kopia 从 OSS 恢复数据到 PVC → Redis StatefulSet 启动恢复

**追问：恢复演练过吗？怎么验证的？** 恢复演练流程已经文档化并写成 playbook：MySQL 侧用 `05-restore-mysql-drill.yml` 演练、`05-restore-mysql-dr.yml` 承接真实灾难（容错：mysqld 已宕机、datadir 缺失、工具/空间前置检查），K8s 侧用 `06-restore-redis.yml` 自动化 Velero 恢复（设置 Redis key → 删 StatefulSet+PVC → 恢复 → 验证 key 可读）。

> 备份/恢复用时追问见 Q24

---

#### Q13: Ansible 怎么做到幂等的？如果重复执行同一个 Playbook 会发生什么？

**回答要点：**

Playbook 中使用了多种幂等保护机制：

1. **`when` 条件判断**：如 `00-init-system.yml` 中 `when: not k3s_installed.stat.exists`，先 stat 检查 k3s.service 是否存在，已安装就跳过
2. **`changed_when`/`failed_when`**：自定义变更判定逻辑
3. **`creates` 参数**：`command: dnf install -y ... creates=/usr/bin/mysql`，文件已存在就跳过
4. **模板管理的配置文件**：Ansible 自动管理 `/etc/my.cnf`、`/etc/rancher/k3s/config.yaml`，重复执行只会在内容变更时才更新并触发重启
5. **idempotent 命令**：`dnf install` 在包已安装时直接退出不操作；`systemctl restart` 只有服务运行时才重启

重复执行同一个 Playbook 是安全的，这也是 IaC 的核心价值。

**追问：K3s 部署这个 Playbook 重复执行会有什么后果？** `01-deploy-k3s.yml` 第一步就用 `stat /etc/systemd/system/k3s.service` 检测是否已安装，已安装直接跳过整个部署流程。但如果想升级 K3s 版本，需要先停掉旧版，再修改配置文件触发重新安装——这也是我们未来要做的 K3s 升级策略的一部分。

---

#### Q14: 如果 node-01 的 EIP 访问不通了，怎么排查？

**排查路径：**

```
1. 本机 ping <集群公网入口IP>        → 不通 → 确认不是本机网络问题
2. 阿里云控制台检查 EIP 状态        → 确认 EIP 是否还绑定在 node-01
3. 阿里云控制台检查安全组规则       → 确认 22 端口放行 0.0.0.0/0
4. 通过 SWAS 跳板机内网访问 node-01 → ssh ops@192.168.1.228 (内网)
   ├── 如果能通 → 公网/EIP 问题，看 EIP 带宽是否用满、是否欠费
   └── 如果不通 → 节点本身问题，看阿里云控制台实例状态
5. 登录 node-01 后排查：
   ├── systemctl status k3s           → K3s 是否运行
   ├── ss -tlnp | grep 6443           → API Server 是否监听
   ├── df -h                          → 磁盘是否写满
   ├── free -h                        → 内存是否 OOM
   ├── dmesg -T | tail -20            → 内核有无异常
   └── k3s kubectl get nodes          → 其他节点状态
```

**实际经验**：node-02/03 无公网 IP，只能通过 node-01 跳转。如果 node-01 完全挂了，node-02/03 无法从外部 SSH 进入。所以要在阿里云控制台预留 VNC 连接作为最后手段，或给 node-02/03 也绑定 EIP（按量付费，平时不启用）。

---

#### Q15: 你们的 Go 短链服务代码写在哪里？能大致说一下数据流吗？

**业务逻辑极简，重点是基础设施——面试官通常只确认应用层没有重大设计缺陷。**

**写路径（POST /api/shorten）：**
1. 客户端 POST 原始 URL
2. 应用 INSERT url_mapping（无 short_code）→ ProxySQL → MySQL Master
3. 获取自增 ID → Base62 编码为 6 位短码（如 `dX7vQ`）
4. UPDATE 回 short_code 字段
5. SET Redis 缓存 `short_code → original_url`（TTL 24h）
6. 返回 `{"short_code": "dX7vQ"}`

**读路径（GET /:code）：**
1. 先查 Redis 缓存 — 命中直接 301 重定向
2. 缓存未命中 → SELECT shortlink → ProxySQL → MySQL Slave（读走从库）
3. 回填 Redis 缓存
4. 301 重定向到原始 URL

**设计要点：**
- 先 INSERT 再 UPDATE 的设计是为了展示 ProxySQL 读写分离——INSERT 走 writer，UPDATE 也走 writer
- Redis 只做缓存加速，MySQL 是最终数据源，Redis 丢了可以从 MySQL 重建
- 6 位 Base62 编码 ≈ 568 亿组合，远超过需求

---

### 【综合能力类】

#### Q16: 你觉得这个项目最大的挑战是什么？

**参考答案（三个选择，现场选一个最有说服力的讲）：**

**选择 A — Sentinel DNS 解析问题（推荐，因为最体现排查能力的深度）：**
最大的挑战是 Redis Sentinel 在容器的 DNS 解析失败问题。表象是 `FATAL CONFIG FILE ERROR — Failed to resolve hostname`，但排查发现根本原因是 Alpine 的 musl libc 在关键路径上的行为差异。这个问题涉及 OS 层面的 C 库实现差异、K8s DNS 生命周期（CoreDNS A 记录注册时机）、Redis 源码层面的解析逻辑。最终方案是 init container 运行时注入 IP，绕过了 musl 的限制。这个问题的排查过程让我对"容器不等于完整 Linux 环境"有了深刻的认知。

**选择 B — IUA Setters Bug（推荐，因为体现架构决策能力）：**
FluxCD v2.9.2 的 ImageUpdateAutomation 有 Setters 策略 Bug，不管你设什么 `images.name`，它都把完整镜像引用写进 `newTag`。我们花了 2 天排错（改域名格式、试短格式、翻 FluxCD GitHub issues 确认是已知 Bug），最终决定废弃 IUA，改由 CI 直接更新 Kustomize 的 tag。这个决策不是绕开问题，而是基于"更符合我们的部署模式"的判断——CI 本就知道 tag，没必要等 FluxCD 去猜。

**选择 C — 国内环境部署的系列问题（体现适应性和工程韧性）：**
从 GitHub 二进制下载慢（78MB 超时）→ Docker Hub 被墙（daocloud 镜像源）→ daocloud 本身偶尔不可用（SSH 反向隧道代理兜底）→ node-02/03 无公网（airgap 分发）→ ACR 新个人版不支持公网拉取（VPC 域名 + registries.yaml 认证）→ flux bootstrap HTTPS 超时（手动 SSH deploy key 安装）。环环相扣，每一个网络限制都迫使你理解底层原理去找替代方案。这些"国产化"问题虽然在简历上只是一行字，但实际解决时学到了大量 Linux 网络和容器镜像拉取的底层知识。

---

#### Q17: 如果让你重新做一遍，有什么会做得不一样？

**回答要点（展示成长性思维）：**

1. **一开始就用 SSH 连接 FluxCD**：第一次用 flux bootstrap 卡在 HTTPS 超时上，其实 FluxCD 官方文档就有 SSH 方式的示例，但没仔细看。以后遇到类似问题先确认网络连通性再选连接方式。
2. **先做 airgap 方案调研**：Node-02/03 无公网是 Phase 1 就知道的，但直到 Phase 2 部署 K3s 时才发现 node-02/03 拉不了镜像。如果提前调研 K3s 的 airgap 部署要求，Phase 1 的 ECS 配置阶段就可以规划好。
3. **Ansible 先测试幂等性**：有些 Playbook 写完后没测试重复执行，结果第二次执行时 MySQL 的 RPM 又装了一遍导致冲突。后来加了很多 `when`/`creates` 检查。
4. **给 node-02/03 加个备用 EIP**：现在 node-01 挂了就无法外部访问 node-02/03，虽然已经有 VNC 备用，但运维上不够灵活。

---

#### Q18: 你就 3 台服务器，这个项目用了多少技术栈？会不会有点"为了用而用"？

**这是面试官在测试你的技术判断力和务实精神——不要慌，正面回应。**

**回答要点：**

（先承认）确实有这个风险。我在项目初期也反复问自己这个问题。

（再解释）但我区分了三类技术：
1. **P0（解决实际问题的）**：K3s、MySQL HA、Redis HA、GitHub Actions、FluxCD——这些是这个项目要做的事必需的技术，没有它们集群跑不起来、CI/CD 做不了。
2. **P1（体现工程质量的）**：Terraform（IaC 接入）、Ansible（批量部署一致性）、NetworkPolicy、RBAC、SecurityContext——这些是"做好"和"做完"的区别，而且每一层都解决了一个真实问题（权限提升、网络攻击平面、密钥泄露）。
3. **P2（学习的）**：Trivy 扫描、Velero 备份——这些确实有点超前，但我把它们当作"证明我能学习和集成新工具"的样本。

**核心逻辑**：中厂 SRE 的技术栈不会比这个少。实际工作中 Ansible + Terraform + CI/CD + K8s + MySQL + Redis 是标配。我在项目里把这些工具串起来形成完整的工作流，而不是孤立的"用过"。而且每一个我都踩过坑、写过修复、做过生产化配置——不是装完就跑。

---

### 【场景题】

#### Q19: 假设你值班收到告警：短链服务不可用，你怎么排查？

**按 SRE 排查方法论——分层定位：**

```
1. 先看全局：
   curl http://<集群公网入口IP>/health  → 是否返回 {"status":"ok"}
   ssh node-01 "k3s kubectl get pods -A" → 哪些 Pod 异常

2. 定位到异常 Pod 后：
   ├── Pod Pending     → kubectl describe pod → 看 Events
   │   ├── 镜像拉取失败 → 检查 registries.yaml 和 ACR 连通性
   │   └── 资源不足    → kubectl describe node → 检查 CPU/内存
   ├── Pod CrashLoop   → kubectl logs pod → 看应用日志
   │   ├── 数据库连接失败 → 检查 ProxySQL/MySQL
   │   ├── Redis 连接失败 → 检查 Sentinel/Redis
   │   └── 配置错误    → 检查 ConfigMap/Secret
   └── Pod Running 但返回 5xx → 检查应用本身逻辑

3. 数据库层（如果 ProxySQL 或 MySQL 有问题）：
   ├── ProxySQL 状态   → mysql -h proxysql -P 6032 -u admin
   │   ├── SELECT * FROM runtime_mysql_servers → 看哪些后端 ONLINE
   │   └── SELECT * FROM monitor.mysql_server_read_only_log → 看看 read_only 切换记录
   ├── MySQL 状态      → SHOW REPLICA STATUS\G → 检查复制线程
   └── Orchestrator    → GET /api/topology/192.168.1.230/3306 → 看拓扑

4. Redis 层：
   ├── Sentinel 状态   → SENTINEL master mymaster → 看 Master IP
   └── Redis 数据       → redis-cli GET <key> → 验证数据能读

5. 网络层（如果 Service 不可达）：
   ├── NetworkPolicy   → kubectl get networkpolicy -n app-layer
   ├── Service         → kubectl describe svc shortlink
   └── Ingress         → kubectl describe ingress shortlink
```

**关键认知**：不要跳层排查。先验证最外层的访问，再逐层深入。很多新人在数据库层排查了半天，最后发现是 Ingress 配置问题。

---

#### Q20: 你对接手的中厂 K8s 集群，第一周会做什么？

**这是考察 SRE 的风险意识和生产流程认知。**

第一周不会急着改配置，会做 **4 件事**：

1. **读文档 / 问人**（周 1-2）：
   - 找到集群的架构文档、部署手册、Secrets 管理方式
   - 了解团队在用的工具链（Helm？Kustomize？Flux/Argo？）
   - 了解生产变更流程（谁审批？什么时间窗口可以变更？）
   - 了解告警规则和 On-Call 流程

2. **搭环境**（周 1-2）：
   - 配置本地 kubectl + 环境切换（如果有多个集群）
   - 搭建开发/测试环境，确保可以在非生产环境做实验

3. **读集群现状**（周 2-3）：
   - `kubectl get nodes` — 节点状态、版本分布
   - `kubectl get pods -A` — 有哪些 Namespace、哪些 Workload
   - `kubectl get networkpolicy -A` — 现有安全策略
   - `kubectl describe quota -A` — 资源限制
   - 看现有备份策略和恢复演练记录
   - 看近期 Fire 的 Ticket 了解常见问题

4. **做一个小改进**（周 2-4）：
   - 找一个小且安全的问题改（比如文档过期、告警阈值调整、加一个自动化脚本）
   - 走完一整套变更流程：提 MR → 审查 → 测试 → 灰度 → 全量 → 观察
   - 目的不是改多少东西，而是**学会团队的变更规范**

**核心原则**：SRE 的第一要务是**不引入故障**，不是证明自己多能干。

---

### 【量化指标类】

> 简历上写出的每一个数字，面试官都可能要求你给出测量方法、构成分解和打破条件。本节针对 Result 部分的量化指标逐条深挖。备份此前未量化，Q24 为**拟设场景**（数字基于 2C4G 硬件合理推算，实际面试前应在集群上自测校准后写入简历）。

---

#### Q21: 简历写"MySQL 复制延迟 < 1s"——这个数字怎么测出来的？

**回答要点：**

两套测量方案，粗精互补（对应 phase-3 Step 6 的延迟测量步骤）：

| 方案 | 精度 | 用途 |
|------|------|------|
| `Seconds_Behind_Master` 循环采样 | 秒级 | 日常巡检、快速确认复制线程健康 |
| `pt-heartbeat --monitor` | 0.01s 亚秒级 | 精确测量端到端真实延迟 |

- **口径**：`Seconds_Behind_Master` 10 次采样恒为 0；`pt-heartbeat --monitor` 当前延迟 0.0x s，1min/5min 均值 ≤ 0.1s → 汇总为"复制延迟 < 1s"
- **为什么必须用 pt-heartbeat**：`Seconds_Behind_Master` 取的是"SQL 线程正在回放的事件"的时间戳，IO 线程有积压但 SQL 线程追平时仍显示 0，且空闲时恒为 0、粒度只有整秒——它只能证明"没有秒级以上的延迟"，不能证明延迟真的接近 0
- **压力下也验证过**：Master 循环写入 1000 行，`--monitor` 观察延迟短暂上升后回落至 ~0

**追问：什么情况下这个 <1s 会被打破？** 三种典型场景：① 大事务——单条 INSERT 10 万行的 binlog 事件，Slave 单线程回放耗时等于 Master 执行耗时，延迟瞬间抬高；② Slave 单 SQL 线程瓶颈——本项目未开启并行复制（`replica_parallel_workers`），写入 QPS 高时会积压，但短链写入低频，单线程足够；③ 磁盘 IO 竞争——xtrabackup 备份期间 Slave 读 IO 饱和，延迟会上升，所以备份放凌晨低峰。主动讲出"我调低了复杂度：数据量小 + 写入低频，不值得为亚秒延迟引入并行复制/MGR"，比堆参数更能体现判断力。

---

#### Q22: "Redis failover < 10s"——这 10 秒里每一段耗时是多少？

**回答要点：**

10s 不是拍的，是按参数逐段分解后留了余量的：

| 阶段 | 耗时 | 参数依据 |
|------|------|----------|
| 主观下线判定 | 5s | `down-after-milliseconds=5000` |
| 客观下线 + Sentinel Leader 选举 | ~1-2s | 3 Sentinel 内网 RTT < 1ms |
| 提升 Slave（`SLAVEOF NO ONE`） | < 1s | 内存操作 |
| 其余 Slave 重新同步新 Master | ~2s | `parallel-syncs=1`，数据量小全量同步快 |
| 客户端感知新 Master 地址 | ~1s | shortlink 通过 Sentinel 定期刷新拓扑 |

实测触发手动 failover 到新 Master 可写约 7s，简历写 < 10s 留了余量。

**追问 1：能不能优化到 5s？代价是什么？** 把 `down-after-milliseconds` 调到 2s，判定提前 3s。代价是误判风险上升——瞬时网络抖动/主进程 GC 停顿超过 2s 就会触发无谓切换，每次切换本身有写入闪断。生产上 5s 是"快速切换"和"防误判"的常见折中。

**追问 2：failover 窗口内会丢数据吗？** 可能丢——Redis 主从是异步复制，被提升的 Slave 可能落后原 Master 几条未同步的写命令。但本架构中 Redis 只是缓存层（MySQL 才是数据源），丢的写会在缓存未命中时从 MySQL 重建，业务无感知。能讲清"技术上会丢 + 架构上可接受 + 为什么"三层，是这个指标最有价值的展开。

**追问 3：为什么 `parallel-syncs=1`？** 多个 Slave 同时对新 Master 全量同步会打爆其 CPU/带宽（Redis 全量同步 = RDB 生成 + 传输），逐个同步牺牲收敛速度换新 Master 稳定。

---

#### Q23: "git push 到生产上线 ~4min"——4 分钟花在哪？还能再压吗？

**回答要点：**

| 阶段 | 耗时 | 说明 |
|------|------|------|
| go vet + go test | ~60s | 单测量小，Actions 缓存 module 后更快 |
| docker buildx 多阶段构建 | ~80s | Go 编译是大头（GOMODCACHE 缓存后 ~60s） |
| push ACR | ~15s | 最终镜像仅 7.5MB |
| Trivy 扫描 | ~20s | 漏洞库增量更新 |
| sed + git commit/push | ~5s | 更新 kustomization newTag |
| FluxCD 检测新 commit | 0-60s | SourceController 默认轮询 1min，均值 ~30s |
| 滚动更新 + 健康检查 | ~30s | maxSurge 1 + readinessProbe 逐个替换 |

合计 ~4min（FluxCD 轮询按均值计）。

**追问：怎么优化到 1min？为什么不做？** 手段有三个：① Flux 配置 webhook receiver 替代 1min 轮询（省 ~30s）；② buildx 用 GitHub Actions 缓存（省 ~30s）；③ Trivy 漏洞库缓存（省 ~10s）。不做的原因：个人项目发布频率极低，4min 无感，webhook 需要暴露公网 receiver 端点引入新的安全面——为不存在的需求加复杂度，和 Q18 "不为用而用"是同一个原则。

---

#### Q24: 【拟设备份场景】备份用时 / 恢复用时是多少？RPO 是多少？

> 简历中备份只有"7 天保留、流程已验证"，没有时间量化。以下场景为**拟设**（10GB 数据规模、2C4G 硬件推算），面试前应实际跑一次校准数字。

**拟设量化口径：**

| 环节 | 拟设数值 | 计算依据 |
|------|---------|---------|
| MySQL 数据规模 | 10 GB | shortlink 库灌入压测数据后的规模（2C4G ECS 可承受） |
| xtrabackup 全量（Slave 上，`xbstream \| gzip` 流式） | ~5 min | 瓶颈是 gzip 压缩 ~40MB/s（2C 单核）：10GB ÷ 40MB/s ≈ 4min，加 redo 合并开销 |
| 压缩后备份包 | ~2.5 GB | 行数据文本为主，gzip 压缩比 ~4:1 |
| ossutil 上传 OSS | ~1 min | ECS → OSS 同地域内网带宽 50MB/s+ |
| **全量备份总用时** | **~6 min** | 02:00 开始 02:06 完成，距 Velero 02:30 有 24min 余量 |
| **恢复总用时（RTO）** | **~25 min** | OSS 下载 2.5GB ~1min + `--prepare`（长尾，~8min）+ `--copy-back` ~4min + 启动重建 GTID 复制 ~2min；Velero 侧 restore ~5min |

**回答要点：** 备份窗口是设计出来的，不是碰运气——MySQL 02:00、Velero 02:30 错峰 30min，且全量 6min 远小于窗口；RTO 的长尾在 `--prepare`（重放 redo 到一致性点位），不是数据传输。

**Velero 侧 restore ~5min 的构成（要能拆开讲）：** Velero 备份的持久卷是 Redis 的 3 个 PVC（每个 512Mi，local-path；实际占用仅百 MB 级——缓存语义，数据远小于容量，kopia FSB 备份的是实际文件而非 PVC 容量）：

| 阶段 | 耗时 | 说明 |
|------|------|------|
| API 资源重建 | ~1min | 恢复 namespace / Secret / StatefulSet / Service / PVC 对象 |
| kopia 数据回灌 | ~1min | node-agent 从 OSS 下载 PVC 数据；数据量小，耗时是 kopia 解压校验的固定开销 |
| Workload 有序拉起 | ~2-3min | redis-0 → 1 → 2 串行（StatefulSet 有序性），每个 Pod 含 init container（DNS 修复）+ readiness 就绪；Sentinel StatefulSet 同理 |

**追问 1：为什么用 `xbstream | gzip` 流式管道，而不是先落盘再压缩？** node-03 是 2C4G + 40GB 系统盘，数据目录已 10GB，落盘压缩需要额外 10GB 临时空间，磁盘余量扛不住。流式管道内存占用恒定、磁盘零额外占用，代价是压缩 CPU 成为瓶颈拉长用时——小磁盘机器上用时间换空间，是正确取舍。

**追问 2：为什么在 Slave 上备份而不是 Master？一致性怎么保证？** 备份的读 IO 压力和 redo 拷贝都隔离在 Slave 上，不抖动 Master 写入。一致性方面：xtrabackup 本身是 crash-consistent（备份起点记录 checkpoint LSN，prepare 时重放 redo）；再加 `--slave-info` 记录备份时刻的 GTID 位点，恢复后 `SOURCE_AUTO_POSITION=1` 从该位点续传复制，不丢不重。

**追问 3：每天一次全量，RPO 是多少？下午 Master 磁盘坏了丢多少数据？** 分场景：

- **节点整体故障**：Orchestrator 提升 Slave，RPO ≈ 复制延迟（< 1s），与备份无关
- **误删数据（DROP TABLE）**：秒级同步到 Slave，主从同时丢——只能回到凌晨全量，最坏丢 ~20h 数据
- **真正的改进项**：binlog 备份（PITR）。用 `mysqlbinlog --read-from-remote-server` 实时拉 binlog 推 OSS，RPO 收敛到秒级；最低限度用 ossutil 分钟级同步 binlog 目录。目前 binlog 只在物理机本地，这是本项目"未来改进"清单第一项——面试主动讲出比被问到体面得多

**追问 4：凌晨 2 点的备份 cron 挂了，你怎么知道？** 现状的诚实回答：退出码和推送结果写进巡检报告，周报才能发现，滞后最多一周。正确做法是备份完成后立即校验产物：① OSS 对象存在且大小 > 历史最小值的 70%（防 gzip 出空包/半包）；② 定期恢复演练——**可恢复的备份才算备份**，校验"备份存在"只是及格线。企业里这是备份成功率 SLA + 告警。

**追问 5：如果数据涨到备份超过 30min 窗口，和 Velero 重叠了怎么办？** 三个手段按序上：① Velero 窗口顺延（两套备份互不依赖，重叠只影响 OSS 带宽峰值，不会互相破坏）；② MySQL 改全量+增量（周全量 + `xtrabackup --incremental` 日增量，日备份降到分钟级）；③ 备份与上传流水线化（`xbstream | gzip | ossutil` 三段管道边备边传）。关键是先讲清"重叠不致命"，再讲优化顺序。

---
