# Terraform 配置细化 — 分步创建 + 余额保护

> 最后更改：2026-07-20
> 状态：**方案已更改（2026-07-21）且未同步文档**
> 前置文档：[phase-1-plan.md](phase-1-plan.md)（总体计划）

---

## 0. 核心原则

> **所有涉及用户账号余额变动的操作，必须得到用户明确确认后再执行。**

### 0.1 操作分类

| 类别 | 操作 | 是否产生费用 | 是否需要确认 |
|------|------|-------------|-------------|
| **只读** | `terraform init` | 否 | 否 |
| **只读** | `terraform validate` | 否 | 否 |
| **只读** | `terraform fmt` | 否 | 否 |
| **只读** | `terraform plan` | 否 | 否 |
| **只读** | `terraform import` | 否（导入已有资源到 state） | 否 |
| **只读** | `terraform state list/show` | 否 | 否 |
| **创建资源** | `terraform apply`（含新 ECS） | **是** | **是** |
| **修改资源** | `terraform apply`（改安全组等） | 否（安全组免费） | 否 |
| **释放资源** | `terraform destroy` | 停止计费 | **是**（确认释放范围） |

### 0.2 确认流程

```
    terraform plan  ──→  展示给用户  ──→  用户确认？  ──→  terraform apply
         │                    │                │
        只读               说明费用影响         │
                                            ┌──┴──┐
                                           是     否
                                           │      │
                                        执行    中止
```

**执行前检查清单**（每次 `apply` 前过一遍）：
- [ ] `terraform plan` 输出已展示给用户
- [ ] 用户明确回复"确认"或"继续"
- [ ] 确认本次 apply 涉及的资源及预估费用
- [ ] 无意外资源被创建或销毁（检查 `~` `+` `-` 标记）

---

## 1. 实例规划

### 1.1 节点分配

| 节点 | 来源 | 实例 ID | 操作 | 费用影响 |
|------|------|---------|------|---------|
| k3s-node-01 | **复用现有实例** | `6f44c80fcd674637b260400dcd1d0a28` | `terraform import` | 无新增费用 |
| k3s-node-02 | **新建（测试）** | Terraform 创建 | `terraform apply -var=create_node_02=true` | **+~45 元/月** |
| k3s-node-03 | **新建（最终）** | Terraform 创建 | `terraform apply -var=create_node_03=true` | **+~45 元/月** |

### 1.2 分步策略

```
Phase A ─── 安全组 + 导入现有实例（无新费用）
    │
    ▼
Phase B ─── 测试创建 k3s-node-02（+45元/月，需确认）
    │
    ▼
Phase C ─── 验证 k3s-node-02 配置正确
    │
    ▼
Phase D ─── 创建 k3s-node-03（+45元/月，需确认）
```

**为什么分步？**
1. **降低风险** — 先创建 1 台验证 Terraform 配置无误，避免一次性创建 3 台后发现问题
2. **控制成本** — 每次只增加 1 台费用，发现问题可及时 `destroy` 止损
3. **复用现有** — 现有实例 `6f44c80fcd674637b260400dcd1d0a28` 直接复用，省 1 台费用

---

## 2. Terraform 配置

### 2.1 目录结构

```
terraform/
├── main.tf              # 主配置
├── variables.tf         # 输入变量（含分步控制变量）
├── outputs.tf           # 输出
├── user-data.sh         # cloud-init（仅新实例使用）
├── terraform.tfvars     # 变量赋值
└── README.md            # 使用说明
```

### 2.2 `variables.tf` — 输入变量

