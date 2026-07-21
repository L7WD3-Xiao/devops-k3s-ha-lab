# Phase 1: Terraform IaC — 阿里云 ECS 基础设施创建

> 日期：2026-07-15 ~ 2026-07-21
> 状态：**已完成**
> 前置文档：[aliyun-ecs-k3s-plan.md](aliyun-ecs-k3s-plan.md)（方案调研，部分已过时）
> 配置细化：[terraform-config-detail.md](terraform-config-detail.md)（分步创建策略，已过时，待清理）

---

## 1. 概述

### 1.1 目标

使用 **Terraform** 在阿里云杭州地域创建全新的 VPC + 3 台 ECS 实例，组成 K3s HA 集群的物理基础设施。通过 cloud-init 完成系统初始化，node-01 绑定按量 EIP 提供互联网出口和 SSH 直连。

### 1.2 方案变更说明

> ⚠️ 原方案（[aliyun-ecs-k3s-plan.md](aliyun-ecs-k3s-plan.md)）计划复用现有 SWAS 实例的 VPC (172.16.0.0/12) 和 Jump Host。实施时发现 **SWAS 与 ECS API 隔离，VPC 不互通**，因此改为新建 VPC + 全新 ECS 方案。

| 项目 | 原方案（已废弃） | 实际方案 |
|------|----------------|---------|
| VPC | 复用 SWAS VPC (172.16.0.0/12) | **新建 VPC (192.168.0.0/16)** |
| vSwitch | 复用 vsw-bp171csb7bkm1n0156f3b (cn-hangzhou-i) | **新建 vswitch (192.168.1.0/24, cn-hangzhou-h)** |
| node-01 | 复用现有 SWAS 实例 (import) | **新建 ECS** |
| 公网访问 | SWAS 做 Jump Host (47.114.124.150) | **node-01 绑按量 EIP (116.62.168.245)** |
| 实例规格 | 3 台全部 2C2G | **node-01 2C2G, node-02/03 2C4G**（Phase 3 前升级） |
| 密钥对 | 控制台预创建 | **Terraform 自动创建并导入公钥** |

### 1.3 产出物

| 产出 | 路径 / 资源 | 说明 |
|------|------------|------|
| Terraform 项目 | `terraform/` | main.tf / variables.tf / outputs.tf / user-data.sh / setenv.sh |
| VPC | vpc-bp1yjb43u1ht8jdoqdw31 | 192.168.0.0/16, cn-hangzhou |
| VSwitch | vsw-bp13ew0svbez0hez2gvhi | 192.168.1.0/24, cn-hangzhou-h |
| 安全组 | sg-bp1807co8efnr2upllnb | K3s 集群安全组 |
| SSH 密钥对 | k3s-cluster-key | Terraform 创建，导入本机公钥 |
| ECS × 3 | 见 §2.1 | node-01 + EIP, node-02/03 纯内网 |
| EIP | 116.62.168.245 | 绑定 node-01, PayByTraffic |

---

## 2. 基础设施现状

### 2.1 节点规划

| 节点 | 实例类型 | vCPU | 内存 | 系统盘 | 内网 IP | EIP | K3s 角色 |
|------|---------|------|------|--------|---------|-----|---------|
| k3s-node-01 | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB ESSD Entry | 192.168.1.228 | 116.62.168.245 | server + etcd |
| k3s-node-02 | ecs.e-c1m2.large | 2 | 4 GiB | 40 GB ESSD Entry | 192.168.1.230 | — | server + etcd |
| k3s-node-03 | ecs.e-c1m2.large | 2 | 4 GiB | 40 GB ESSD Entry | 192.168.1.229 | — | server + etcd |

> node-01 保持 2C2G（仅跑 K3s 控制面 + FluxCD + Velero，不跑 MySQL）。
> node-02/03 在 Phase 3 前升级到 2C4G（跑 MySQL 物理机主从，2C2G 内存余量 <200MB 有 OOM 风险）。

