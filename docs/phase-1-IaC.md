# Phase 1: Terraform IaC — 阿里云 ECS 基础设施创建

> 日期：2026-07-15 ~ 2026-07-21
> 状态：**已完成**

---

## 1. 概述

### 1.1 目标

使用 **Terraform** 在阿里云杭州地域创建全新的 VPC + 3 台 ECS 实例，组成 K3s HA 集群的物理基础设施。通过 cloud-init 完成系统初始化，node-01 绑定按量 EIP 提供互联网出口和 SSH 直连。

### 1.2 方案变更说明

| 项目 | 原方案（已废弃） | 实际方案 |
|------|----------------|---------|
| VPC | 复用 SWAS VPC (172.16.0.0/12) | **新建 VPC (192.168.0.0/16)** |
| vSwitch | 复用 vsw-bp171csb7bkm1n0156f3b (cn-hangzhou-i) | **新建 vswitch (192.168.1.0/24, cn-hangzhou-h)** |
| node-01 | 复用现有 SWAS 实例 (import) | **新建 ECS** |
| 公网访问 | SWAS 做 Jump Host (47.114.124.150) | **node-01 绑按量 EIP (<集群公网入口IP>)** |
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
| EIP | <集群公网入口IP> | 绑定 node-01, PayByTraffic |

---

## 2. 基础设施现状

### 2.1 节点规划

| 节点 | 实例类型 | vCPU | 内存 | 系统盘 | 内网 IP | EIP | K3s 角色 |
|------|---------|------|------|--------|---------|-----|---------|
| k3s-node-01 | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB ESSD Entry | 192.168.1.228 | <集群公网入口IP> | server + etcd |
| k3s-node-02 | ecs.e-c1m2.large | 2 | 4 GiB | 40 GB ESSD Entry | 192.168.1.230 | — | server + etcd |
| k3s-node-03 | ecs.e-c1m2.large | 2 | 4 GiB | 40 GB ESSD Entry | 192.168.1.229 | — | server + etcd |

> node-01 保持 2C4G（仅跑 K3s 控制面 + FluxCD + Velero，不跑 MySQL）。
> node-02/03 在 Phase 3 前升级到 2C4G（跑 MySQL 物理机主从，2C4G 内存余量 <200MB 有 OOM 风险）。

### 2.2 网络拓扑

```
                        ┌─────────────────────────────────────────────────┐
                        │         阿里云 VPC (192.168.0.0/16)              │
                        │         cn-hangzhou / cn-hangzhou-h             │
                        │                                                 │
   Internet             │   ┌──────────────────────────────────────┐      │
      │                 │   │  VSwitch: 192.168.1.0/24             │      │
      ▼                 │   │                                      │      │
  ┌────────┐            │   │  ┌─────────────┐  ┌──────────────┐   │      │
  │  EIP   │──── SSH ───┼──▶│  │  k3s-node-01│  │ k3s-node-02  │  │      │
  │ 公网IP │  直连 22     │   │  │ 192.168.1.228│  │192.168.1.230│  │      │
  └────────┘            │   │  │ + etcd      │  │ + etcd       │  │      │
       │ 互联网出口       │   │  │ 2C4G 40G    │  │ 2C4G 40G     │  │      │
       ▼                │   │  └──────┬──────┘  └──────┬───────┘  │      │
  (K3s/镜像下载)         │   │         │   VPC 内网      │          │      │
                        │   │         └───────┬────────┘          │      │
                        │   │         ┌───────┴──────┐            │      │
                        │   │         │  k3s-node-03 │            │      │
                        │   │         │192.168.1.229 │            │      │
                        │   │         │ K3s Server   │            │      │
                        │   │         │ + etcd       │            │      │
                        │   │         │ 2C4G 40G     │            │      │
                        │   │         └──────────────┘            │      │
                        │   └─────────────────────────────────────┘      │
                        └────────────────────────────────────────────────┘
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

#### 3.2.2 VPC 新建

新建独立 VPC (192.168.0.0/16)，所有资源 Terraform 原生管理。

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
variable "instance_type"          { default = "ecs.e-c1m1.large" }  # 2C4G, node-01
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
├── alicloud_instance.k3s_node_01   ── ECS node-01 (2C4G, count=create_node_01)
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
# 1. 关闭 swap (k8s明确要求)
# 2. 内核参数 (ip_forward, bridge-nf-call-iptables)
# 3. 安装基础包 (dnf)
# 4. 时区 Asia/Shanghai + chronyd
# 5. 创建 ops 用户 + sudo NOPASSWD
# 6. 配置 ops SSH 公钥
# 7. 禁用 firewalld
# 8. 标记完成 /tmp/cloud-init-k3s-done
```

