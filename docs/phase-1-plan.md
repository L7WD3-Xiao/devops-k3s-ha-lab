# Phase 1: Terraform IaC — 阿里云 ECS 实例创建

> 日期：2026-07-20
> 状态：计划待实施
> 前置文档：[aliyun-ecs-k3s-plan.md](aliyun-ecs-k3s-plan.md)（方案调研）

---

## 1. 概述

### 1.1 目标

使用 **Terraform** 在阿里云杭州地域创建 3 台 ECS 实例，组成 K3s HA 集群的物理基础设施。复用现有 VPC / vSwitch，通过 cloud-init 完成系统初始化，替代已废弃的 WSL2 方案。

### 1.2 产出物

| 产出 | 路径 | 说明 |
|------|------|------|
| Terraform 项目 | `terraform/` | main.tf / variables.tf / outputs.tf / user-data.sh |
| 3 台 ECS 实例 | 阿里云控制台 | ecs.e-c1m1.large × 3，Alibaba Cloud Linux 3 |
| 安全组 | 阿里云控制台 | K3s 集群安全组（见 §2.4） |
| Ansible Playbook 适配 | `ansible/` | inventory / group_vars / 00-init-system.yml 适配 |
| 本计划文档 | `docs/phase-1-plan.md` | 你正在看的这个 |

---

## 2. 基础设施规划

### 2.1 节点规划

| 节点 | 实例类型 | vCPU | 内存 | 系统盘 | 内网 IP（Terraform 分配） | K3s 角色 |
|------|---------|------|------|--------|--------------------------|---------|
| k3s-node-1 | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB ESSD Entry | 172.26.5.x | server + etcd |
| k3s-node-2 | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB ESSD Entry | 172.26.5.y | server + etcd |
| k3s-node-3 | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB ESSD Entry | 172.26.5.z | server + etcd |
| **现有 ECS** | ecs.e-c1m1.large | 2 | 2 GiB | 40 GB | 172.26.5.95 | Ansible 控制节点 + Jump Host |

> 新实例不分配公网 IP，通过现有 ECS（47.114.124.150）做 Jump Host SSH 访问。
> 内网 IP 由 VPC DHCP 分配，Terraform 创建后通过 `outputs` 输出。

### 2.2 网络拓扑

```
                        ┌─────────────────────────────────────────────────┐
                        │              阿里云 VPC (172.16.0.0/12)           │
                        │              cn-hangzhou / cn-hangzhou-i         │
                        │                                                 │
   Internet             │   ┌──────────────────────────────────────┐      │
      │                 │   │   vSwitch: vsw-bp171csb7bkm1n0156f3b │      │
      │                 │   │                                      │      │
      ▼                 │   │  ┌─────────────┐  ┌─────────────┐    │      │
  ┌────────┐            │   │  │  k3s-node-1 │  │  k3s-node-2 │    │      │
  │公网 IP │──── SSH ───┼──▶│  │ 172.26.5.x  │  │ 172.26.5.y  │    │      │
  │47.114  │  (Jump)    │   │  │ K3s Server  │  │ K3s Server  │    │      │
  │.124.150│            │   │  │ + etcd      │  │ + etcd      │    │      │
  └────────┘            │   │  └──────┬──────┘  └──────┬──────┘    │      │
       │                │   │         │    VPC 内网     │            │      │
  ┌────────┐            │   │         └───────┬────────┘            │      │
  │现有ECS  │            │   │         ┌───────┴──────┐              │      │
  │astrbot │            │   │         │  k3s-node-3  │              │      │
  │napcat  │            │   │         │ 172.26.5.z   │              │      │
  └────────┘            │   │         │ K3s Server   │              │      │
                        │   │         │ + etcd       │              │      │
                        │   │         └──────────────┘              │      │
                        │   └──────────────────────────────────────┘      │
                        └─────────────────────────────────────────────────┘
```

### 2.3 现有资源（复用，Terraform data 引用）

