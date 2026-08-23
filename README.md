<div align="center">
<h1 align="center">DevOps K3s HA Lab</h1>
<p align="center"><strong>面向 DevOps/SRE 校招的 K3s 高可用集群教学项目</strong></p>
<p align="center">
<img alt="K3s" src="https://img.shields.io/badge/K3s-v1.28-FFC61C?logo=k3s&logoColor=white" />
<img alt="FluxCD" src="https://img.shields.io/badge/FluxCD-v2.9-4169E1?logo=flux&logoColor=white" />
<img alt="Go" src="https://img.shields.io/badge/Go-1.22-00ADD8?logo=go&logoColor=white" />
<img alt="MySQL" src="https://img.shields.io/badge/MySQL-8.0-4479A1?logo=mysql&logoColor=white" />
<img alt="Redis" src="https://img.shields.io/badge/Redis-7.2-DC382D?logo=redis&logoColor=white" />
<img alt="GitHub Actions" src="https://img.shields.io/badge/GitHub_Actions-CI/CD-2088FF?logo=githubactions&logoColor=white" />
<img alt="Alibaba Cloud" src="https://img.shields.io/badge/Alibaba_Cloud-ECS-FF6A00?logo=alibabacloud&logoColor=white" />
<img alt="License" src="https://img.shields.io/badge/License-MIT-green" />
</p>
</div>
---

## 项目简介

本项目完整搭建了一套**生产级 K3s 高可用集群**，集成 **FluxCD GitOps** 持续部署与 **GitHub Actions** 持续集成，运行一个 Go 短链服务（Shortlink）。

> 🎯 **定位**：面向 **DevOps / SRE 校招面试**的教学项目，覆盖容器化、Kubernetes、CI/CD、基础设施即代码等核心技能栈。

| 知识点 | 涵盖内容 |
|--------|---------|
| 🐳 **容器化** | Docker 多阶段构建、镜像瘦身（~7.5MB）、ACR 镜像仓库管理 |
| ☸️ **Kubernetes** | K3s HA 部署、Pod 调度、HPA、PDB、Ingress、ConfigMap、Secret |
| 🔄 **CI/CD** | GitHub Actions 流水线、FluxCD GitOps 声明式部署、镜像自动更新 |
| 🗄️ **数据层** | MySQL 读写分离（ProxySQL）、Redis 哨兵模式高可用、Orchestrator 故障切换 |
| 🌐 **网络** | VPC 内网、Traefik Ingress、SSH 反向隧道、ACR 双域名策略 |
| 🔐 **安全** | 非 root 运行、Secret 管理、SSH 部署密钥、最小权限原则 |
| 📐 **架构** | 高可用设计、故障域隔离、漂移纠正、滚动更新、优雅关闭 |

---

## 架构总览

### 请求流

```text
                  ┌──────────────┐
                  │ 🌍 用户 :80  │
                  └──────┬───────┘
                         │
                  ┌──────▼───────┐
                  │   Traefik    │
                  │   Ingress    │
                  └──────┬───────┘
                         │
                  ┌──────▼───────┐
                  │  Shortlink   │
                  │  Go + Gin    │
                  │  2-6 replicas│
                  │  HPA + PDB   │
                  └──┬───┬───┬───┘
                     │   │   │
          ┌──────────┘   │   └──────────┐
          │              │              │
   ┌──────▼──────┐   ┌───▼────┐  ┌──────▼──────┐
   │  ProxySQL   │   │  Redis │  │Orchestrator │
   │  读写分离    │   │Sentinel │  │GTID 故障切换 │
   └──┬──────┬───┘   └───┬────┘  └──────┬──────┘
      │      │            │             │
 ┌────▼──┐ ┌─▼─────┐  ┌───▼────┐        │
 │ MySQL │ │MySQL  │  │ Redis  │        │
 │Primary│ │Replica│  │Primary │        │
 └───────┘ └───────┘  └────────┘        │
      ^                                 │
      └─────────────────────────────────┘
```

### 集群拓扑

```
┌───────────────────┬───────────────────┬───────────────────┐
│     node-01       │     node-02       │     node-03       │
│  ┌─────────────┐  │                   │                   │
│  │ FluxCD ×6   │  │  Shortlink Pod    │  Shortlink Pod    │
│  │AntiAffinity │  │  AntiAffinity     │  AntiAffinity     │
│  ├─────────────┤  │                   │                   │
│  │etcd + 控制面 │  │  etcd + 控制面     │  etcd + 控制面     │
│  └─────────────┘  │                   │                   │
│  公网IP ✅        │                   │                   │
└───────────────────┴───────────────────┴───────────────────┘
```

