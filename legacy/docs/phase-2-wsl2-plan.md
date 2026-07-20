# Phase 2: K3s HA 集群部署

## 概述

### 目标

在 Phase 1 搭建的 3 节点 WSL2 环境上，通过 Ansible Playbook 一键部署 K3s HA 集群（embedded etcd 模式），实现控制面高可用。

### 产出物

| 产出 | 路径 | 说明 |
|------|------|------|
| K3s 配置模板 | `ansible/templates/k3s-config.yaml.j2` | 按节点角色生成 K3s config.yaml |
| 部署 Playbook | `ansible/playbooks/01-deploy-k3s.yml` | 4 个 Play：预检 → 首节点 → Join → 验证 |
| 更新的变量 | `ansible/group_vars/all.yml` | 新增 K3s 版本、端口、接口等变量 |
| 本计划文档 | `docs/phase-2-plan.md` | 你正在看的这个 |

### 部署后状态

| 节点 | K3s 角色 | etcd 成员 | 状态 |
|------|---------|----------|------|
| node-01 | Server (cluster-init) | ✅ | Ready, control-plane |
| node-02 | Server (join) | ✅ | Ready, control-plane |
| node-03 | Server (join) | ✅ | Ready, control-plane |

---

## K3s HA 架构说明

### Embedded etcd 模式

K3s 支持两种 HA 模式：

| 模式 | 外部数据库 | 说明 |
|------|----------|------|
| **外部 DB** | MySQL/PostgreSQL | 控制面无状态，依赖外部 DB HA |
| **Embedded etcd** (本项目) | 内置 etcd | 3 节点各运行 etcd 成员，自洽 HA |

本项目使用 **embedded etcd**，原因：
- 无需额外维护外部数据库
- etcd 分布式共识（Raft）需要奇数节点，3 节点正好满足
- 与生产级 K8s 集群架构一致（标准 kube-apiserver + etcd 模式）

### 部署顺序

```
                    ┌──────────────────────────────────────────────┐
  Step 1            │  node-01: k3s server --cluster-init         │
                    │  → 启动 etcd 集群（1/3 成员）                  │
                    │  → 启动 kube-apiserver, controller-manager   │
                    │  → 生成 cluster token                        │
                    └──────────────────┬───────────────────────────┘
                                       │ token
                    ┌──────────────────▼───────────────────────────┐
  Step 2            │  node-02: k3s server --server https://node01 │
  (serial: 1)       │  → 加入 etcd 集群（2/3 成员）                  │
                    │  → 同步集群状态                                │
                    └──────────────────┬───────────────────────────┘
                                       │
                    ┌──────────────────▼───────────────────────────┐
  Step 3            │  node-03: k3s server --server https://node01 │
  (serial: 1)       │  → 加入 etcd 集群（3/3 成员）                  │
                    │  → 集群达到完整 HA                            │
                    └──────────────────────────────────────────────┘
```

**为什么 serial: 1**：etcd 成员逐个加入，避免多节点同时加入导致的共识冲突。每次加入后等待 etcd 状态同步，再添加下一个。

---

## 安装策略

### 配置文件驱动（非 CLI 参数驱动）

K3s 支持两种配置方式：CLI 参数和配置文件。本项目使用 **配置文件** 方式：

```yaml
# /etc/rancher/k3s/config.yaml （由 Ansible 模板生成）
node-ip: 192.168.50.11          # 节点身份
flannel-iface: eth0              # WSL2 网络适配
write-kubeconfig-mode: "0644"   # 允许非 root 读取
cluster-init: true              # 仅首节点
# server: https://192.168.50.11:6443  # 仅 join 节点
```

**为什么用配置文件**：
- IaC 原则：配置即代码，可版本控制
- 可读性：YAML 比 CLI 参数链更清晰
- 可维护：修改配置后重启服务即可，不用改 systemd unit

### Token 传递机制

