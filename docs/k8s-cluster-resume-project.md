# 基于 K3s 的高可用短链服务集群 — 项目需求规格与简历内容

## 一、项目概述

### 1.1 项目定位

面向校招运维 / SRE 岗位的集群基础设施项目，重点展示 **集群架构设计、部署管理、数据高可用、自动化 CI/CD、安全加固与备份容灾** 能力。业务场景刻意保持简单（短链跳转），将精力集中在基础设施运维本身。

> **关于可观测性**：监控告警、日志收集等可观测性体系由简历另一项目单独承载，本项目不涉及，避免内容重叠。本项目聚焦"基础设施运维"主线。

### 1.2 设计原则

| 原则 | 说明 |
|------|------|
| 校招适配 | 3 台 2C4G 虚拟机 |
| 生产级标准 | 架构设计、配置写法、安全策略对标生产环境 |
| IaC 优先 | 所有部署通过代码完成，环境可一键复现 |
| 重点突出 | 聚焦集群基础设施运维，业务逻辑极简 |

---

## 二、运维技能矩阵（需求分析与头脑风暴）

### 2.1 原始需求拆解

| 原始需求 | 对应运维技能方向 | 为什么需要 |
|---------|----------------|-----------|
| K8s 体系 (k3s/k0s) | 容器编排、集群生命周期管理 | 项目核心技术栈，面试官第一关注点 |
| 集群架构设计 / 部署 / 管理 | 架构设计、自动化部署、节点管理 | 展示系统性思维，不是只会 `kubectl apply` |
| Redis 容器部署高可用 | 有状态应用编排、Sentinel 机制 | 容器化有状态服务是 K8s 难点，区分度高 |
| 数据库物理机部署高可用 | 数据库运维、主从复制、故障切换 | 展示传统运维 + 现代运维结合的能力 |
| 简单业务场景（短链） | 应用容器化、镜像构建 | 业务够简单即可，重点在基础设施 |
| 学生友好硬件 | 资源规划、成本意识 | 校招项目不能要求万元服务器，要能落地 |
| 生产级技术 / 架构 / 配置 | 工程规范、最佳实践 | 面试官会追问配置细节，不能玩具化 |

### 2.2 补充需求分析（用户未提及但简历需要）

| 补充需求 | 技能方向 | 为什么简历需要 |
|---------|---------|---------------|
| **CI/CD 流水线** | GitHub Actions + ArgoCD GitOps | 校招运维岗核心考察点，没 CI/CD 等于没自动化 |
| **IaC 自动化部署** | Ansible Playbook | 展示"可复现部署"理念，不是手动 SSH 逐台配 |
| **安全加固** | RBAC + NetworkPolicy + Trivy | 生产级安全要求，面试会问"集群安全怎么做" |
| **备份容灾** | Velero + xtrabackup | 数据安全是底线，面试会问"数据丢了怎么办" |
| **Helm 包管理** | Helm Chart 编写 | K8s 生态标准工具，展示工程化能力 |
| **HPA 自动伸缩** | Horizontal Pod Autoscaler | 展示弹性伸缩能力 |
| **镜像仓库** | Harbor 私有仓库 | 生产环境不用 Docker Hub，展示私有化能力 |
| **配置管理** | ConfigMap + Secret + Kustomize | 环境隔离、配置分离是工程基本功 |

### 2.3 技能优先级

| 优先级 | 技能模块 | 理由 |
|-------|---------|------|
| **P0 必须** | K3s 集群部署、Redis HA、MySQL HA、CI/CD、Helm | 核心考察点，缺一不可 |
| **P1 推荐** | Ansible、RBAC / NetworkPolicy、Velero 备份 | 生产级必备，有了明显加分 |
| **P2 亮点** | ArgoCD GitOps、HPA、Trivy 镜像扫描、Harbor | 展示深度和 DevSecOps 意识 |

---

## 三、集群架构设计

### 3.1 硬件方案

