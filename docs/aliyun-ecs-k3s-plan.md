# 阿里云 ECS K3s 集群方案

> 日期：2026-07-19
> 状态：方案设计

## 1. 现有服务器调研

### 1.1 实例信息

| 项目 | 值 |
|------|-----|
| **实例类型** | `ecs.e-c1m1.large`（经济型 e 实例，非轻量应用服务器） |
| **地域/可用区** | cn-hangzhou / cn-hangzhou-i |
| **VPC** | vpc-bp1oq6uale5r4id9beupn（172.16.0.0/12） |
| **vSwitch** | vsw-bp171csb7bkm1n0156f3b |
| **内网 IP** | 172.26.5.95 |
| **公网 IP** | 47.114.124.150 |
| **操作系统** | Alibaba Cloud Linux 3.2104 U10（OpenAnolis Edition, RHEL 系） |
| **内核** | 5.10.134-17.2.al8.x86_64 |
| **CPU** | 2 vCPU（Intel Xeon Platinum, 超线程） |
| **内存** | 1.8 GiB（已用 1.3 GiB，可用 ~350 MB） |
| **磁盘** | 40 GB（已用 17 GB，剩余 21 GB） |
| **运行时间** | 71 天 |

### 1.2 运行中的服务

| 容器 | 镜像 | 端口 | 用途 |
|------|------|------|------|
| astrbot | soulter/astrbot:latest | 6185, 6186 | AI 聊天机器人 |
| napcat | mlikiowa/napcat-docker:latest | 6099 | QQ 机器人框架 |

### 1.3 关键结论

- **该实例实为 ECS 经济型 e 实例**，已在 VPC 内，可同 VPC 新购 ECS 实例通过内网互通
- **内存仅剩 ~350 MB**，无法在本机上运行 K3s，但可复用为 Ansible 控制节点 / Jump Host
- **操作系统为 RHEL 系**（Alibaba Cloud Linux 3），现有 Ansible Playbook（apt 系）需适配为 yum/dnf 系

## 2. 推荐方案：3 节点 ECS 经济型 e 实例 + K3s HA

### 2.1 架构概述

```
                        ┌─────────────────────────────────────────────────┐
                        │              阿里云 VPC (172.16.0.0/12)           │
                        │              cn-hangzhou-i                       │
                        │                                                 │
   Internet             │   ┌──────────────────────────────────────┐      │
      │                 │   │   vSwitch: vsw-bp171csb7bkm1n0156f3b │      │
      │                 │   │                                      │      │
      ▼                 │   │  ┌─────────────┐  ┌─────────────┐    │      │
  ┌────────┐            │   │  │  k3s-node-1 │  │  k3s-node-2 │    │      │
  │公网 IP │──── SSH ───┼──▶│  │ 172.26.5.x  │  │ 172.26.5.y  │    │      │
  │47.114  │  (Jump)    │   │  │ K3s Server  │  │ K3s Server  │    │      │
  │.124.150│            │   │  │ + etcd      │  │ + etcd      │    │      │
  └────────┘            │   │  │ 2C2G 40G    │  │ 2C2G 40G    │    │      │
       │                │   │  └──────┬──────┘  └──────┬──────┘    │      │
  ┌────────┐            │   │         │    VPC 内网     │            │      │
  │现有ECS  │            │   │         └───────┬────────┘            │      │
  │astrbot │            │   │                 │                     │      │
  │napcat  │            │   │         ┌───────┴──────┐              │      │
  └────────┘            │   │         │  k3s-node-3  │              │      │
                        │   │         │ 172.26.5.z   │              │      │
                        │   │         │ K3s Server   │              │      │
                        │   │         │ + etcd       │              │      │
                        │   │         │ 2C2G 40G     │              │      │
                        │   │         └──────────────┘              │      │
                        │   └──────────────────────────────────────┘      │
                        └─────────────────────────────────────────────────┘
```

### 2.2 实例规划

| 节点 | 实例类型 | vCPU | 内存 | 系统盘 | 内网 IP | K3s 角色 | 预估月费 |
|------|---------|------|------|--------|---------|---------|---------|
| k3s-node-1 | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB ESSD Entry | 172.26.5.x | server + etcd | ~45 元 |
| k3s-node-2 | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB ESSD Entry | 172.26.5.y | server + etcd | ~45 元 |
| k3s-node-3 | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB ESSD Entry | 172.26.5.z | server + etcd | ~45 元 |
| **现有 ECS** | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB | 172.26.5.95 | Ansible + kubectl | 已有 |
| | | | | | | **合计新增** | **~135 元/月** |

> 价格参考：经济型 e 实例 ecs.e-c1m1.large 包月约 45 元/月（杭州），按量约 0.12 元/小时。
> 如选包年可更低（~35 元/月）。实际以阿里云控制台为准。

### 2.3 K3s HA 架构（3 Server + Embedded etcd）