| 资源 | ID | 获取方式 |
|------|----|---------|
| VPC | vpc-bp1oq6uale5r4id9beupn | `data "alicloud_vpcs" "existing"` |
| vSwitch | vsw-bp171csb7bkm1n0156f3b | `data "alicloud_vswitchs" "existing"` |
| 现有 ECS | 172.26.5.95 | 已有，不需创建 |

### 2.4 安全组规则

| 方向 | 协议 | 端口 | 源/目标 | 用途 |
|------|------|------|---------|------|
| 入 | TCP | 22 | 172.26.5.95/32（现有 ECS） | SSH 管理（仅 Jump Host） |
| 入 | TCP | 6443 | 0.0.0.0/0 | K3s API Server |
| 入 | TCP | 2379-2380 | 同安全组内 | etcd 集群通信 |
| 入 | TCP | 10250 | 同安全组内 | kubelet |
| 入 | UDP | 8472 | 同安全组内 | flannel VXLAN |
| 入 | TCP | 80, 443 | 0.0.0.0/0 | 业务 Ingress |
| 出 | ALL | ALL | 0.0.0.0/0 | 默认允许 |

> ⚠️ etcd 端口（2379/2380）务必限制为同安全组内，**不要对公网开放**。

### 2.5 操作系统

| 镜像 | 说明 |
|------|------|
| Alibaba Cloud Linux 3.2104 | 与现有服务器一致，RHEL 8 兼容，内核 5.10，免费使用阿里云内网 yum 源 |

> K3s 官方支持 RHEL 8+，Alibaba Cloud Linux 3 基于 platform:al8，兼容性良好。

---

## 3. Terraform 项目设计

### 3.1 目录结构

```
terraform/
├── main.tf           # 主配置：provider + data + 资源定义
├── variables.tf      # 输入变量
├── outputs.tf        # 输出（ECS 内网 IP、实例 ID 等）
├── user-data.sh      # cloud-init 初始化脚本
├── terraform.tfvars  # 变量赋值（不含敏感信息）
└── README.md         # 使用说明
```

### 3.2 `variables.tf` — 输入变量

```hcl
# ── 阿里云 Provider 配置 ──
variable "alicloud_region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hangzhou"
}

# ── 复用现有网络 ──
variable "vpc_id" {
  description = "现有 VPC ID"
  type        = string
  default     = "vpc-bp1oq6uale5r4id9beupn"
}

variable "vswitch_id" {
  description = "现有 vSwitch ID"
  type        = string
  default     = "vsw-bp171csb7bkm1n0156f3b"
}

# ── ECS 实例配置 ──
variable "instance_type" {
  description = "ECS 实例规格"
  type        = string
  default     = "ecs.e-c1m1.large"
}

variable "image_id" {
  description = "镜像 ID（Alibaba Cloud Linux 3）"
  type        = string
  default     = ""  # 留空则通过 data 自动查询最新
}

variable "system_disk_size" {
  description = "系统盘大小（GB）"
  type        = number
  default     = 40
}

variable "system_disk_category" {
  description = "系统盘类型"
  type        = string
  default     = "cloud_essd_entry"
}

# ── 节点配置 ──
variable "node_count" {
  description = "K3s 节点数量"
  type        = number
  default     = 3
}

variable "node_name_prefix" {
  description = "节点名前缀"
  type        = string
  default     = "k3s-node"
}

# ── SSH 密钥 ──
variable "ssh_key_name" {
  description = "SSH 密钥对名称（需在阿里云控制台预先创建）"
  type        = string
  default     = "k3s-cluster-key"
}

# ── Jump Host ──
variable "jump_host_ip" {
  description = "Jump Host 内网 IP（现有 ECS，用于安全组 SSH 限制）"
  type        = string
  default     = "172.26.5.95"
}

# ── Ops 用户 ──
variable "ops_user" {
  description = "运维用户名"
  type        = string
  default     = "ops"
}

variable "ops_pubkey" {
  description = "Ops 用户的 SSH 公钥（用于 cloud-init 注入）"
  type        = string
  default     = ""  # 在 terraform.tfvars 中设置
}
```

