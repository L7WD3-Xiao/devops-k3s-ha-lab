# ═══════════════════════════════════════════════
# Provider 配置
# ═══════════════════════════════════════════════

variable "alicloud_region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hangzhou"
}

# ═══════════════════════════════════════════════
# 新建 VPC 网络（不复用 SWAS VPC）
# ═══════════════════════════════════════════════

variable "vpc_cidr" {
  description = "VPC 网段"
  type        = string
  default     = "192.168.0.0/16"
}

variable "vswitch_cidr" {
  description = "VSwitch 网段"
  type        = string
  default     = "192.168.1.0/24"
}

variable "zone_id" {
  description = "可用区 ID"
  type        = string
  default     = "cn-hangzhou-h"
}

# ═══════════════════════════════════════════════
# ECS 实例配置
# ═══════════════════════════════════════════════

variable "instance_type" {
  description = "ECS 实例规格（2C2G）"
  type        = string
  default     = "ecs.e-c1m2.large"
}

variable "instance_type_upgraded" {
  description = "ECS 实例规格（2C4G）"
  type        = string
  default     = "ecs.e-c1m2.large"
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

# ═══════════════════════════════════════════════
# SSH 密钥对
# ═══════════════════════════════════════════════

variable "ssh_key_name" {
  description = "阿里云 SSH 密钥对名称（Terraform 自动创建并导入公钥）"
  type        = string
  default     = "k3s-cluster-key"
}

# ═══════════════════════════════════════════════
# 分步创建控制变量
# ═══════════════════════════════════════════════
# 余额保护原则：每个变量设为 true 前需用户确认费用
# Phase A: 全部 false → 仅创建 VPC + 安全组 + 密钥（免费）
# Phase B: create_node_01 + create_eip = true → 创建首台 + EIP
# Phase D: create_node_02 = true → 创建第二台
# Phase E: create_node_03 = true → 创建第三台

variable "create_node_01" {
  description = "是否创建 k3s-node-01。"
  type        = bool
  default     = false
}

variable "create_node_02" {
  description = "是否创建 k3s-node-02。"
  type        = bool
  default     = false
}

variable "create_node_03" {
  description = "是否创建 k3s-node-03。"
  type        = bool
  default     = false
}

variable "create_eip" {
  description = "是否创建按量 EIP 并绑定到 k3s-node-01。按流量计费，~0.8 元/GB。"
  type        = bool
  default     = false
}

# ═══════════════════════════════════════════════
# 用户配置
# ═══════════════════════════════════════════════

variable "ops_user" {
  description = "运维用户名"
  type        = string
  default     = "ops"
}

variable "ops_pubkey" {
  description = "Ops 用户的 SSH 公钥（cloud-init 注入 + 阿里云密钥对）"
  type        = string
  default     = ""
}