### 2.2 网络拓扑

```
                        ┌─────────────────────────────────────────────────┐
                        │         阿里云 VPC (192.168.0.0/16)               │
                        │         cn-hangzhou / cn-hangzhou-h               │
                        │                                                 │
   Internet             │   ┌──────────────────────────────────────┐      │
      │                 │   │  VSwitch: 192.168.1.0/24             │      │
      ▼                 │   │                                      │      │
  ┌────────┐            │   │  ┌─────────────┐  ┌─────────────┐   │      │
  │  EIP   │──── SSH ───┼──▶│  │  k3s-node-01│  │ k3s-node-02 │   │      │
  │116.62  │  直连 22   │   │  │ 192.168.1.228│  │192.168.1.230│   │      │
  │.168.245│            │   │  │ K3s Server  │  │ K3s Server  │   │      │
  └────────┘            │   │  │ + etcd      │  │ + etcd      │   │      │
       │ 互联网出口      │   │  │ 2C2G 40G    │  │ 2C4G 40G    │   │      │
       ▼                │   │  └──────┬──────┘  └──────┬──────┘   │      │
  (K3s/镜像下载)        │   │         │   VPC 内网      │          │      │
                        │   │         └───────┬────────┘          │      │
                        │   │         ┌───────┴──────┐           │      │
                        │   │         │  k3s-node-03 │           │      │
                        │   │         │192.168.1.229 │           │      │
                        │   │         │ K3s Server   │           │      │
                        │   │         │ + etcd       │           │      │
                        │   │         │ 2C4G 40G     │           │      │
                        │   │         └──────────────┘           │      │
                        │   └──────────────────────────────────────┘      │
                        └─────────────────────────────────────────────────┘
```

### 2.3 安全组规则

安全组 `sg-bp1807co8efnr2upllnb`，所有节点共用：

| 方向 | 协议 | 端口 | 源/目标 | 用途 |
|------|------|------|---------|------|
| 入 | TCP | 22 | 0.0.0.0/0 | SSH（EIP 直连 + SWAS 内网互通跳板） |
| 入 | TCP | 6443 | 0.0.0.0/0 | K3s API Server（kubectl 远程访问） |
| 入 | TCP | 2379-2380 | 192.168.0.0/16 | etcd 集群通信（仅 VPC 内部） |
| 入 | TCP | 10250 | 192.168.0.0/16 | kubelet（仅 VPC 内部） |
| 入 | UDP | 8472 | 192.168.0.0/16 | flannel VXLAN（仅 VPC 内部） |
| 入 | TCP | 80, 443 | 0.0.0.0/0 | 业务 Ingress |
| 出 | ALL | ALL | 0.0.0.0/0 | 默认允许 |

> SSH 开放 0.0.0.0/0 是因为 node-01 有 EIP 直连，同时 SWAS 内网互通也需要访问。
> etcd 端口严格限制在 VPC CIDR 内，不对公网开放。

### 2.4 操作系统

| 镜像 | 说明 |
|------|------|
| Alibaba Cloud Linux 3.2104 LTS 64位 | RHEL 8 兼容，内核 5.10，免费使用阿里云内网 yum 源 |

> Terraform 镜像查询 name_regex: `^aliyun_3_x64_20G_alibase_`（非 `alibaba_cloud_linux_3.*`，阿里云镜像命名规则）。

---

## 3. Terraform 项目设计

### 3.1 目录结构

```
terraform/
├── main.tf              # 主配置：provider + VPC + 安全组 + 3 实例 + EIP
├── variables.tf         # 输入变量（含分步创建控制 + 升级规格变量）
├── outputs.tf           # 输出（IP、实例 ID、Ansible inventory 片段）
├── user-data.sh         # cloud-init 初始化脚本
├── terraform.tfvars     # 变量赋值（含 ops 公钥，.gitignore 排除）
├── setenv.sh            # 阿里云凭证环境变量加载脚本（.gitignore 排除）
├── terraform.tfstate    # 状态文件（.gitignore 排除）
└── .terraform.lock.hcl  # Provider 版本锁定
```