| 组件 | 配置 |
|------|------|
| **K3s 模式** | embedded etcd HA（3 server 节点组成 etcd 集群） |
| **API Server** | 6443/tcp，每节点均运行 |
| **etcd** | 2379-2380/tcp，节点间内网通信 |
| **flannel VXLAN** | 8472/udp，Pod 网络互联 |
| **kubelet** | 10250/tcp，每节点均运行 |
| **metrics-server** | 默认安装 |
| **LB / 公网入口** | 阿里云 SLB（可选）或 DNS 轮询 |

> ECS 每台拥有独立网络命名空间，`127.0.0.1` 不共享，
> K3s supervisor（6444）、etcd（2379）、containerd（10010）均无端口冲突。

### 2.4 网络与安全

**安全组规则（K3s 节点安全组）：**

| 方向 | 协议 | 端口 | 源/目标 | 用途 |
|------|------|------|---------|------|
| 入 | TCP | 22 | 现有 ECS 内网 IP / 公网 | SSH 管理 |
| 入 | TCP | 6443 | 0.0.0.0/0（或限范围） | K3s API Server |
| 入 | TCP | 2379-2380 | 同安全组内 | etcd 集群通信 |
| 入 | TCP | 10250 | 同安全组内 | kubelet |
| 入 | UDP | 8472 | 同安全组内 | flannel VXLAN |
| 入 | TCP | 80, 443 | 0.0.0.0/0 | 业务 Ingress |
| 出 | ALL | ALL | 0.0.0.0/0 | 默认允许 |

**内网通信：** 同 VPC 同 vSwitch 的 ECS 实例通过内网 IP 互通，免费且低延迟。

### 2.5 操作系统选择

| 选项 | 优点 | 缺点 | 推荐 |
|------|------|------|------|
| **Alibaba Cloud Linux 3** | 与现有服务器一致；免费；RHEL 兼容；内核 5.10 | Playbook 需改 apt→yum | ⭐⭐⭐ |
| Ubuntu 22.04 | Playbook 无需改；社区资源多 | 需下载镜像（但 ECS 直接选镜像） | ⭐⭐⭐⭐ |
| Ubuntu 24.04 | 最新 LTS；cgroups v2 原生 | 部分软件兼容性 | ⭐⭐⭐ |

> **推荐 Alibaba Cloud Linux 3**：与现有服务器统一，免费用阿里云内网 yum 源（速度快），
> Playbook 适配工作量不大（apt→dnf，包名微调）。简历上也能体现多 OS 适配能力。

## 3. Ansible Playbook 适配清单

ECS 实例使用 Alibaba Cloud Linux 3（RHEL 8 系），Ansible Playbook 需按以下规范配置：

### 3.1 `group_vars/all.yml`

```yaml
# --- 修改项 ---
# 1. 节点 IP 改为 VPC 内网 IP
node_ips:
  k3s-node-1: 172.26.5.x    # 新购 ECS 1 内网 IP
  k3s-node-2: 172.26.5.y    # 新购 ECS 2 内网 IP
  k3s-node-3: 172.26.5.z    # 新购 ECS 3 内网 IP

# 2. K3s 架构改为 HA
k3s_cluster_mode: ha          # 新增：ha | single
k3s_first_server: k3s-node-1
k3s_first_server_ip: 172.26.5.x

# 3. flannel 网卡（ECS 默认 eth0）
k3s_flannel_iface: eth0
```

### 3.2 `inventory.ini`

```ini
[k3s_servers]
k3s-node-1 ansible_host=172.26.5.x
k3s-node-2 ansible_host=172.26.5.y
k3s-node-3 ansible_host=172.26.5.z

[k3s_agents]
# 无 agent 节点（3 server HA）

[k3s_cluster:children]
k3s_servers

[k3s_cluster:vars]
ansible_user=ops
ansible_ssh_private_key_file=~/.ssh/id_rsa

[ansible_controller]
# 现有 ECS 作为控制节点
aliyun ansible_host=172.26.5.95
```

### 3.3 `00-init-system.yml` 适配

| 原 (Ubuntu/apt) | 改为 (Alibaba Cloud Linux 3/dnf) |
|-----------------|----------------------------------|
| `apt: update_cache=true` | `dnf: update_cache=true`（或 `yum`） |
| `apt: upgrade=dist` | `dnf: name=* state=latest` |
| `apt: name={{ base_packages }}` | `dnf: name={{ base_packages }}` |
| `service: name=ssh` | `service: name=sshd` |
| `groups: sudo` | `groups: wheel` |
| `chrony` 包名 | `chrony`（一致） |

> 可用 Ansible 的 `ansible_os_family` 变量做条件判断，同时支持 Ubuntu 和 RHEL 系，
> 体现 Playbook 的跨平台能力（简历加分）。

### 3.4 `k3s-config.yaml.j2` 适配