### 3.3 `main.tf` — 主配置

```hcl
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.220"
    }
  }
}

provider "alicloud" {
  region = var.alicloud_region
}

# ── 引用现有 VPC ──
data "alicloud_vpcs" "existing" {
  ids = [var.vpc_id]
}

# ── 引用现有 vSwitch ──
data "alicloud_vswitchs" "existing" {
  ids = [var.vswitch_id]
}

# ── 查询最新 Alibaba Cloud Linux 3 镜像（如未指定 image_id）──
data "alicloud_images" "acl3" {
  count       = var.image_id == "" ? 1 : 0
  name_regex  = "^alibaba_cloud_linux_3.*2104.*x64"
  most_recent = true
  owners      = "system"
}

locals {
  image_id    = var.image_id != "" ? var.image_id : data.alicloud_images.acl3[0].images[0].id
  vpc_cidr    = data.alicloud_vpcs.existing.vpcs[0].cidr_block
}

# ── 安全组 ──
resource "alicloud_security_group" "k3s" {
  name        = "k3s-cluster-sg"
  description = "Security group for K3s HA cluster"
  vpc_id      = var.vpc_id
}

# SSH: 仅允许 Jump Host
resource "alicloud_security_group_rule" "ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "22/22"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = "${var.jump_host_ip}/32"
}

# K3s API Server: 公网可访问（可收紧为 VPC CIDR）
resource "alicloud_security_group_rule" "k3s_api" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "6443/6443"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = "0.0.0.0/0"
}

# etcd: 仅安全组内部
resource "alicloud_security_group_rule" "etcd_client" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "2379/2379"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = local.vpc_cidr
}

resource "alicloud_security_group_rule" "etcd_peer" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "2380/2380"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = local.vpc_cidr
}

# kubelet: 仅安全组内部
resource "alicloud_security_group_rule" "kubelet" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "10250/10250"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = local.vpc_cidr
}

# flannel VXLAN: 仅安全组内部
resource "alicloud_security_group_rule" "flannel" {
  type              = "ingress"
  ip_protocol       = "udp"
  port_range        = "8472/8472"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = local.vpc_cidr
}

# Ingress HTTP/HTTPS: 公网可访问
resource "alicloud_security_group_rule" "http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "80/80"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = "0.0.0.0/0"
}

resource "alicloud_security_group_rule" "https" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "443/443"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = "0.0.0.0/0"
}

# ── ECS 实例 ──
resource "alicloud_instance" "k3s_nodes" {
  count                     = var.node_count
  instance_name             = "${var.node_name_prefix}-${count.index + 1}"
  host_name                 = "${var.node_name_prefix}-${count.index + 1}"
  instance_type             = var.instance_type
  image_id                  = local.image_id
  security_groups           = [alicloud_security_group.k3s.id]
  vswitch_id                = var.vswitch_id
  system_disk_size          = var.system_disk_size
  system_disk_category      = var.system_disk_category
  internet_max_bandwidth_out = 0  # 不分配公网 IP
  key_name                  = var.ssh_key_name  # 阿里云密钥对（root 用户）

  # cloud-init user-data
  user_data = templatefile("${path.module}/user-data.sh", {
    ops_user   = var.ops_user
    ops_pubkey = var.ops_pubkey
  })

  tags = {
    Project    = "k3s-cluster"
    Phase      = "phase-1"
    NodeRole   = "server-etcd"
    NodeIndex  = tostring(count.index + 1)
  }
}
```

### 3.4 `outputs.tf` — 输出

```hcl
output "k3s_node_private_ips" {
  description = "K3s 节点内网 IP（用于 Ansible inventory）"
  value = {
    for i, instance in alicloud_instance.k3s_nodes :
    "k3s-node-${i + 1}" => instance.private_ip
  }
}

output "k3s_node_instance_ids" {
  description = "ECS 实例 ID"
  value = {
    for i, instance in alicloud_instance.k3s_nodes :
    "k3s-node-${i + 1}" => instance.id
  }
}

output "security_group_id" {
  description = "安全组 ID"
  value       = alicloud_security_group.k3s.id
}

output "jump_host_ssh_command" {
  description = "通过 Jump Host 连接节点的示例命令"
  value = [
    for i, instance in alicloud_instance.k3s_nodes :
    "ssh -J ops@47.114.124.150 ops@${instance.private_ip}"
  ]
}
```