### 3.2 关键设计决策

#### 3.2.1 分步创建控制（余额保护）

不使用 `count` 一次性创建 3 台，而是为每个节点单独定义 resource block + 布尔控制变量：

```hcl
variable "create_node_01" { default = false }
variable "create_node_02" { default = false }
variable "create_node_03" { default = false }
variable "create_eip"     { default = false }
```

**原因**：
1. 每台 ECS ~45 元/月，逐台创建可控制成本风险
2. 首台创建后验证 cloud-init 正确性，再创建后续节点
3. 单独 resource block 便于 `terraform apply -target` 精确操作单台实例
4. 后续升级规格时也可 `-target` 单台操作，保持 etcd quorum

#### 3.2.2 VPC 新建（非复用 SWAS VPC）

原方案计划复用现有 SWAS 的 VPC (172.16.0.0/12)，实施时发现 SWAS 与 ECS API 隔离，VPC 不互通。改为新建独立 VPC (192.168.0.0/16)，所有资源 Terraform 原生管理。

#### 3.2.3 EIP 按量计费

node-01 绑定按量 EIP (PayByTraffic, 0.8 元/GB)，用途：
- SSH 直连（无需 Jump Host）
- 互联网出口（下载 K3s 二进制、容器镜像）
- kubectl 远程访问 API Server

预估费用：安装阶段一次性 ~3 元，后续 < 1 元/月。

#### 3.2.4 密钥对 Terraform 管理

使用 `alicloud_ecs_key_pair` 资源自动创建密钥对并导入本机公钥，无需控制台手动创建：

```hcl
resource "alicloud_ecs_key_pair" "k3s" {
  key_pair_name = var.ssh_key_name
  public_key    = var.ops_pubkey
}
```

> 注意：用 `key_pair_name`（非已废弃的 `key_name`）。

### 3.3 `variables.tf` — 关键变量

```hcl
# ── 网络配置 ──
variable "vpc_cidr"      { default = "192.168.0.0/16" }
variable "vswitch_cidr"  { default = "192.168.1.0/24" }
variable "zone_id"       { default = "cn-hangzhou-h" }

# ── 实例规格 ──
variable "instance_type"          { default = "ecs.e-c1m1.large" }  # 2C2G, node-01
variable "instance_type_upgraded" { default = "ecs.e-c1m2.large" }  # 2C4G, node-02/03

# ── 镜像 ──
# 留空则自动查询：name_regex = "^aliyun_3_x64_20G_alibase_"

# ── 分步创建控制 ──
variable "create_node_01" { default = false }
variable "create_node_02" { default = false }
variable "create_node_03" { default = false }
variable "create_eip"     { default = false }

# ── SSH 密钥 ──
variable "ssh_key_name" { default = "k3s-cluster-key" }
variable "ops_pubkey"   { default = "" }  # 在 terraform.tfvars 中设置

# ── 用户 ──
variable "ops_user" { default = "ops" }
```

### 3.4 `main.tf` — 资源架构

```
alicloud_vpc.k3s                    ── 新建 VPC
├── alicloud_vswitch.k3s            ── 新建 VSwitch
├── alicloud_security_group.k3s     ── 安全组
│   └── alicloud_security_group_rule.* (8 条规则)
├── alicloud_ecs_key_pair.k3s       ── SSH 密钥对
├── alicloud_instance.k3s_node_01   ── ECS node-01 (2C2G, count=create_node_01)
├── alicloud_instance.k3s_node_02   ── ECS node-02 (2C4G, count=create_node_02)
├── alicloud_instance.k3s_node_03   ── ECS node-03 (2C4G, count=create_node_03)
├── alicloud_eip_address.k3s_node_01        ── EIP (count=create_eip)
└── alicloud_eip_association.k3s_node_01    ── EIP 绑定 node-01
```

