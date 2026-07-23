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
# Data Sources
# ═══════════════════════════════════════════════

data "alicloud_images" "acl3" {
  count       = var.image_id == "" ? 1 : 0
  name_regex  = "^aliyun_3_x64_20G_alibase_"
  most_recent = true
  owners      = "system"
}

locals {
  # 仅在实际需要创建实例时才引用 data source，避免 Phase A 强制求值
  image_id = var.image_id != "" ? var.image_id : (
    var.create_node_01 || var.create_node_02 || var.create_node_03
    ? data.alicloud_images.acl3[0].images[0].id
    : "placeholder"
  )
}

# ═══════════════════════════════════════════════
# VPC + VSwitch
# ═══════════════════════════════════════════════

resource "alicloud_vpc" "k3s" {
  vpc_name   = "k3s-cluster-vpc"
  cidr_block = var.vpc_cidr
  tags = {
    Project = "k3s-cluster"
  }
}

resource "alicloud_vswitch" "k3s" {
  vswitch_name = "k3s-cluster-vswitch"
  vpc_id       = alicloud_vpc.k3s.id
  cidr_block   = var.vswitch_cidr
  zone_id      = var.zone_id
  tags = {
    Project = "k3s-cluster"
  }
}

# ═══════════════════════════════════════════════
# SSH 密钥对（导入现有公钥）
# ═══════════════════════════════════════════════

resource "alicloud_ecs_key_pair" "k3s" {
  key_pair_name = var.ssh_key_name
  public_key    = var.ops_pubkey
}

# ═══════════════════════════════════════════════
# 安全组（所有节点共用）
# ═══════════════════════════════════════════════

resource "alicloud_security_group" "k3s" {
  security_group_name = "k3s-cluster-sg"
  description          = "Security group for K3s HA cluster"
  vpc_id               = alicloud_vpc.k3s.id
}

# SSH: 0.0.0.0/0（EIP 直连 + SWAS 内网互通跳板）
resource "alicloud_security_group_rule" "ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "22/22"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = "0.0.0.0/0"
}

# K3s API Server: 0.0.0.0/0（kubectl 远程访问）
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
  cidr_ip           = var.vpc_cidr
}

# etcd peer: 仅 VPC 内部
resource "alicloud_security_group_rule" "etcd_peer" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "2380/2380"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = var.vpc_cidr
}

# kubelet: 仅 VPC 内部
resource "alicloud_security_group_rule" "kubelet" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "10250/10250"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = var.vpc_cidr
}

# flannel VXLAN: 仅 VPC 内部
resource "alicloud_security_group_rule" "flannel" {
  type              = "ingress"
  ip_protocol       = "udp"
  port_range        = "8472/8472"
  security_group_id = alicloud_security_group.k3s.id
  cidr_ip           = var.vpc_cidr
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
# k3s-node-01（首台，Phase B）
# ═══════════════════════════════════════════════

resource "alicloud_instance" "k3s_node_01" {
  count = var.create_node_01 ? 1 : 0

  instance_name              = "k3s-node-01"
  host_name                  = "k3s-node-01"
  instance_type              = var.instance_type
  image_id                   = local.image_id
  security_groups            = [alicloud_security_group.k3s.id]
  vswitch_id                 = alicloud_vswitch.k3s.id
  system_disk_size           = var.system_disk_size
  system_disk_category       = var.system_disk_category
  internet_max_bandwidth_out = 0
  key_name                   = alicloud_ecs_key_pair.k3s.key_pair_name

  user_data = templatefile("${path.module}/user-data.sh", {
    ops_user   = var.ops_user
    ops_pubkey = var.ops_pubkey
  })

  tags = {
    Project  = "k3s-cluster"
    Phase    = "phase-1"
    NodeRole = "server-etcd"
    NodeName = "k3s-node-01"
  }
}

# ═══════════════════════════════════════════════
# k3s-node-02（Phase D）
# ═══════════════════════════════════════════════

resource "alicloud_instance" "k3s_node_02" {
  count = var.create_node_02 ? 1 : 0

  instance_name              = "k3s-node-02"
  host_name                  = "k3s-node-02"
  instance_type              = var.instance_type_upgraded
  image_id                   = local.image_id
  security_groups            = [alicloud_security_group.k3s.id]
  vswitch_id                 = alicloud_vswitch.k3s.id
  system_disk_size           = var.system_disk_size
  system_disk_category       = var.system_disk_category
  internet_max_bandwidth_out = 0
  key_name                   = alicloud_ecs_key_pair.k3s.key_pair_name

  user_data = templatefile("${path.module}/user-data.sh", {
    ops_user   = var.ops_user
    ops_pubkey = var.ops_pubkey
  })

  tags = {
    Project  = "k3s-cluster"
    Phase    = "phase-1"
    NodeRole = "server-etcd"
    NodeName = "k3s-node-02"
  }
}

# ═══════════════════════════════════════════════
# k3s-node-03（Phase E）
# ═══════════════════════════════════════════════

resource "alicloud_instance" "k3s_node_03" {
  count = var.create_node_03 ? 1 : 0

  instance_name              = "k3s-node-03"
  host_name                  = "k3s-node-03"
  instance_type              = var.instance_type_upgraded
  image_id                   = local.image_id
  security_groups            = [alicloud_security_group.k3s.id]
  vswitch_id                 = alicloud_vswitch.k3s.id
  system_disk_size           = var.system_disk_size
  system_disk_category       = var.system_disk_category
  internet_max_bandwidth_out = 0
  key_name                   = alicloud_ecs_key_pair.k3s.key_pair_name

  user_data = templatefile("${path.module}/user-data.sh", {
    ops_user   = var.ops_user
    ops_pubkey = var.ops_pubkey
  })

  tags = {
    Project  = "k3s-cluster"
    Phase    = "phase-1"
    NodeRole = "server-etcd"
    NodeName = "k3s-node-03"
  }
}

# ═══════════════════════════════════════════════
# EIP（按量计费，绑定 k3s-node-01）
# ═══════════════════════════════════════════════
# 用途：互联网出口（下载 K3s/镜像）+ SSH 直连
# 计费：PayByTraffic，0 底薪 + 0.8 元/GB
# 预估：一次性 ~3 元（安装），后续 < 1 元/月

resource "alicloud_eip_address" "k3s_node_01" {
  count                = var.create_eip ? 1 : 0
  address_name         = "k3s-node-01-eip"
  internet_charge_type = "PayByTraffic"
  bandwidth            = "10"
  description          = "EIP for k3s-node-01 (internet + SSH)"
}

resource "alicloud_eip_association" "k3s_node_01" {
  count         = var.create_eip && var.create_node_01 ? 1 : 0
  allocation_id = alicloud_eip_address.k3s_node_01[0].id
  instance_id   = alicloud_instance.k3s_node_01[0].id
}