### 3.5 `user-data.sh` — cloud-init 初始化脚本

```bash
#!/bin/bash
# cloud-init user-data for K3s cluster nodes
# Runs as root on first boot

set -euo pipefail

OPS_USER="${ops_user}"
OPS_PUBKEY="${ops_pubkey}"

# ── 1. 关闭 swap ──
swapoff -a
sed -i '/swap/d' /etc/fstab

# ── 2. 内核参数 ──
cat > /etc/sysctl.d/99-k3s.conf << 'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
modprobe br_netfilter 2>/dev/null || true
sysctl --system

# ── 3. 安装基础软件包（dnf, RHEL 系）──
dnf install -y curl wget vim git net-tools iproute2 chrony python3 python3-pip \
    gnupg ca-certificates tar gzip

# ── 4. 时区 & 时间同步 ──
timedatectl set-timezone Asia/Shanghai
systemctl enable --now chronyd

# ── 5. 创建 ops 用户 ──
useradd -m -s /bin/bash -G wheel "${OPS_USER}"
echo "${OPS_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${OPS_USER}"
chmod 0440 "/etc/sudoers.d/${OPS_USER}"

# ── 6. 配置 ops SSH 公钥 ──
mkdir -p "/home/${OPS_USER}/.ssh"
echo "${OPS_PUBKEY}" > "/home/${OPS_USER}/.ssh/authorized_keys"
chmod 700 "/home/${OPS_USER}/.ssh"
chmod 600 "/home/${OPS_USER}/.ssh/authorized_keys"
chown -R "${OPS_USER}:${OPS_USER}" "/home/${OPS_USER}/.ssh"

# ── 7. 配置 /etc/hosts（节点间解析）──
# 注：内网 IP 在 cloud-init 运行时可能还未完全分配
# Ansible Playbook 00 会补充完整的 /etc/hosts
echo "# K3s cluster hosts (managed by Ansible)" >> /etc/hosts

# ── 8. 禁用 firewalld（K3s 自行管理网络规则）──
systemctl disable --now firewalld 2>/dev/null || true

# ── 9. 标记 cloud-init 完成 ──
touch /tmp/cloud-init-k3s-done
```

### 3.6 `terraform.tfvars` — 变量赋值

```hcl
# 在此处填入你的 SSH 公钥（用于 ops 用户免密登录）
ops_pubkey = "ssh-ed25519 AAAAC3Nz... your_email@example.com"
```

> ⚠️ 不要将 `terraform.tfvars` 提交到 Git。在 `.gitignore` 中排除。

---

## 4. 实施步骤

### Step 0: 前置准备

```bash
# 1. 安装 Terraform（本地 Windows 或现有 ECS）
#    下载地址: https://developer.hashicorp.com/terraform/downloads

# 2. 配置阿里云凭证（环境变量）
export ALICLOUD_ACCESS_KEY="your-access-key"
export ALICLOUD_SECRET_KEY="your-secret-key"

# 3. 在阿里云控制台创建 SSH 密钥对 "k3s-cluster-key"（用于 root 用户）
#    ECS 控制台 → 密钥对 → 创建密钥对 → 下载 .pem 文件

# 4. 在 terraform.tfvars 中填入 ops 用户的 SSH 公钥
```

### Step 1: Terraform 初始化 & 预览

```bash
cd terraform/

# 初始化 Provider
terraform init

# 预览将创建的资源
terraform plan
```

### Step 2: 创建基础设施

```bash
# 执行创建（约 2-3 分钟）
terraform apply -auto-approve

# 记录输出的内网 IP（后续 Ansible inventory 需要）
terraform output -json k3s_node_private_ips
```