```hcl
# ═══════════════════════════════════════════════
# Provider 配置
# ═══════════════════════════════════════════════

variable "alicloud_region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hangzhou"
}

# ═══════════════════════════════════════════════
# 复用现有网络
# ═══════════════════════════════════════════════

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

# ═══════════════════════════════════════════════
# 复用现有实例（k3s-node-01）
# ═══════════════════════════════════════════════

variable "existing_instance_id" {
  description = "复用的现有 ECS 实例 ID（k3s-node-01）"
  type        = string
  default     = "6f44c80fcd674637b260400dcd1d0a28"
}

# ═══════════════════════════════════════════════
# 新建实例配置
# ═══════════════════════════════════════════════

variable "instance_type" {
  description = "ECS 实例规格"
  type        = string
  default     = "ecs.e-c1m1.large"
}

variable "image_id" {
  description = "镜像 ID（留空则自动查询最新 Alibaba Cloud Linux 3）"
  type        = string
  default     = ""
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

variable "ssh_key_name" {
  description = "阿里云 SSH 密钥对名称（需预先在控制台创建）"
  type        = string
  default     = "k3s-cluster-key"
}

# ═══════════════════════════════════════════════
# 分步创建控制变量（核心）
# ═══════════════════════════════════════════════

variable "create_node_02" {
  description = "是否创建 k3s-node-02（测试实例）。设为 true 前需用户确认费用。"
  type        = bool
  default     = false
}

variable "create_node_03" {
  description = "是否创建 k3s-node-03（最终实例）。设为 true 前需用户确认费用。"
  type        = bool
  default     = false
}

# ═══════════════════════════════════════════════
# Jump Host & 用户配置
# ═══════════════════════════════════════════════

variable "jump_host_ip" {
  description = "Jump Host 内网 IP（用于安全组 SSH 限制）"
  type        = string
  default     = "172.26.5.95"
}

variable "ops_user" {
  description = "运维用户名"
  type        = string
  default     = "ops"
}

variable "ops_pubkey" {
  description = "Ops 用户的 SSH 公钥（cloud-init 注入，仅新实例）"
  type        = string
  default     = ""
}
```

### 2.3 `main.tf` — 主配置

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

# ═══════════════════════════════════════════════
# Data Sources — 引用现有资源
# ═══════════════════════════════════════════════

data "alicloud_vpcs" "existing" {
  ids = [var.vpc_id]
}

data "alicloud_vswitchs" "existing" {
  ids = [var.vswitch_id]
}

data "alicloud_images" "acl3" {
  count       = var.image_id == "" ? 1 : 0
  name_regex  = "^alibaba_cloud_linux_3.*2104.*x64"
  most_recent = true
  owners      = "system"
}

# 引用现有实例（k3s-node-01）的当前配置
data "alicloud_instances" "existing_node_01" {
  ids = [var.existing_instance_id]
}

locals {
  image_id  = var.image_id != "" ? var.image_id : data.alicloud_images.acl3[0].images[0].id
  vpc_cidr  = data.alicloud_vpcs.existing.vpcs[0].cidr_block

  # 从现有实例读取实际配置（用于 resource 定义，避免 drift）
  existing_instance_type = data.alicloud_instances.existing_node_01.instances[0].instance_type
  existing_image_id      = data.alicloud_instances.existing_node_01.instances[0].image_id
  existing_private_ip    = data.alicloud_instances.existing_node_01.instances[0].private_ip
}

# ═══════════════════════════════════════════════
# 安全组（免费，所有节点共用）
# ═══════════════════════════════════════════════

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

# K3s API Server
resource "alicloud_security_group_rule" "k3s_api" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "6443/6443"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = "0.0.0.0/0"
}

# etcd client: 仅 VPC 内部
resource "alicloud_security_group_rule" "etcd_client" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "2379/2379"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = local.vpc_cidr
}

# etcd peer: 仅 VPC 内部
resource "alicloud_security_group_rule" "etcd_peer" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "2380/2380"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = local.vpc_cidr
}

# kubelet: 仅 VPC 内部
resource "alicloud_security_group_rule" "kubelet" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "10250/10250"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = local.vpc_cidr
}

# flannel VXLAN: 仅 VPC 内部
resource "alicloud_security_group_rule" "flannel" {
  type              = "ingress"
  ip_protocol       = "udp"
  port_range        = "8472/8472"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = local.vpc_cidr
}

# Ingress HTTP
resource "alicloud_security_group_rule" "http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "80/80"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = "0.0.0.0/0"
}

# Ingress HTTPS
resource "alicloud_security_group_rule" "https" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "443/443"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = "0.0.0.0/0"
}

# ═══════════════════════════════════════════════
# k3s-node-01: 复用现有实例（import，不创建）
# ═══════════════════════════════════════════════
#
# 导入命令（Phase A 执行）：
#   terraform import alicloud_instance.k3s_node_01 6f44c80fcd674637b260400dcd1d0a28
#
# 导入后 terraform plan 会显示 drift（配置 vs 实际），
# 通过 ignore_changes 忽略不想修改的属性，
# 仅管理 security_groups 和 tags。
#
# 注意：现有实例的系统初始化通过 Ansible 完成（cloud-init 不会重新执行）。