> **踩坑修复**：Alibaba Cloud Linux 3 (RHEL 8 系) 包名 `iproute` 而非 `iproute2`（Debian 系）。cloud-init 首次执行时 `dnf install iproute2` 失败，改为 `iproute` 后通过。
>
> 关闭 swap 出于集群性能考虑：[k8s优化之关闭swap - Leo_Yide - 博客园](https://www.cnblogs.com/leojazz/p/18932239)

---

## 4. 实施计划（5 步）

> 执行顺序严格按依赖关系排列：必须先创建网络基础设施，后创建 ECS 实例。规格升级可选，按需在 Phase 3 前执行。

```
Step 1: Terraform 项目 ────► 编写 main.tf / variables.tf / outputs.tf / user-data.sh
    │
    ▼
Step 2: 网络基础设施 ──────► VPC + VSwitch + 安全组 + SSH 密钥对（0 元）
    │
    ▼
Step 3: node-01 ──────────► ECS + EIP（cloud-init 初始化）
    │
    ▼
Step 4: node-02/03 ───────► 两台 ECS 纯内网节点
    │
    ▼
Step 5: 规格升级 ──────────► node-02/03 2C4G → 2C4G（可选，按需执行）
```

---

### Step 1: 准备工作

**安装 Terraform（本机）：**

```bash
winget install --id HashiCorp.Terraform --accept-source-agreements --accept-package-agreements 2>&1 | tail -20
```

**创建阿里云 AccessKey ：**

1. 登录 [阿里云控制台](https://home.console.aliyun.com/)
2. 鼠标悬停右上角头像 → 点击 **AccessKey 管理**
3. 系统会提示"建议使用 RAM 子用户 AccessKey"，点击 **开始使用子用户 AccessKey**
4. 点击 **创建用户**，用户名填 `terraform`（或任意），勾选 **OpenAPI 调用访问**
5. 创建后**立即复制 AccessKey ID 和 AccessKey Secret**（只显示一次）
6. 给该用户授权：搜索并添加 `AliyunECSFullAccess` 策略（管理 ECS 的权限）

> ⚠️ 不要使用主账号 AccessKey，安全风险太大。RAM 子用户只需 ECS 管理权限即可。
>
> AccessKey ID 和 AccessKey Secret 用在下面 setenv.sh

### Step 2: Terraform 项目文件

**目标**：编写全部 Terraform 配置文件（main.tf / variables.tf / outputs.tf）和 cloud-init 脚本（user-data.sh），为基础设施创建做准备。

**新建文件**：

| 文件 | 说明 |
|------|------|
| `terraform/main.tf` | 主配置：provider + VPC + 安全组 + 3 实例 + EIP |
| `terraform/variables.tf` | 输入变量（含分步创建控制 + 升级规格变量） |
| `terraform/outputs.tf` | 输出（IP、实例 ID、Ansible inventory 片段） |
| `terraform/user-data.sh` | cloud-init 初始化脚本（templatefile 渲染） |
| `terraform/terraform.tfvars` | 变量赋值（含 ops 公钥，`.gitignore` 排除） |
| `terraform/setenv.sh` | 阿里云凭证环境变量加载脚本（`.gitignore` 排除） |

**关键设计**：

| 设计点 | 决策 | 原因 |
|--------|------|------|
| 分步创建控制 | 3 个独立 resource + 布尔变量 | 逐台创建控制成本，支持 `-target` 精确操作 |
| VPC 新建 | 独立 VPC 192.168.0.0/16 | 不与 SWAS 共享，Terraform 原生管理 |
| EIP 按量 | `PayByTraffic` | 安装阶段一次性 ~3 元，后续 < 1 元/月 |
| 密钥对 | `alicloud_ecs_key_pair` 资源自动创建 | 无需控制台手动操作 |

**验证**：
```bash
terraform init             # Provider 下载成功
terraform fmt -check       # 格式合规
terraform validate         # 配置语法正确
```

---

### Step 3: 网络基础设施

**目标**：创建 VPC + VSwitch + 安全组 + SSH 密钥对。此步骤不产生 ECS 实例费用（0 元）。

```bash
# terraform.tfvars: 全部 create_* = false
terraform apply
```

**创建资源**：

| 资源 | ID | 配置 |
|------|----|------|
| VPC | vpc-bp1yjb43u1ht8jdoqdw31 | 192.168.0.0/16, cn-hangzhou |
| VSwitch | vsw-bp13ew0svbez0hez2gvhi | 192.168.1.0/24, cn-hangzhou-h |
| 安全组 | sg-bp1807co8efnr2upllnb | 8 条规则（SSH/6443/2379-2380/10250/8472/80,443） |
| SSH 密钥对 | k3s-cluster-key | Terraform 自动创建并导入本机公钥 |

**验证**：
```bash
terraform output            # 此时仅有 vpc_id / vswitch_id / sg_id
terraform state list         # 仅有 VPC/VSwitch/SG/KeyPair
# 阿里云控制台确认安全组 8 条规则已生效
```

---

### Step 4: node-01 + EIP

**目标**：创建首台 ECS 实例（node-01）并绑定按量 EIP，提供 SSH 直连和互联网出口。费用 +~45 元/月。

```bash
# terraform.tfvars: create_node_01 = true, create_eip = true
terraform apply
```

**创建资源**：

| 资源 | ID / 地址 | 规格 |
|------|-----------|------|
| ECS node-01 | i-bp18iw6uhnyntovdgn02 | ecs.e-c1m1.large (2C2G), 40G ESSD Entry |
| 内网 IP | 192.168.1.228 | — |
| EIP | <集群公网入口IP> | PayByTraffic, 10Mbps 带宽上限 |

**修改文件**：

| 文件 | 变更 | 原因 |
|------|------|------|
| `terraform/user-data.sh` | `iproute2` → `iproute` | Alibaba Cloud Linux 3 (RHEL 系) 包名为 `iproute`，非 Debian 系的 `iproute2` |

> **踩坑**：cloud-init 首次执行失败 — `dnf install iproute2` 包名错误。修复 `user-data.sh` 后重新 `terraform apply`，问题解决。后续节点（Step 4）不受影响。

**验证**：
```bash
ssh -i k3s-cluster-key ops@<集群公网入口IP>   # SSH 直连成功
hostname                                        # k3s-node-01
free -h                                         # Swap = 0
cat /tmp/cloud-init-k3s-done                   # cloud-init 标记存在
# cloud-init 完成检查
sudo cat /var/log/cloud-init-output.log        # 无报错
```

---

### Step 5: node-02 + node-03

**目标**：创建 node-02/03 纯内网 ECS 实例，至此 3 节点基础设施全部就绪。费用 +~90 元/月。

```bash
# terraform.tfvars: create_node_02 = true, create_node_03 = true
terraform apply
```

**创建资源**：

| 节点 | ID | 内网 IP | 规格 |
|------|-----|---------|------|
| node-02 | i-bp13rih84qlww3p8gqag | 192.168.1.230 | ecs.e-c1m1.large (2C2G) |
| node-03 | i-bp1fszqhjmzkyi7jt9f5 | 192.168.1.229 | ecs.e-c1m1.large (2C2G) |

> cloud-init 自动完成（Step 3 的 `iproute` 修复已生效），无需手动干预。

**验证**：
```bash
# 通过 node-01 跳转
ssh k3s-node-01
ssh 192.168.1.230            # 跳转 node-02 → hostname: k3s-node-02
ssh 192.168.1.229            # 跳转 node-03 → hostname: k3s-node-03

# cloud-init 检查（逐台）
free -h                      # Swap = 0
sysctl net.ipv4.ip_forward   # 1
chronyc tracking             # 时间同步正常
timedatectl                  # 时区 Asia/Shanghai
cat /etc/sudoers.d/ops       # 包含 NOPASSWD
```

---

## 5. 受影响文件总览

### 新建文件（6 个）

| 文件路径 | 步骤 | 说明 |
|---------|------|------|
| `terraform/main.tf` | Step 2 | 主配置：provider + VPC + 安全组 + 3 实例 + EIP |
| `terraform/variables.tf` | Step 2 | 输入变量（含分步创建控制 + 升级规格变量） |
| `terraform/outputs.tf` | Step 2 | 输出定义 |
| `terraform/user-data.sh` | Step 2, 3 | cloud-init 初始化脚本（Step 3 修复 iproute 包名） |
| `terraform/terraform.tfvars` | Step 2 | 变量赋值（`.gitignore` 排除） |
| `terraform/setenv.sh` | Step 2 | 阿里云凭证环境变量（`.gitignore` 排除） |

### 自动生成文件（3 个）

| 文件路径 | 说明 |
|---------|------|
| `terraform/terraform.tfstate` | Terraform 状态文件（`.gitignore` 排除） |
| `terraform/.terraform.lock.hcl` | Provider 版本锁定 |
| `terraform/.terraform/` | Provider 二进制缓存 |

## 6. 部署顺序与回滚

### 推荐部署顺序

```
1. Step 1: 编写全部 .tf 文件 + user-data.sh
2. terraform init → fmt → validate
3. Step 2: 网络基础设施    → 验证 VPC/VSwitch/SG 创建
4. Step 3: node-01 + EIP  → SSH 直连 + cloud-init 验证
5. Step 4: node-02/03     → 跳转验证
```

### 回滚策略

| 步骤 | 回滚方式 |
|------|---------|
| Step 2（网络） | `terraform destroy -target=alicloud_vpc.k3s`（关联资源自动销毁） |
| Step 3（node-01） | `terraform destroy -target=alicloud_instance.k3s_node_01` |
| Step 4（node-02/03） | `terraform destroy -target=alicloud_instance.k3s_node_02 -target=alicloud_instance.k3s_node_03` |
| 全部销毁 | `terraform destroy`（释放所有资源，停止计费） |

> **销毁注意事项**：EIP 销毁后公网 IP 会释放且不可恢复。如需保留 IP，解除 EIP 绑定但不销毁资源。

## 7. 风险与注意事项

| # | 风险 | 影响 | 缓解措施 |
|---|------|------|---------|
| 1 | cloud-init 包名差异 | node-01 初始化失败，需修复后重新 apply | 先在 node-01 验证，再创建后续节点 |
| 2 | EIP 未释放持续计费 | 即使 destroy 时 EIP 未解绑，可能残留产生费用 | destroy 时检查 `terraform state list` 确认全部清理 |
| 3 | 规格升级中断 etcd quorum | 同时升级 2 台可能导致 etcd 失 quorum | 分步 `-target` 操作，一次只停一台 |
| 4 | 余额不足导致创建中断 | 欠费时 ECS 创建失败，部分资源残留 | 分步创建控制，逐台确认后再继续 |
| 5 | SSH 密钥变更导致失联 | `key_pair_name` 更新后已有实例不生效 | 首次确定后不修改密钥，换用导入公钥到 authorized_keys |
| 6 | Terraform state 文件丢失 | 无法管理已有资源，需手动 import | `terraform.tfstate` 入 `.gitignore`，但需定期备份 |

---

## 8. 验证清单

Phase 1 完成后逐项验证：

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

## 9. 成本估算

| 项目 | 月费 | 说明 |
|------|------|------|
| ECS ecs.e-c1m2.large × 3 | ~300 元 | 2C4G，升级后 |
| ESSD Entry 40G × 3 | 含在实例费中 | — |
| EIP (PayByTraffic) | < 1 元 | 0.8 元/GB，仅安装阶段有流量 |
| VPC / VSwitch / 安全组 / 密钥对 | 免费 | — |
| **合计** | **~300 元/月** | — |

> 项目完成后可随时 `terraform destroy` 释放所有资源，停止计费。

---

## 10. 踩坑记录

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| cloud-init 执行失败 | `iproute2` 是 Debian 系包名，RHEL 系叫 `iproute` | user-data.sh 改 `iproute2` → `iproute` |
| 镜像 name_regex 不匹配 | `alibaba_cloud_linux_3.*` 不是阿里云镜像命名格式 | 改为 `^aliyun_3_x64_20G_alibase_` |
| `key_name` 已废弃 | alicloud provider 更新，`key_name` deprecated | 改用 `key_pair_name` |
| node-02/03 内存不足 | 2C2G 跑 MySQL 主从余量 <200MB，OOM 风险 | 升级到 2C4G (ecs.e-c1m2.large) |

---

## 11. 版本信息

| 工具 | 版本 |
|------|------|
| Terraform | 1.15.8 (winget) |
| alicloud provider | 1.285.0 |
| 阿里云 CLI | 未使用（纯 Terraform） |
| 操作系统 | Alibaba Cloud Linux 3.2104 LTS |
| K3s | v1.36.2+k3s1（Phase 2 部署） |