预期输出示例：
```json
{
  "k3s-node-1": "172.26.5.101",
  "k3s-node-2": "172.26.5.102",
  "k3s-node-3": "172.26.5.103"
}
```

### Step 3: 验证 cloud-init 完成

```bash
# 通过 Jump Host SSH 到新实例
ssh -J ops@47.114.124.150 ops@172.26.5.101

# 验证初始化
hostname                    # k3s-node-1
free -h                     # Swap 全为 0
sysctl net.ipv4.ip_forward  # 返回 1
timedatectl                 # Asia/Shanghai
which dnf                   # /usr/bin/dnf
ls /tmp/cloud-init-k3s-done # 文件存在
```

### Step 4: 配置 Ansible Inventory

根据 `terraform output` 的实际 IP，更新 `ansible/inventory.ini`：

```ini
[k3s_servers]
k3s-node-1 ansible_host=172.26.5.101
k3s-node-2 ansible_host=172.26.5.102
k3s-node-3 ansible_host=172.26.5.103

[k3s_cluster:children]
k3s_servers

[k3s_cluster:vars]
ansible_user=ops
ansible_ssh_private_key_file=~/.ssh/id_ed25519
ansible_python_interpreter=/usr/bin/python3
```

### Step 5: 运行 Ansible 系统初始化

```bash
# 在现有 ECS（Jump Host）上运行
cd /home/ops/k8s-project/ansible
ansible-playbook -i inventory.ini playbooks/00-init-system.yml
```

### Step 6: 验证

```bash
# Ansible 连通性
ansible all -i inventory.ini -m ping

# 节点状态
ansible all -i inventory.ini -m command -a "hostname"
ansible all -i inventory.ini -m command -a "free -h"
ansible all -i inventory.ini -m command -a "sysctl net.ipv4.ip_forward"
ansible all -i inventory.ini -m command -a "timedatectl"
```

---

## 5. Ansible Playbook 适配清单

现有 Playbook 写于 WSL2 + Ubuntu 环境，迁移到 ECS + Alibaba Cloud Linux 3 需以下改动：

### 5.1 `group_vars/all.yml`

| 修改项 | 旧值（WSL2） | 新值（ECS） |
|--------|-------------|-------------|
| `node_ips` | 192.168.50.11/12/13 | 172.26.5.101/102/103（Terraform 输出） |
| `cluster_hosts` | WSL2 IP 列表 | ECS 内网 IP 列表 |
| `base_packages` | `apt` 包名（含 `openssh-server`、`python3-passlib`） | `dnf` 包名（移除 `openssh-server`、`software-properties-common`，加 `python3-passlib` → `python3-libselinux`） |
| `k3s_flannel_iface` | `eth0` | `eth0`（ECS 默认，保留） |

### 5.2 `inventory.ini`

| 修改项 | 旧值 | 新值 |
|--------|------|------|
| 节点名 | `node-01/02/03` | `k3s-node-1/2/3` |
| `ansible_host` | 192.168.50.1X | 172.26.5.10X（Terraform 输出） |
| 节点分组 | `k3s_cluster`（混合） | `k3s_servers`（3 server，无 agent） |

### 5.3 `00-init-system.yml`

| 原 (Ubuntu/apt) | 改为 (Alibaba Cloud Linux 3/dnf) | 说明 |
|-----------------|----------------------------------|------|
| `apt: update_cache=true` | `dnf: update_cache=true` | 包管理器 |
| `apt: upgrade=dist` | `dnf: name=* state=latest` | 系统升级 |
| `apt: name={{ base_packages }}` | `dnf: name={{ base_packages }}` | 安装软件包 |
| `service: name=ssh` | `service: name=sshd` | SSH 服务名 |
| `groups: sudo` | `groups: wheel` | sudo 组名 |
| WSL2 IP alias service | **删除** | ECS 有独立 IP，不需要 |
| `Configure sshd ListenAddress` | **删除** | ECS 不需要绑定特定 IP |
| `Verify IP alias` post_task | **删除** | 不再需要 |