resource "alicloud_instance" "k3s_node_01" {
  instance_name = "k3s-node-01"
  host_name     = "k3s-node-01"
  instance_type = local.existing_instance_type
  image_id      = local.existing_image_id
  vswitch_id    = var.vswitch_id

  # 仅管理安全组（将 K3s 安全组加入此实例）
  security_groups = [alicloud_security_group.k3s.id]

  tags = {
    Project  = "k3s-cluster"
    Phase    = "phase-1"
    NodeRole = "server-etcd"
    NodeName = "k3s-node-01"
    Source   = "existing"
  }

  # 忽略以下属性变更，避免修改现有实例配置
  lifecycle {
    ignore_changes = [
      system_disk_size,
      system_disk_category,
      internet_max_bandwidth_out,
      internet_charge_type,
      key_name,
      user_data,
      spot_strategy,
      spot_price_limit,
      deletion_protection,
      force_delete,
    ]
  }
}

# ═══════════════════════════════════════════════
# k3s-node-02: 测试创建（Phase B，需用户确认）
# ═══════════════════════════════════════════════

resource "alicloud_instance" "k3s_node_02" {
  count = var.create_node_02 ? 1 : 0

  instance_name              = "k3s-node-02"
  host_name                  = "k3s-node-02"
  instance_type              = var.instance_type
  image_id                   = local.image_id
  security_groups            = [alicloud_security_group.k3s.id]
  vswitch_id                 = var.vswitch_id
  system_disk_size           = var.system_disk_size
  system_disk_category       = var.system_disk_category
  internet_max_bandwidth_out = 0  # 不分配公网 IP
  key_name                   = var.ssh_key_name

  user_data = templatefile("${path.module}/user-data.sh", {
    ops_user   = var.ops_user
    ops_pubkey = var.ops_pubkey
  })

  tags = {
    Project  = "k3s-cluster"
    Phase    = "phase-1"
    NodeRole = "server-etcd"
    NodeName = "k3s-node-02"
    Source   = "terraform"
  }
}

# ═══════════════════════════════════════════════
# k3s-node-03: 最终创建（Phase D，需用户确认）
# ═══════════════════════════════════════════════

resource "alicloud_instance" "k3s_node_03" {
  count = var.create_node_03 ? 1 : 0

  instance_name              = "k3s-node-03"
  host_name                  = "k3s-node-03"
  instance_type              = var.instance_type
  image_id                   = local.image_id
  security_groups            = [alicloud_security_group.k3s.id]
  vswitch_id                 = var.vswitch_id
  system_disk_size           = var.system_disk_size
  system_disk_category       = var.system_disk_category
  internet_max_bandwidth_out = 0
  key_name                   = var.ssh_key_name

  user_data = templatefile("${path.module}/user-data.sh", {
    ops_user   = var.ops_user
    ops_pubkey = var.ops_pubkey
  })

  tags = {
    Project  = "k3s-cluster"
    Phase    = "phase-1"
    NodeRole = "server-etcd"
    NodeName = "k3s-node-03"
    Source   = "terraform"
  }
}
```

### 2.4 `outputs.tf` — 输出

```hcl
# k3s-node-01（现有实例，始终有值）
output "k3s_node_01_private_ip" {
  description = "k3s-node-01 内网 IP（现有实例）"
  value       = alicloud_instance.k3s_node_01.private_ip
}

output "k3s_node_01_instance_id" {
  description = "k3s-node-01 实例 ID"
  value       = alicloud_instance.k3s_node_01.id
}

# k3s-node-02（条件创建）
output "k3s_node_02_private_ip" {
  description = "k3s-node-02 内网 IP（创建后才有值）"
  value       = length(alicloud_instance.k3s_node_02) > 0 ? alicloud_instance.k3s_node_02[0].private_ip : null
}

output "k3s_node_02_instance_id" {
  description = "k3s-node-02 实例 ID"
  value       = length(alicloud_instance.k3s_node_02) > 0 ? alicloud_instance.k3s_node_02[0].id : null
}