> 每个实例 resource block 使用 `count = var.create_node_XX ? 1 : 0` 控制是否创建。
> outputs.tf 中用 `length(alicloud_instance.k3s_node_XX) > 0` 判断是否有值。

### 3.5 `user-data.sh` — cloud-init 初始化

```bash
#!/bin/bash
# cloud-init user-data for K3s cluster nodes (templatefile 渲染)
# 关键步骤：
# 1. 关闭 swap
# 2. 内核参数 (ip_forward, bridge-nf-call-iptables)
# 3. 安装基础包 (dnf)
# 4. 时区 Asia/Shanghai + chronyd
# 5. 创建 ops 用户 + sudo NOPASSWD
# 6. 配置 ops SSH 公钥
# 7. 禁用 firewalld
# 8. 标记完成 /tmp/cloud-init-k3s-done
```

> **踩坑修复**：Alibaba Cloud Linux 3 (RHEL 8 系) 包名 `iproute` 而非 `iproute2`（Debian 系）。cloud-init 首次执行时 `dnf install iproute2` 失败，改为 `iproute` 后通过。

---

## 4. 实施时间线

### Phase A: 免费资源（2026-07-15）

> 费用：0 元

```bash
# terraform.tfvars: 全部 false
terraform apply
```

创建内容：
- VPC: vpc-bp1yjb43u1ht8jdoqdw31 (192.168.0.0/16)
- VSwitch: vsw-bp13ew0svbez0hez2gvhi (192.168.1.0/24, cn-hangzhou-h)
- 安全组: sg-bp1807co8efnr2upllnb + 8 条规则
- SSH 密钥对: k3s-cluster-key

### Phase B: node-01 + EIP（2026-07-15）

> 费用：+~45 元/月 (ECS) + 按量 EIP

```bash
# terraform.tfvars: create_node_01 = true, create_eip = true
terraform apply
```

创建内容：
- ECS: i-bp18iw6uhnyntovdgn02, 内网 192.168.1.228
- EIP: 116.62.168.245 (PayByTraffic, 10Mbps 带宽上限)

**踩坑**：cloud-init 首次执行失败 — `dnf install iproute2` 包名错误。修复 `user-data.sh` 中 `iproute2` → `iproute`，后续节点不受影响。

### Phase D+E: node-02 + node-03（2026-07-15）

> 费用：+~90 元/月 (2 台 ECS)

```bash
# terraform.tfvars: create_node_02 = true, create_node_03 = true
terraform apply
```

创建内容：
- node-02: i-bp13rih84qlww3p8gqag, 192.168.1.230
- node-03: i-bp1fszqhjmzkyi7jt9f5, 192.168.1.229

cloud-init 自动完成（iproute 修复已生效），无需手动干预。

### Phase 1 完成

3 节点全部 cloud-init 通过，可 SSH 直连 node-01 (EIP) 或通过 node-01 跳转到 node-02/03。

### 后续：node-02/03 升级 2C4G（2026-07-21）

> 费用：+~40-60 元/月 (规格升级差价)

Phase 3 前为 MySQL 物理机主从预留内存余量，将 node-02/03 从 2C2G 升级到 2C4G：

```bash
# variables.tf 新增 instance_type_upgraded
# main.tf node-02/03 改用 var.instance_type_upgraded
# 分步 apply，保持 etcd quorum：
terraform apply -target=alicloud_instance.k3s_node_03  # 先升 node-03
terraform apply -target=alicloud_instance.k3s_node_02  # 再升 node-02
```

每台停机 < 30 秒，etcd 2/3 quorum 全程未断，K3s 自动重连恢复 Ready。

---

## 5. 验证清单

Phase 1 完成后逐项验证（全部通过）：