| 方案 | 配置 | 成本 | 优缺点 |
|------|------|------|--------|
| A. 云 VPS（推荐） | 3 x 2C4G | ~200 元/月 | 真实公网 IP，可体验完整 Ingress；学生优惠更低 |
| B. 本地虚拟机 | 3 x 2C4G VM | 免费 | 零成本可重建；无公网 IP，Ingress 用 Hosts 模拟 |
| C. 混合方案 | 1 VPS + 2 本地 VM | ~50 元/月 | 兼顾成本与真实网络 |

**推荐方案 B**：本地虚拟机，零成本，随时销毁重建。简历注明"基于本地虚拟化环境模拟生产集群"即可。

### 3.2 节点角色分配

3 节点均为 Master + Worker，使用 K3s embedded etcd 实现控制面高可用。

| 节点 | 角色 | 部署组件 |
|------|------|---------|
| node-01 | Master + Worker + etcd | K3s server、ArgoCD、Harbor、Velero、Orchestrator (容器) |
| node-02 | Master + Worker + etcd | K3s server、短链 App Pod、Redis Master (容器)、Sentinel x1 (容器)、MySQL Master (物理机)、ProxySQL (容器) |
| node-03 | Master + Worker + etcd | K3s server、短链 App Pod、Redis Slave (容器)、Sentinel x2 (容器)、MySQL Slave (物理机)、xtrabackup 定时备份 |

**为什么 3 节点**：etcd 共识需要奇数节点，3 是最小 HA 单元，成本可控。

**为什么 k3s 而非 k8s**：轻量级（单二进制），内置 Traefik + Flannel + CoreDNS，资源友好；概念与 k8s 完全一致，简历可写"k8s 体系"。

### 3.3 架构总览

```
                       ┌──────────────────────────┐
                       │     External Traffic      │
                       │  Users + GitHub Actions   │
                       └────────────┬─────────────┘
                                    │
                       ┌────────────▼─────────────┐
                       │    Traefik Ingress        │
                       │    (K3s 内置)              │
                       └────────────┬─────────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         │                          │                          │
┌────────▼─────────┐    ┌──────────▼─────────┐    ┌──────────▼─────────┐
│     node-01      │    │     node-02        │    │     node-03        │
│ Master+Worker    │    │ Master+Worker      │    │ Master+Worker      │
│     + etcd       │    │     + etcd         │    │     + etcd         │
├──────────────────┤    ├────────────────────┤    ├────────────────────┤
│ K3s server       │    │ K3s server         │    │ K3s server         │
│ ArgoCD           │    │ URL App Pod        │    │ URL App Pod        │
│ Harbor           │    │ Redis Master (容器) │    │ Redis Slave (容器)  │
│ Velero           │    │ Sentinel x1 (容器)  │    │ Sentinel x2 (容器)  │
│ Orchestrator     │    │ MySQL Master (物理) │    │ MySQL Slave (物理)  │
│   (容器)         │    │ ProxySQL (容器)     │    │ xtrabackup 备份    │
└──────────────────┘    └────────────────────┘    └────────────────────┘
         │                          │                          │
         │                ┌─────────▼──────────┐               │
         └────────────────│   数据高可用层      │───────────────┘
                          ├────────────────────┤
                          │ Redis HA (容器化)   │  1主2从 + 3哨兵, 自动切换
                          │ MySQL HA (物理机)   │  主从复制 + Orchestrator
                          └────────────────────┘
```

### 3.4 数据库 HA 设计（物理机部署）

**为什么 MySQL 放物理机**：生产环境常见模式——核心数据不进容器，保证 I/O 性能和数据安全。与 Redis 容器化形成对比，展示"哪些该容器化、哪些不该"的架构判断力。

| 组件 | 部署方式 | HA 机制 | 说明 |
|------|---------|--------|------|
| MySQL 8.0 | 物理机直装 | 1 主 1 从异步复制 | GTID 模式，半同步可选 |
| Orchestrator | 容器化 (K3s Pod) | 自动故障检测 + 主从切换 | 拓扑可视化，故障自动恢复 |
| ProxySQL | 容器化 (K3s Pod) | 读写分离 | 对应用透明，写走 Master 读走 Slave |
| xtrabackup | 物理机 cron 定时 | 全量 + 增量备份 | 异地保存，支持 PITR |