# k3s-node-03（条件创建）
output "k3s_node_03_private_ip" {
  description = "k3s-node-03 内网 IP（创建后才有值）"
  value       = length(alicloud_instance.k3s_node_03) > 0 ? alicloud_instance.k3s_node_03[0].private_ip : null
}

output "k3s_node_03_instance_id" {
  description = "k3s-node-03 实例 ID"
  value       = length(alicloud_instance.k3s_node_03) > 0 ? alicloud_instance.k3s_node_03[0].id : null
}

# 安全组
output "security_group_id" {
  description = "K3s 集群安全组 ID"
  value       = alicloud_security_group.k3s.id
}

# 汇总（用于 Ansible inventory）
output "ansible_inventory" {
  description = "Ansible inventory 片段（根据已创建的节点动态生成）"
  value = <<-EOT
    [k3s_servers]
    k3s-node-01 ansible_host=${alicloud_instance.k3s_node_01.private_ip}
    %{ if length(alicloud_instance.k3s_node_02) > 0 }
    k3s-node-02 ansible_host=${alicloud_instance.k3s_node_02[0].private_ip}
    %{ endif }
    %{ if length(alicloud_instance.k3s_node_03) > 0 }
    k3s-node-03 ansible_host=${alicloud_instance.k3s_node_03[0].private_ip}
    %{ endif }
  EOT
}
```

### 2.5 `terraform.tfvars` — 变量赋值

```hcl
# ═══ 分步创建控制（默认全部 false，按阶段手动开启）═══
create_node_02 = false
create_node_03 = false

# ═══ Ops 用户公钥（新实例 cloud-init 用）═══
ops_pubkey = "ssh-ed25519 AAAAC3Nz... your_email@example.com"
```

---

## 3. 执行计划

### Phase A: 安全组 + 导入现有实例

> **费用影响：无**（安全组免费，import 不创建资源）

```bash
cd terraform/

# 1. 初始化
terraform init

# 2. 导入现有实例到 Terraform state
terraform import alicloud_instance.k3s_node_01 6f44c80fcd674637b260400dcd1d0a28

# 3. 预览（应显示：创建安全组 + 规则，修改 node-01 的安全组关联）
terraform plan

# 4. 确认无误后执行（仅创建安全组，不产生 ECS 费用）
#    ⚠️ 虽然不产生费用，但仍建议展示 plan 输出给用户
terraform apply
```

**Phase A 验证**：
```bash
# 安全组已创建
terraform output security_group_id

# node-01 已在 state 中
terraform state list
# 预期输出包含：
#   alicloud_instance.k3s_node_01
#   alicloud_security_group.k3s
#   alicloud_security_group_rule.*（多条）

# node-01 内网 IP
terraform output k3s_node_01_private_ip

# 确认 node-01 安全组已更新（阿里云控制台或 CLI）
# 注：可能需要重启实例使安全组生效
```

**注意事项**：
- `terraform import` 后首次 `plan` 可能显示大量属性 drift
- 需要根据 plan 输出调整 `main.tf` 中 `k3s_node_01` 的属性，直到 plan 只显示 `security_groups` 的变更
- 如果 `host_name` 不匹配，加入 `ignore_changes`
- 如果 `instance_name` 不匹配，加入 `ignore_changes`
- 现有实例的系统初始化（ops 用户、swap 关闭等）需通过 Ansible 完成，cloud-init 不会重新执行

---

### Phase B: 测试创建 k3s-node-02

> **费用影响：+~45 元/月**（1 台 ecs.e-c1m1.large）
> **需要用户确认！**

```bash
# 1. 预览（显示将创建 1 台 ECS 实例）
terraform plan -var=create_node_02=true

# ──────────────────────────────────────────────
# ⚠️ 余额保护检查点
# 
# 展示 plan 输出给用户，说明：
#   - 将创建 1 台 ECS 实例（ecs.e-c1m1.large）
#   - 预估费用：~45 元/月
#   - 实例名：k3s-node-02
#   
# 等待用户回复"确认"后继续。
# ──────────────────────────────────────────────

# 2. 用户确认后执行
terraform apply -var=create_node_02=true

# 3. 记录内网 IP
terraform output k3s_node_02_private_ip
```

**Phase B 验证**：
```bash
# 通过 Jump Host SSH 到新实例
ssh -J ops@47.114.124.150 ops@<node-02-ip>