---

## CI/CD 流程

```text
git push (app/ 或 Dockerfile 变更)
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Actions                                                 │
│   ① go vet + go test                                            │
│   ② Docker build（多阶段 · ldflags 注入版本号）                    │
│   ③ push → ACR 公网域名（v1.0.{run_number}）                      │
│   ④ sed 更新 k8s/app-layer/kustomization.yaml newTag             │
│   ⑤ git commit + push（GITHUB_TOKEN · contents: write）          │
└──────────────────────────────────┬──────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│  FluxCD                                                         │
│   ① SourceController 检测新 commit（~1min）                       │
│   ② KustomizeController kustomize build + 滚动更新               │
│   ③ healthChecks 等待 shortlink Deployment 健康                  │
│   ④ 漂移纠正：手动修改 → 自动恢复                                   │
└──────────────────────────────────┬──────────────────────────────┘
                                   │
                                   ▼
                          ✅ 新版本部署完成
                    curl http://host/health
                  {"status":"ok","version":"v1.0.N"}
```

---

## 项目结构

<details open>
<summary>点击展开/收起</summary>

```ascii
.
├── .github/workflows/
│   └── build-deploy.yml         # CI 流水线：构建 → 推送 → 更新 tag
├── app/
│   ├── main.go                  # Go 短链服务（Gin + MySQL + Redis）
│   ├── go.mod
│   └── go.sum
├── Dockerfile                   # 多阶段构建（daocloud 镜像源）
├── k8s/
│   ├── cert-manager/            # 自签 CA 私有 PKI（ClusterIssuer + 根 CA）
│   │   ├── namespace.yaml
│   │   ├── clusterissuer-selfsigned.yaml
│   │   └── clusterissuer-ca.yaml
│   ├── data-layer/              # Redis、Sentinel、ProxySQL、Orchestrator
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml        # PSS labels + ResourceQuota + LimitRange
│   │   ├── sa.yaml               # ServiceAccounts (redis, proxysql, orchestrator)
│   │   ├── rbac.yaml             # RoleBindings → view ClusterRole
│   │   ├── networkpolicy.yaml    # 白名单隔离 (9 policies)
│   │   ├── redis-configmap.yaml
│   │   ├── redis-statefulset.yaml
│   │   ├── sentinel-statefulset.yaml
│   │   ├── orchestrator.yaml
│   │   └── proxysql.yaml
│   └── app-layer/               # Shortlink 应用层
│       ├── kustomization.yaml   # 镜像 tag 由 CI 自动更新
│       ├── namespace.yaml        # PSS labels + ResourceQuota + LimitRange
│       ├── sa.yaml               # ServiceAccounts (shortlink-app, developer, viewer)
│       ├── rbac.yaml             # Roles (app-developer, app-viewer) + RoleBindings
│       ├── networkpolicy.yaml    # 白名单隔离 (4 policies)
│       ├── configmap.yaml
│       ├── shortlink.yaml       # Deployment + Service
│       ├── ingress.yaml         # Traefik Ingress
│       └── hpa.yaml             # HPA + PDB
├── clusters/production/         # FluxCD 自定义资源
│   ├── data-layer.yaml          # Kustomization CR（基础层）
│   ├── app-layer.yaml           # Kustomization CR（应用层, dependsOn）
│   ├── image-repo.yaml          # ImageRepository（扫描 ACR）
│   ├── image-policy.yaml        # ImagePolicy（semver）
│   └── image-update.yaml        # ImageUpdateAutomation（已暂停）
├── ansible/
│   └── playbooks/
│       ├── 00-init-system.yml   # 系统初始化
│       ├── 01-deploy-k3s.yml    # K3s 集群部署
│       ├── 02-deploy-mysql.yml  # 数据层部署
│       ├── 03-configure-acr.yml # ACR 配置
│       ├── 04-setup-backup-tools.yml  # 备份工具安装
│       ├── 05-restore-mysql.yml      # MySQL 恢复
│       └── 08-db-inspect.yml         # 数据库自动巡检部署
├── terraform/                   # IaC
├── scripts/
│   ├── autossh-tunnel.sh        # SSH 反向隧道守护脚本
│   ├── check-tunnel.sh          # 隧道健康检查
│   ├── build-push.sh            # 手动构建推送
│   ├── xtrabackup-backup.sh     # MySQL xtrabackup 异地备份
│   └── db-inspect.sh            # MySQL 自动巡检（7 维度 → OSS）
└── docs/
```