```
node-01 安装 K3s → 生成 /var/lib/rancher/k3s/server/node-token
                        │
                   Ansible 读取并 set_fact (cacheable: true)
                        │
                   hostvars['node-01']['k3s_cluster_token']
                        │
                   node-02/03 安装时通过 K3S_TOKEN 环境变量传入
```

### 幂等性设计

Playbook 可安全重复执行：
- `which k3s` 检查是否已安装 → 已安装则跳过安装步骤
- 配置文件通过 template 模块部署 → 内容不变时不会触发变更
- 等待任务通过 `until/retries/delay` 实现 → 已就绪则立即通过

### K3s 安装脚本

使用官方安装脚本 `curl -sfL https://get.k3s.io | sh -`，原因：
- 自动处理二进制下载、systemd 服务创建、环境配置
- 创建 killall/uninstall 工具脚本（运维需要）
- 是 K3s 官方推荐的标准安装方式

---

## Playbook 结构

### 文件：`ansible/playbooks/01-deploy-k3s.yml`

| Play | 目标节点 | 功能 | 关键任务 |
|------|---------|------|---------|
| 1. Pre-flight | 全部 3 节点 | 环境预检 | swap、systemd、IP 别名、节点连通性、K3s 已装检查 |
| 2. First Server | node-01 | 首节点部署 | 创建配置 → 安装 K3s → 等待就绪 → 读取 token → 配置 kubectl |
| 3. Join Servers | node-02, node-03 | Join 部署 (serial:1) | 创建配置 → 安装 K3s (带 token) → 等待加入 → 配置 kubectl |
| 4. Verify | node-01 | 集群验证 | get nodes、get pods、etcd health、cluster-info |

### Play 间数据传递

```
Play 1: k3s_installed (per-node fact) → 后续 Play 判断是否跳过安装
Play 2: k3s_cluster_token (set_fact, cacheable) → Play 3 通过 hostvars 读取
Play 3: join_result (delegate_to: node-01) → 从 node-01 检查节点是否加入
Play 4: 最终验证输出
```

### 关键设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 配置方式 | config.yaml 文件 | IaC 原则，可版本控制 |
| Token 传递 | K3S_TOKEN 环境变量 | 安装脚本标准方式，持久化到 systemd env file |
| Join 顺序 | serial: 1 | etcd 逐个加入，避免共识冲突 |
| kubectl 访问 | 复制 kubeconfig 到 ops 用户 | 非 root 也能用 kubectl |
| etcd 快照 | 每 12 小时自动快照 | 生产级配置，支持灾备 |

---

## 执行步骤

### 前提条件

- [x] Phase 1 完成：3 节点 WSL2 实例运行中，SSH 免密，Ansible 可用
- [x] 所有节点 swap 已关闭
- [x] 所有节点 IP 别名（192.168.50.1X）已配置

### Step 1: 启动所有 WSL 节点

```powershell
# 确保所有节点运行中
.\scripts\start-all-nodes.ps1
```

### Step 2: 上传更新的 Ansible 项目到 node-01

> Phase 2 新增了 `templates/k3s-config.yaml.j2`、`playbooks/01-deploy-k3s.yml`，
> 并更新了 `group_vars/all.yml`。需要同步到 node-01。

```powershell
# 上传新增的 templates 目录
scp -r ansible/templates node-01:/home/ops/ansible/

# 上传新的 playbook
scp ansible/playbooks/01-deploy-k3s.yml node-01:/home/ops/ansible/playbooks/

# 上传更新的 group_vars
scp ansible/group_vars/all.yml node-01:/home/ops/ansible/group_vars/
```

### Step 3: 语法检查

```powershell
ssh node-01
```

```bash
cd /home/ops/ansible
ansible-playbook --syntax-check -i inventory.ini playbooks/01-deploy-k3s.yml
```

### Step 4: 执行部署

```bash
# 在 node-01 上执行
cd /home/ops/ansible
ansible-playbook -i inventory.ini playbooks/01-deploy-k3s.yml
```