> **跨平台建议**：可用 `ansible_os_family` 变量做条件判断，同时支持 Ubuntu（Debian）和 Alibaba Cloud Linux（RedHat），体现 Playbook 的跨平台能力（简历加分）。

### 5.4 `k3s-config.yaml.j2`

```yaml
# HA 模式配置（3 server + embedded etcd）
node-ip: {{ node_ips[inventory_hostname] }}
node-name: {{ inventory_hostname }}
flannel-iface: eth0

write-kubeconfig-mode: "0644"
tls-san:
  - {{ node_ips[inventory_hostname] }}

# etcd HA: 首节点初始化集群，其余节点 join
cluster-init: {% if inventory_hostname == k3s_first_server %}true{% else %}false{% endif %}
server: https://{{ k3s_first_server_ip }}:{{ k3s_api_port }}
```

> 不再需要 `disable-apiserver-lb`——ECS 有独立 loopback，无端口冲突。

### 5.5 `01-deploy-k3s.yml`

| 改动项 | 说明 |
|--------|------|
| HA 模式安装 | server 节点添加 `--cluster-init`（首节点）和 `--server`（join 节点） |
| 删除 `disable-apiserver-lb` | 不再需要 |
| 删除二进制复制逻辑 | ECS 有公网/NAT，可直接下载 |
| 删除 WSL2 前置检查 | IP 别名检查等不再需要 |
| 新增 etcd 健康检查 | `k3s etcd-snapshot` 验证 |

---

## 6. 成本估算

| 项目 | 月费 | 说明 |
|------|------|------|
| ECS ecs.e-c1m1.large × 3 | ~135 元 | 经济型 e 实例，包月 |
| ESSD Entry 40G × 3 | 含在实例费中 | — |
| 安全组 | 免费 | — |
| 公网带宽（现有服务器） | 已有 | 复用现有 |
| NAT 网关（可选） | ~25 元 | 如需新实例自行下载包 |
| **最小方案** | **~135 元/月** | 3 ECS only |
| **完整方案** | **~160 元/月** | + NAT 网关 |

> 项目完成后可随时 `terraform destroy` 释放所有资源，停止计费。

---

## 7. 验证清单

Terraform apply 完成后，逐项验证：

- [ ] `terraform output` 显示 3 个内网 IP
- [ ] 通过 Jump Host SSH 免密登录 3 台新实例
- [ ] `hostname` 返回 k3s-node-1 / k3s-node-2 / k3s-node-3
- [ ] `free -h` 中 Swap 全为 0
- [ ] `sysctl net.ipv4.ip_forward` 返回 1
- [ ] `timedatectl` 时区为 Asia/Shanghai
- [ ] `chronyc tracking` 时间同步正常
- [ ] `cat /etc/sudoers.d/ops` 包含 NOPASSWD
- [ ] `ansible all -m ping` 三节点全部 SUCCESS
- [ ] 安全组规则在阿里云控制台可查
- [ ] `terraform show` 显示所有资源状态正常

---

## 8. 风险与注意事项

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| 经济型 e 实例 CPU 性能基线 | 突发负载时降频 | 部署阶段可临时升级规格，完成后降回 |
| Alibaba Cloud Linux 3 兼容性 | K3s 某些特性可能差异 | K3s 官方支持 RHEL 8+，兼容性良好 |
| Terraform state 文件安全 | 含资源 ID，误删风险 | 使用 `terraform backend` 远程存储（OSS） |
| SSH 密钥丢失 | 无法登录实例 | 阿里云密钥对 + cloud-init 公钥双重保障 |
| cloud-init 执行失败 | 节点未初始化 | 检查 `/var/log/cloud-init-output.log` |

---

## 9. 下一步

Phase 1 完成后，进入 **Phase 2: K3s HA 集群部署**——在现有 ECS（Jump Host）上通过 Ansible Playbook 在 3 节点上部署 K3s 3-Server HA + embedded etcd 集群。
