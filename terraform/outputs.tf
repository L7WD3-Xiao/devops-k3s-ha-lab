# ═══════════════════════════════════════════════
# 网络资源
# ═══════════════════════════════════════════════

output "vpc_id" {
  description = "新建 VPC ID"
  value       = alicloud_vpc.k3s.id
}

output "vswitch_id" {
  description = "VSwitch ID"
  value       = alicloud_vswitch.k3s.id
}

output "security_group_id" {
  description = "K3s 集群安全组 ID"
  value       = alicloud_security_group.k3s.id
}

output "ssh_key_pair_name" {
  description = "SSH 密钥对名称"
  value       = alicloud_ecs_key_pair.k3s.key_pair_name
}

# ═══════════════════════════════════════════════
# ECS 实例
# ═══════════════════════════════════════════════

output "k3s_node_01_private_ip" {
  description = "k3s-node-01 内网 IP"
  value       = length(alicloud_instance.k3s_node_01) > 0 ? alicloud_instance.k3s_node_01[0].private_ip : null
}

output "k3s_node_01_instance_id" {
  description = "k3s-node-01 实例 ID"
  value       = length(alicloud_instance.k3s_node_01) > 0 ? alicloud_instance.k3s_node_01[0].id : null
}

output "k3s_node_02_private_ip" {
  description = "k3s-node-02 内网 IP"
  value       = length(alicloud_instance.k3s_node_02) > 0 ? alicloud_instance.k3s_node_02[0].private_ip : null
}

output "k3s_node_02_instance_id" {
  description = "k3s-node-02 实例 ID"
  value       = length(alicloud_instance.k3s_node_02) > 0 ? alicloud_instance.k3s_node_02[0].id : null
}

output "k3s_node_03_private_ip" {
  description = "k3s-node-03 内网 IP"
  value       = length(alicloud_instance.k3s_node_03) > 0 ? alicloud_instance.k3s_node_03[0].private_ip : null
}

output "k3s_node_03_instance_id" {
  description = "k3s-node-03 实例 ID"
  value       = length(alicloud_instance.k3s_node_03) > 0 ? alicloud_instance.k3s_node_03[0].id : null
}

# ═══════════════════════════════════════════════
# EIP
# ═══════════════════════════════════════════════

output "k3s_node_01_eip" {
  description = "k3s-node-01 弹性公网 IP（SSH 直连 + 互联网出口）"
  value       = length(alicloud_eip_address.k3s_node_01) > 0 ? alicloud_eip_address.k3s_node_01[0].ip_address : null
}

# ═══════════════════════════════════════════════
# Ansible inventory 片段
# ═══════════════════════════════════════════════

output "ansible_inventory" {
  description = "Ansible inventory 片段（根据已创建的节点动态生成）"
  value = <<-EOT
    [k3s_servers]
    %{ if length(alicloud_instance.k3s_node_01) > 0 }
    k3s-node-01 ansible_host=${alicloud_instance.k3s_node_01[0].private_ip}
    %{ endif }
    %{ if length(alicloud_instance.k3s_node_02) > 0 }
    k3s-node-02 ansible_host=${alicloud_instance.k3s_node_02[0].private_ip}
    %{ endif }
    %{ if length(alicloud_instance.k3s_node_03) > 0 }
    k3s-node-03 ansible_host=${alicloud_instance.k3s_node_03[0].private_ip}
    %{ endif }
  EOT
}