**故障切换流程**：

1. Orchestrator 检测到 Master 不可用（连续探测失败）
2. 自动提升 Slave 为新 Master
3. 更新 ProxySQL 后端配置，流量切到新 Master
4. 原 Master 恢复后自动重连为 Slave

### 3.5 Redis HA 设计（容器化部署）

**为什么用 Sentinel 而非 Cluster**：短链场景数据量小、QPS 不高，Sentinel 足够；Cluster 分片复杂度高，不适合校招项目规模，但简历可写"可平滑迁移至 Cluster 模式"。

| 组件 | 部署方式 | HA 机制 | 说明 |
|------|---------|--------|------|
| Redis 7 | StatefulSet | 1 主 2 从 | 主从复制 |
| Sentinel | StatefulSet | 3 哨兵节点 | 自动故障检测与切换 |
| 持久化 | PVC (local-path) | RDB 快照 + AOF 日志 | 双持久化保障数据安全 |
| Service | ClusterIP + Headless | 客户端通过 Sentinel 发现 Master | 读写分离可选 |

**故障切换流程**：

1. Sentinel 节点定期检测 Master 存活
2. 超过 quorum (2/3) 判定 Master 下线
3. 选举新 Master，其余 Slave 跟随
4. 客户端通过 Sentinel 获取新 Master 地址

---

## 四、技术选型

| 层级 | 技术选型 | 选型理由 |
|------|---------|---------|
| 集群 | K3s (embedded etcd HA) | 轻量但概念完整，生产级配置 |
| 网络 | Flannel CNI + Traefik Ingress + CoreDNS | K3s 内置，减少额外配置 |
| 存储 | local-path-provisioner + PVC | 轻量，适合本地环境 |
| 数据库 | MySQL 8.0 (物理机) + Orchestrator + ProxySQL | 物理机 HA 标准方案 |
| 缓存 | Redis 7 + Sentinel (StatefulSet) | 容器化 HA 标准方案 |
| CI | GitHub Actions (lint -> test -> build -> push) | 免费额度够用，业界主流 |
| CD | ArgoCD (GitOps) | 声明式部署，配置即代码 |
| 镜像 | Docker 多阶段构建 + Harbor 私有仓库 | 镜像优化 + 私有化管理 |
| IaC | Ansible Playbook | 批量配置、一键部署 |
| 包管理 | Helm Chart + Kustomize | 应用打包 + 环境 overlay |
| 安全 | RBAC + NetworkPolicy + Trivy | 权限控制 + 网络隔离 + 镜像扫描 |
| 备份 | Velero (集群资源) + xtrabackup (MySQL) | 双备份策略 |
| 业务 | Go (Gin) + Redis + MySQL | 编译快、镜像小、适合容器化 |

---

## 五、业务场景设计（短链服务）

### 5.1 API 设计

```
POST /api/shorten    {"url": "https://example.com/very/long"}  -> {"code": "aB3xK9"}
GET  /:code          -> 301 Redirect -> 原始 URL
GET  /health         -> 健康检查 (Liveness/Readiness Probe 使用)
```

### 5.2 数据模型

```sql
CREATE TABLE url_mapping (
    id           BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    short_code   VARCHAR(10) NOT NULL UNIQUE,
    original_url TEXT NOT NULL,
    created_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_short_code (short_code)
) ENGINE=InnoDB;
```

### 5.3 技术栈选择

| 组件 | 选择 | 理由 |
|------|------|------|
| 语言 | Go (Gin 框架) | 编译快、二进制小、镜像可压到 20 MB 以内 |
| 存储 | MySQL | 持久化存储短码映射关系 |
| 缓存 | Redis | 缓存热点短码 -> 长 URL 映射，TTL 24h |
| 短码生成 | Base62 编码 (6 位) | 约 568 亿组合，足够使用 |

**为什么选短链**：逻辑极简（2 个 API），但涉及缓存 + 数据库 + HTTP 重定向，麻雀虽小五脏俱全。面试官不会追问业务逻辑，只会追问基础设施。

---

## 六、预期简历项目内容

### 6.1 项目名称与描述