# 验证 cloud-init 完成
hostname                        # k3s-node-02
free -h                         # Swap 全为 0
sysctl net.ipv4.ip_forward      # 返回 1
timedatectl                     # Asia/Shanghai
which dnf                       # /usr/bin/dnf
ls /tmp/cloud-init-k3s-done     # 文件存在
cat /etc/sudoers.d/ops          # 包含 NOPASSWD

# 验证安全组规则生效
sudo ss -tlnp | grep 6443       # 端口监听正常（K3s 部署后）
```

**如果验证失败**：
```bash
# 查看 cloud-init 日志
ssh -J ops@47.114.124.150 ops@<node-02-ip> "sudo cat /var/log/cloud-init-output.log"

# 如需销毁测试实例（停止计费）
# ⚠️ 需用户确认
terraform destroy -target=alicloud_instance.k3s_node_02
```

---

### Phase C: 验证测试实例

> **费用影响：无**（只读验证）

Phase B 创建成功后，进行全面验证，确保 Terraform 配置正确：

```bash
# 1. Terraform state 一致性
terraform plan -var=create_node_02=true
# 预期：No changes. Your infrastructure matches the configuration.

# 2. cloud-init 完整性检查
ssh -J ops@47.114.124.150 ops@<node-02-ip> << 'EOF'
  echo "=== hostname ==="; hostname
  echo "=== swap ==="; free -h | grep Swap
  echo "=== ip_forward ==="; sysctl net.ipv4.ip_forward
  echo "=== timezone ==="; timedatectl | grep "Time zone"
  echo "=== chrony ==="; chronyc tracking | head -3
  echo "=== ops user ==="; id ops
  echo "=== sudo ==="; cat /etc/sudoers.d/ops
  echo "=== ssh key ==="; ls -la /home/ops/.ssh/authorized_keys
  echo "=== packages ==="; dnf list installed | grep -E "curl|wget|vim|git|chrony"
  echo "=== firewalld ==="; systemctl is-active firewalld 2>&1
  echo "=== cloud-init flag ==="; ls /tmp/cloud-init-k3s-done
EOF

# 3. 安全组规则验证
# 在阿里云控制台确认 k3s-cluster-sg 的规则列表

# 4. Ansible 连通性测试
ansible k3s-node-02 -i inventory.ini -m ping
# 预期：SUCCESS
```

**验证通过后**，进入 Phase D。如果验证失败，修复配置后重新创建 node-02。

---

### Phase D: 创建 k3s-node-03

> **费用影响：+~45 元/月**（1 台 ecs.e-c1m1.large）
> **需要用户确认！**

```bash
# 1. 预览（显示将创建 1 台 ECS 实例）
terraform plan -var=create_node_02=true -var=create_node_03=true

# ──────────────────────────────────────────────
# ⚠️ 余额保护检查点
# 
# 展示 plan 输出给用户，说明：
#   - 将创建 1 台 ECS 实例（ecs.e-c1m1.large）
#   - 预估费用：+~45 元/月（累计 ~90 元/月新增）
#   - 实例名：k3s-node-03
#   
# 等待用户回复"确认"后继续。
# ──────────────────────────────────────────────

# 2. 用户确认后执行
terraform apply -var=create_node_02=true -var=create_node_03=true

# 3. 记录内网 IP
terraform output k3s_node_03_private_ip
```

**Phase D 验证**：
```bash
# 同 Phase B 验证流程
ssh -J ops@47.114.124.150 ops@<node-03-ip>
hostname  # k3s-node-03
# ... 完整 cloud-init 检查
```

---

### Phase E: 最终验证 & Ansible Inventory 生成

> **费用影响：无**

```bash
# 1. 所有节点 state 一致
terraform plan -var=create_node_02=true -var=create_node_03=true
# 预期：No changes.

# 2. 生成 Ansible inventory 片段
terraform output ansible_inventory

# 3. 完整节点列表
terraform output -json | python3 -m json.tool