- [x] `terraform output` 显示 3 个内网 IP + 1 个 EIP
- [x] `ssh k3s-node-01` 直连成功（通过 EIP）
- [x] `ssh k3s-node-01` → `ssh 192.168.1.230` 跳转 node-02 成功
- [x] `hostname` 返回 k3s-node-01 / 02 / 03
- [x] `free -h` 中 Swap 全为 0
- [x] `sysctl net.ipv4.ip_forward` 返回 1
- [x] `timedatectl` 时区为 Asia/Shanghai
- [x] `chronyc tracking` 时间同步正常
- [x] `cat /etc/sudoers.d/ops` 包含 NOPASSWD
- [x] `ls /tmp/cloud-init-k3s-done` 文件存在
- [x] 安全组规则在阿里云控制台可查
- [x] `terraform plan` 无 pending changes（state 与配置一致）

---

## 6. 成本估算

| 项目 | 月费 | 说明 |
|------|------|------|
| ECS ecs.e-c1m1.large × 1 (node-01) | ~45 元 | 2C2G |
| ECS ecs.e-c1m2.large × 2 (node-02/03) | ~110 元 | 2C4G，升级后 |
| ESSD Entry 40G × 3 | 含在实例费中 | — |
| EIP (PayByTraffic) | < 1 元 | 0.8 元/GB，仅安装阶段有流量 |
| VPC / VSwitch / 安全组 / 密钥对 | 免费 | — |
| **合计** | **~156 元/月** | — |

> 项目完成后可随时 `terraform destroy` 释放所有资源，停止计费。

---

## 7. SSH 连接方式

### 7.1 本机 SSH 配置

```
# ~/.ssh/config
Host k3s-node-01
    HostName 116.62.168.245
    User ops
    IdentityFile ~/.ssh/id_rsa

Host k3s-node-02
    HostName 192.168.1.230
    User ops
    IdentityFile ~/.ssh/id_rsa
    ProxyJump k3s-node-01

Host k3s-node-03
    HostName 192.168.1.229
    User ops
    IdentityFile ~/.ssh/id_rsa
    ProxyJump k3s-node-01
```

### 7.2 连接命令

```bash
ssh k3s-node-01    # 直连 EIP
ssh k3s-node-02    # 通过 node-01 跳转
ssh k3s-node-03    # 通过 node-01 跳转
```

---

## 8. 踩坑记录

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| cloud-init 执行失败 | `iproute2` 是 Debian 系包名，RHEL 系叫 `iproute` | user-data.sh 改 `iproute2` → `iproute` |
| SWAS VPC 不可复用 | SWAS 与 ECS API 隔离，VPC 不互通 | 新建独立 VPC (192.168.0.0/16) |
| 镜像 name_regex 不匹配 | `alibaba_cloud_linux_3.*` 不是阿里云镜像命名格式 | 改为 `^aliyun_3_x64_20G_alibase_` |
| `key_name` 已废弃 | alicloud provider 更新，`key_name` deprecated | 改用 `key_pair_name` |
| node-02/03 内存不足 | 2C2G 跑 MySQL 主从余量 <200MB，OOM 风险 | 升级到 2C4G (ecs.e-c1m2.large) |

---

## 9. 版本信息

| 工具 | 版本 |
|------|------|
| Terraform | 1.15.8 (winget) |
| alicloud provider | 1.285.0 |
| 阿里云 CLI | 未使用（纯 Terraform） |
| 操作系统 | Alibaba Cloud Linux 3.2104 LTS |
| K3s | v1.36.2+k3s1（Phase 2 部署） |

---

## 10. 下一步

Phase 1 完成后，进入 **Phase 2: K3s 3-Server HA 集群部署** — 通过 Ansible Playbook 在 3 节点上部署 K3s embedded etcd HA 集群。详见 [phase-2-k3s-deploy.md](phase-2-k3s-deploy.md)。