**项目名称**：基于 K3s 的高可用短链服务集群设计与实现

**项目描述**：
设计并实现了一套面向生产环境的高可用 K3s 集群架构，承载短链跳转服务。涵盖集群部署、网络管理、数据高可用（Redis 容器化 + MySQL 物理机）、GitOps CI/CD、安全加固、备份容灾等基础设施全栈运维能力。

### 6.2 技术栈（简历直接可用）

> K3s / Ansible / Helm / ArgoCD / GitHub Actions / Redis Sentinel / MySQL 主从 / Orchestrator / ProxySQL / Harbor / Velero / Trivy / Go

### 6.3 项目职责

1. **集群架构与自动化部署**：设计 3 节点 K3s HA 集群（Master + Worker + embedded etcd），使用 Ansible Playbook 实现一键自动化部署，编写 Inventory 管理节点角色，通过 Helm Chart 统一管理应用 manifests

2. **Redis 容器化高可用**：使用 StatefulSet 部署 Redis Sentinel 集群（1 主 2 从 + 3 哨兵），实现自动故障检测与 Master 切换，配置 RDB + AOF 双持久化，PVC 挂载 local-path 存储保障数据安全

3. **MySQL 物理机高可用**：在物理机部署 MySQL 主从复制（GTID 模式），Orchestrator 实现自动故障检测与主从切换，ProxySQL 容器化部署实现读写分离，xtrabackup 定时全量 + 增量备份支持 PITR

4. **CI/CD 流水线**：搭建 GitHub Actions 构建流水线（代码检查 -> 多阶段镜像构建 -> 推送 Harbor 私有仓库），部署 ArgoCD 实现 GitOps 声明式发布，Git 仓库为唯一事实来源，支持版本回滚

5. **安全加固**：配置 RBAC 权限分级（admin / developer / readonly 三种 Role），NetworkPolicy 实现 Pod 间网络隔离（仅允许 App 访问 Redis / MySQL），Trivy 集成 CI 流水线做镜像漏洞扫描，阻断高危镜像入库

6. **弹性伸缩与调度**：配置 HPA 基于 CPU 使用率自动伸缩应用副本（2-6 副本），设置 PodDisruptionBudget 保障滚动更新最少可用副本数，配置 Liveness / Readiness Probe 实现自动故障恢复

7. **备份容灾**：Velero 定期备份集群资源（含 PV 快照），MySQL xtrabackup 异地备份，编写 Ansible 恢复 Playbook，定期执行恢复演练验证备份有效性

### 6.4 项目亮点

- **Redis 容器化 HA 与 MySQL 物理机 HA 形成对比**，体现"哪些该容器化、哪些不该"的架构判断力——面试高频追问点
- **全链路 IaC**：Ansible 部署集群 -> Helm 打包应用 -> ArgoCD 同步发布，环境可一键复现，消除"雪花服务器"
- **GitOps 模式**：Git 仓库为唯一事实来源，所有变更可审计、可回滚，符合 GitOps 原则
- **安全纵深**：RBAC 权限控制 + NetworkPolicy 网络隔离 + Trivy 镜像扫描，三层安全防线
- **数据双备份**：Velero 集群资源备份 + xtrabackup 数据库备份，覆盖"集群级"和"数据级"两个维度

---

## 七、后续实施路线

| 阶段 | 内容 | 产出 |
|------|------|------|
| Phase 1 | 基础环境搭建 | 3 节点 VM、SSH 免密、Ansible Inventory |
| Phase 2 | K3s 集群部署 | Ansible Playbook 一键部署 K3s HA 集群 |
| Phase 3 | 数据层部署 | MySQL 物理机主从 + Redis StatefulSet |
| Phase 4 | 应用部署 | 短链服务 Go 代码 + Dockerfile + Helm Chart |
| Phase 5 | CI/CD 流水线 | GitHub Actions + Harbor + ArgoCD |
| Phase 6 | 安全加固 | RBAC + NetworkPolicy + Trivy |
| Phase 7 | 备份容灾 | Velero + xtrabackup + 恢复演练 |
| Phase 8 | 文档整理 | README、架构文档、部署手册 |