</details>

---

## 技术栈

<table>
<thead><tr><th>分类</th><th>技术</th><th>用途</th></tr></thead>
<tbody>
<tr><td rowspan="4"><b>基础设施</b></td><td>Terraform</td><td>IaC 创建 VPC + ECS + EIP + 安全组</td></tr>
<tr><td>Alibaba Cloud ECS</td><td>3 台云服务器（node-01 2C2G + node-02/03 2C4G）</td></tr>
<tr><td>K3s v1.28</td><td>轻量 K8s 发行版，嵌入式 etcd HA</td></tr>
<tr><td>Ansible</td><td>集群部署自动化（初始化 → K3s → 数据层 → ACR）</td></tr>
<tr><td rowspan="3"><b>容器化</b></td><td>Docker</td><td>多阶段构建（Alpine ~7.5MB）</td></tr>
<tr><td>ACR</td><td>阿里云容器镜像仓库（公网+VPC 双域名）</td></tr>
<tr><td>containerd + nerdctl</td><td>K3s 内置 CRI，离线构建用 nerdctl + buildkitd</td></tr>
<tr><td rowspan="3"><b>CI/CD</b></td><td>GitHub Actions</td><td>CI 流水线：vet → test → build → push → update tag</td></tr>
<tr><td>FluxCD v2.9</td><td>GitOps：Source + Kustomize + Image Automation + Notification</td></tr>
<tr><td>Flux Image Automation</td><td>ACR 镜像扫描 + ImagePolicy semver 选择</td></tr>
<tr><td rowspan="3"><b>应用层</b></td><td>Go 1.22 + Gin</td><td>短链服务（358 行，REST API）</td></tr>
<tr><td>ProxySQL</td><td>MySQL 读写分离（Read/Write Splitting）</td></tr>
<tr><td>Redis Sentinel</td><td>Redis 高可用（自动故障切换）</td></tr>
<tr><td rowspan="5"><b>运维</b></td><td>Traefik Ingress</td><td>K3s 内置七层负载均衡 + HTTPS（TLS 1.2+）</td></tr>
<tr><td>cert-manager</td><td>自签 CA 私有 PKI（selfSigned → CA Issuer 两阶段签发）</td></tr>
<tr><td>Velero FSB</td><td>集群资源 + PVC 数据备份（kopia 上传 OSS）</td></tr>
<tr><td>HPA + PDB</td><td>水平扩缩容（CPU 70%）+ 最小可用保证</td></tr>
<tr><td>SSH 反向隧道</td><td>本地 ↔ 集群安全通道（autossh 自动重连）</td></tr>
</tbody>
</table>

---

## 学习路线

本项目按 5 个 Phase 递进构建，每阶段产出可独立验证：

| Phase | 内容 | 关键产出 |
|-------|------|---------|
| **Phase 1** 🏛️ | IaC：Terraform 基础设施创建 | 新建 VPC + 3 ECS + EIP + 安全组，cloud-init 初始化 |
| **Phase 2** ☸️ | K3s HA 集群部署 | Ansible Playbook 一键部署 K3s HA（embedded etcd） |
| **Phase 3** 🗄️ | 数据层部署 | MySQL 物理机主从 + Orchestrator + ProxySQL + Redis Sentinel |
| **Phase 4** 🚀 | 应用部署 | 短链服务 Go + Gin、多阶段构建、Traefik Ingress + ACR |
| **Phase 5** 🔄 | CI/CD 流水线 | GitHub Actions + FluxCD GitOps |
| **Phase 6** 🔒 | 安全加固 | RBAC 权限分级 + NetworkPolicy + Trivy 镜像扫描 |
| **Phase 7** 💾 | 备份容灾 | Velero 集群备份 + xtrabackup MySQL 异地备份 + 恢复演练 |
| **Phase 8** 📊 | HTTPS + 数据库自动巡检 | cert-manager 自签 CA（私有 PKI）+ 7 维度 MySQL 自动巡检 → OSS 趋势留存 |

各 Phase 详细文档在 [`docs/`](docs/) 目录，包含完整的**踩坑记录**（涵盖国内网络环境下的各种实际问题）。