# 4. Ansible 全节点连通性
ansible all -i inventory.ini -m ping
# 预期：3 个节点全部 SUCCESS
```

---

## 4. 费用汇总

| 阶段 | 操作 | 新增月费 | 累计月费 | 需确认 |
|------|------|---------|---------|--------|
| Phase A | 安全组 + import | 0 元 | 0 元 | 否 |
| Phase B | 创建 k3s-node-02 | +45 元 | 45 元 | **是** |
| Phase C | 验证 | 0 元 | 45 元 | 否 |
| Phase D | 创建 k3s-node-03 | +45 元 | 90 元 | **是** |
| Phase E | 最终验证 | 0 元 | 90 元 | 否 |

> k3s-node-01 复用现有实例，无新增费用。
> 现有 ECS（172.26.5.95）作为 Jump Host，费用已有。

---

## 5. 回滚 & 清理

### 5.1 销毁单个实例（如测试失败）

```bash
# ⚠️ 需用户确认
# 销毁 k3s-node-02
terraform destroy -target=alicloud_instance.k3s_node_02 -var=create_node_02=true

# 销毁 k3s-node-03
terraform destroy -target=alicloud_instance.k3s_node_03 -var=create_node_02=true -var=create_node_03=true
```

### 5.2 销毁所有新建资源（项目结束）

```bash
# ⚠️ 需用户确认
# 销毁所有新建 ECS + 安全组
terraform destroy -var=create_node_02=true -var=create_node_03=true

# 注意：k3s_node_01 是导入的现有实例，
# terraform destroy 会将其从 state 移除但不会删除实例本身。
# 需确认 plan 输出中没有 node-01 的删除操作。
```

### 5.3 从 state 移除现有实例（不删除实例）

```bash
# 仅从 Terraform state 移除，不影响实际实例
terraform state rm alicloud_instance.k3s_node_01
```

---

## 6. 现有实例初始化

k3s-node-01 是复用的现有实例，cloud-init 不会重新执行。需通过 Ansible 完成系统初始化：

```bash
# 1. 确保 inventory.ini 中包含 k3s-node-01
# 2. 运行系统初始化 Playbook
ansible-playbook -i inventory.ini playbooks/00-init-system.yml --limit k3s-node-01

# 3. 验证
ansible k3s-node-01 -i inventory.ini -m command -a "hostname"
ansible k3s-node-01 -i inventory.ini -m command -a "free -h"
ansible k3s-node-01 -i inventory.ini -m command -a "sysctl net.ipv4.ip_forward"
ansible k3s-node-01 -i inventory.ini -m command -a "id ops"
```

> 如果现有实例已有其他服务运行，Ansible Playbook 应使用 `--limit` 仅针对 k3s-node-01 执行，
> 避免影响其他节点。

---

## 7. 注意事项

### 7.1 terraform import 的 drift 处理

`terraform import` 后，`plan` 可能显示属性 drift。处理原则：

| 属性 | 处理方式 | 原因 |
|------|---------|------|
| `security_groups` | **允许变更** | 需要加入 K3s 安全组 |
| `tags` | **允许变更** | 添加项目管理标签 |
| `instance_type` | `ignore_changes` | 不改变现有实例规格 |
| `image_id` | `ignore_changes` | 不改变现有实例镜像 |
| `system_disk_*` | `ignore_changes` | 不改变现有实例磁盘 |
| `host_name` | `ignore_changes` | 修改 hostname 需重启，可能影响已有服务 |
| `instance_name` | `ignore_changes` | 避免不必要的修改 |
| `key_name` | `ignore_changes` | 密钥变更需重启 |
| `user_data` | `ignore_changes` | user_data 仅首次启动生效 |
| `internet_*` | `ignore_changes` | 不改变网络配置 |

如果 `plan` 仍显示无法消除的 drift，持续追加 `ignore_changes` 属性直到 plan 只显示 `security_groups` 和 `tags` 的变更。

### 7.2 安全组生效

修改现有实例的安全组关联后，可能需要重启实例使规则完全生效。如果无法重启：
- 安全组规则对新连接立即生效
- 已有连接不受影响
- 建议在维护窗口操作

### 7.3 state 文件管理

- `terraform.tfstate` 包含资源 ID，**不要提交到 Git**
- 在 `.gitignore` 中添加 `*.tfstate`、`*.tfstate.*`、`.terraform/`
- 建议使用阿里云 OSS 作为 Terraform backend（可选，简历加分项）：

```hcl
terraform {
  backend "oss" {
    bucket   = "k3s-tfstate"
    prefix   = "k3s-cluster"
    region   = "cn-hangzhou"
    encrypt  = true
  }
}
```