```yaml
# HA 模式配置（3 server + embedded etcd）
node-ip: {{ node_ips[inventory_hostname] }}
node-name: {{ inventory_hostname }}
flannel-iface: eth0

# 所有 server 节点共享
write-kubeconfig-mode: "0644"
tls-san:
  - {{ node_ips[inventory_hostname] }}
  - 47.114.124.150    # 可选：现有 ECS 公网 IP（用于外部 kubectl 访问）

# etcd HA 配置
cluster-init: {% if inventory_hostname == k3s_first_server %}true{% else %}false{% endif %}
server: https://{{ k3s_first_server_ip }}:{{ k3s_api_port }}
```

> ECS 有独立 loopback，无端口冲突，无需额外配置。

### 3.5 `01-deploy-k3s.yml` 适配

| 改动项 | 说明 |
|--------|------|
| HA 模式安装 | server 节点添加 `--cluster-init`（首节点）和 `--server`（join 节点） |
| 公网下载 | ECS 可通过 NAT/公网直接下载 K3s 二进制，无需离线复制 |
| 新增 etcd 健康检查 | `k3s etcd-snapshot` 验证 |

## 4. 实施步骤

### Phase 0：ECS 实例创建（手动 / Terraform）

1. 阿里云控制台 → ECS → 创建实例
   - 地域：杭州（与现有实例同 VPC/vSwitch）
   - 实例规格：ecs.e-c1m1.large
   - 镜像：Alibaba Cloud Linux 3.2104
   - 系统盘：40 GB ESSD Entry
   - 安全组：新建 K3s 安全组（见 2.4）
   - 数量：3 台
   - 不分配公网 IP（通过现有服务器做 Jump Host）

2. 记录 3 台实例的内网 IP

3. 在现有服务器上配置 SSH 免密到新实例

### Phase 1：系统初始化（Ansible Playbook 00）

```bash
# 在现有 ECS 上运行
ansible-playbook -i inventory.ini playbooks/00-init-system.yml
```

### Phase 2：K3s HA 部署（Ansible Playbook 01）

```bash
ansible-playbook -i inventory.ini playbooks/01-deploy-k3s.yml
```

### Phase 3：集群验证

```bash
kubectl get nodes -o wide          # 3 节点 Ready
kubectl get pods -A                # 核心组件 Running
kubectl get cs                     # scheduler/controller-manager Healthy
ETCDCTL_API=3 k3s etcdctl \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint status                   # etcd 3 节点健康
```

### Phase 4：外部访问配置

```bash
# 在现有服务器上配置 kubectl
scp ops@172.26.5.x:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's/127.0.0.1/172.26.5.x/' ~/.kube/config
kubectl get nodes
```

## 5. 成本估算

| 项目 | 月费 | 年费（包年优惠） |
|------|------|----------------|
| ECS ecs.e-c1m1.large × 3 | ~135 元 | ~1,200 元 |
| ESSD Entry 40G × 3 | 含在实例费中 | — |
| 公网带宽（现有服务器） | 已有 | — |
| NAT 网关（可选，如需新实例出公网） | ~25 元 | ~300 元 |
| SLB（可选，API Server LB） | ~30 元 | ~360 元 |
| **最小方案**（3 ECS only） | **~135 元** | **~1,200 元** |
| **完整方案**（+ NAT + SLB） | **~190 元** | **~1,860 元** |

> 最小方案即可完成简历项目目标。NAT 和 SLB 为可选项，如果新实例需要自行下载包
> 或需要外部访问 API Server 才需要。

## 6. 方案优势总结

| 维度 | **阿里云 ECS** |
|------|----------------------|
| 网络隔离 | ✅ 每台 ECS 独立网络命名空间，无 loopback 冲突 |
| K3s 架构 | **3 Server HA + embedded etcd** |
| 简历含金量 | ⭐⭐⭐⭐⭐（公有云 + IaC + HA） |
| 公有云经验 | **有（面试加分）** |
| 部署难度 | 低（Terraform 声明式 + Ansible Playbook 自动化） |
| 月成本 | ~135 元（项目完成后可随时释放） |
| 额外收益 | **可部署业务对外访问，公网 IP + SLB** |

> 花费 ~135 元/月获得一个真正的公有云 HA K8s 集群，简历项目含金量直接拉满。

## 7. 风险与注意事项

1. **经济型 e 实例性能限制**：CPU 有性能基线限制（突发积分制），K3s 部署阶段可能耗尽积分
   导致降频。部署完成后正常负载下无影响。
2. **Alibaba Cloud Linux 3 兼容性**：K3s 官方支持 RHEL 8+，Alibaba Cloud Linux 3 基于
   RHEL 8（platform:al8），兼容性良好。
3. **安全组配置**：etcd 端口（2379/2380）务必限制为同安全组内，不要对公网开放。
4. **数据安全**：K3s 卸载会清除 etcd 数据，部署前做好快照。