---

## 快速开始

> 非开箱即用，部分基础设施和变量仍需手动配置，此处仅供参考

### 前置条件

```bash
# 1. 本地安装 SSH 客户端 + kubectl + terraform
# 2. GitHub 仓库 + ACR 容器镜像仓库
# 3. 创建云厂商 AccessKey、ACR 凭证，并配置 ansible 组变量（group_vars/all.yml）与 github secret
# 4. 3 台同 VPC 的 Alibaba Cloud ECS（推荐 2C4G）
# 5. 在其中一台 ECS 上部署 Ansible
```

### 部署

```bash
# 0. Phase 1：Terraform IaC — 创建 VPC + 3 ECS + EIP（参考 docs/phase-1-plan-IaC.md）
cd terraform && terraform apply

# 1. 系统初始化（所有节点）
ansible-playbook ansible/playbooks/00-init-system.yml

# 2. 部署 K3s HA
ansible-playbook ansible/playbooks/01-deploy-k3s.yml

# 3. 部署数据层（MySQL + Redis）
ansible-playbook ansible/playbooks/02-deploy-mysql.yml

# 4. 配置 ACR
ansible-playbook ansible/playbooks/03-configure-acr.yml

# 5. 安装 FluxCD（国内环境需手动安装 controller + SSH deploy key）
# 详见 docs/phase-5-cicd.md

# 6. 推送应用
kubectl apply -k k8s/app-layer/
```

### 验证

```bash
# 检查集群状态
kubectl get nodes
kubectl get pods -A

# 访问短链服务
curl http://<公网IP>/health
# → {"status":"ok","version":"v1.0.0"}

# 创建短链
curl -X POST http://<公网IP>/api/shorten \
  -H "Content-Type: application/json" \
  -d '{"url":"https://kubernetes.io"}'
# → {"short_code":"1","short_url":"http://host/1"}
```

---

## 功能验证

| 功能 | 状态 |
|------|------|
| ✅ K3s HA（3 control-plane + etcd） | 任意节点宕机不影响集群 |
| ✅ MySQL HA（ProxySQL + Orchestrator GTID） | 自动主从切换 |
| ✅ Redis HA（Sentinel） | 自动故障转移 |
| ✅ 短链服务 API | POST 创建 / GET 301 跳转 / Health 检查 |
| ✅ HPA 自动扩缩容 | CPU > 70% 自动扩容至 6 副本 |
| ✅ PDB 最小可用 | 最多 1 个 Pod 不可用 |
| ✅ GitOps 声明式部署 | 集群与 Git 永久一致，漂移自动纠正 |
| ✅ CI/CD 自动化 | git push → 自动构建 → 自动部署 |
| ✅ 滚动更新 + 优雅关闭 | 零宕机更新 |
| ✅ RBAC 三层权限 | admin / developer (CRUD) / viewer (只读) |
| ✅ NetworkPolicy 白名单 | 12 条流量规则，default deny + allow list |
| ✅ SecurityContext + PSS | app-layer=restricted, data-layer=baseline |
| ✅ Trivy CI 扫描 | HIGH/CRITICAL 阻断部署，SARIF 上传 |
| ✅ ResourceQuota | namespace 资源总量限制 + LimitRange 默认值 |
| ✅ HTTPS + cert-manager | 自签 CA 私有 PKI（两阶段 ClusterIssuer + TLS Ingress）|
| ✅ MySQL 自动巡检 | 7 维度巡检 + 错误日志 + 告警 → OSS 趋势留存（每周日 02:00）|

---

## 拓展方向

- **Helm Charts**：将 Kustomize 扁平结构迁移为 Helm Chart，提升包管理和版本化能力

---

## 参考

- [K3s 官方文档](https://docs.k3s.io)
- [FluxCD 文档](https://fluxcd.io/flux/)
- [GitHub Actions 文档](https://docs.github.com/en/actions)
- [阿里云 ACR 文档](https://www.alibabacloud.com/help/en/acr/)
- [Gin Web Framework](https://gin-gonic.com)
- [ProxySQL 文档](https://proxysql.com/documentation/)
- [Redis Sentinel 文档](https://redis.io/docs/management/sentinel/)

---

<div align="center">
If you find this project helpful for your DevOps/SRE interview prep, give it a ⭐!<br>
Built with ❤️ for learning and sharing.
</div>