> 预计耗时：5-10 分钟（含 K3s 下载安装 + etcd 集群形成）

### Step 5: 验证集群

```bash
# 节点状态
kubectl get nodes -o wide

# 所有 Pod
kubectl get pods -A

# etcd 健康
sudo k3s etcdctl endpoint health
sudo k3s etcdctl member list

# 集群信息
kubectl cluster-info
```

### Step 6: 配置宿主机 kubectl（可选但推荐）

```powershell
# 在 Windows PowerShell 中执行

# 1. 创建 .kube 目录
mkdir $env:USERPROFILE\.kube -Force

# 2. 从 node-01 拉取 kubeconfig
scp node-01:/home/ops/.kube/config $env:USERPROFILE\.kube\config

# 3. 验证
kubectl get nodes
```

---

## WSL2 特殊注意事项

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| `--node-ip` 必须指定 | WSL2 所有 distro 共享 eth0，默认 IP 相同 | config.yaml 中 `node-ip: 192.168.50.1X` |
| `--flannel-iface` 必须指定 | WSL2 网络接口可能被误检测 | config.yaml 中 `flannel-iface: eth0` |
| etcd 成员通信 | 所有 IP 别名在同一 eth0 上 | 无需额外配置，IP 别名保证可达性 |
| ServiceLB 行为 | WSL2 无真实外部 IP | 不影响集群内部通信，本地测试够用 |
| 节点重启后恢复 | WSL2 重启后 K3s 自动启动 | systemd 管理的 K3s 服务会自动恢复 |
| WSL2 自动回收 | 无进程时 distro 自动关闭 | 用 `start-all-nodes.ps1` 或 `sleep infinity` 保活 |
| `br_netfilter` 可能不可用 | WSL2 自定义内核 | K3s Flannel 在 VXLAN 模式下不依赖 br_netfilter |

---

## K3s 内置组件说明

K3s 默认安装以下组件，本阶段 **不做任何裁剪**：

| 组件 | 作用 | 是否保留 |
|------|------|---------|
| Flannel (VXLAN) | Pod 网络 CNI | ✅ 保留 |
| CoreDNS | 集群 DNS | ✅ 保留 |
| Traefik | Ingress Controller | ✅ 保留（项目 Ingress 方案） |
| ServiceLB | LoadBalancer 服务 | ✅ 保留（本地测试用） |
| Metrics Server | 资源指标采集 | ✅ 保留（HPA 依赖） |
| local-path-provisioner | 本地存储 CSI | ✅ 保留（PVC 使用） |

> 后续 Phase 可按需禁用或替换组件（如 Traefik → Nginx Ingress），但 Phase 2 先用默认配置确保集群可用。

---

## 验证清单

部署完成后逐项验证：

- [ ] `kubectl get nodes` 显示 3 个节点，状态均为 `Ready`
- [ ] 3 个节点角色均为 `control-plane,master`
- [ ] `kubectl get pods -A` 所有 Pod 状态为 `Running` 或 `Completed`
- [ ] CoreDNS Pod 运行中（通常 2 副本）
- [ ] Traefik Ingress Pod 运行中
- [ `k3s etcdctl endpoint health` 返回 3 个 endpoint 健康
- [ ] `k3s etcdctl member list` 显示 3 个成员
- [ ] node-01 上 `kubectl get nodes` 可直接使用（kubeconfig 已配置）
- [ ] 宿主机 `kubectl get nodes` 可用（kubeconfig 已拉取）
- [ ] 重新运行 Playbook 验证幂等性（不重复安装）

---

## 下一步

Phase 2 完成后，进入 **Phase 3: 数据层部署**：

1. **MySQL 物理机主从**：在 node-02 / node-03 上部署 MySQL 8.0，配置 GTID 主从复制
2. **Redis 容器化 HA**：用 StatefulSet 部署 Redis Sentinel 集群（1 主 2 从 + 3 哨兵）
3. **数据层验证**：测试主从同步、Sentinel 故障切换、数据持久化
