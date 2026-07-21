#!/bin/bash
# cloud-init user-data for K3s cluster nodes
# Runs as root on first boot
# Template variables (replaced by Terraform templatefile):
#   ${ops_user}   - ops username
#   ${ops_pubkey} - SSH public key for ops user

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
# 注意：Alibaba Cloud Linux 3 基于 RHEL 8，包名与 Debian 系不同
#   iproute2 → iproute
#   python3 已预装（python36）
dnf install -y curl wget vim git net-tools iproute chrony python3 python3-pip \
    gnupg ca-certificates tar gzip

# ── 4. 时区 & 时间同步 ──
timedatectl set-timezone Asia/Shanghai
systemctl enable --now chronyd

# ── 5. 创建 ops 用户 ──
useradd -m -s /bin/bash -G wheel "$OPS_USER"
echo "$OPS_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$OPS_USER"
chmod 0440 "/etc/sudoers.d/$OPS_USER"

# ── 6. 配置 ops SSH 公钥 ──
mkdir -p "/home/$OPS_USER/.ssh"
echo "$OPS_PUBKEY" > "/home/$OPS_USER/.ssh/authorized_keys"
chmod 700 "/home/$OPS_USER/.ssh"
chmod 600 "/home/$OPS_USER/.ssh/authorized_keys"
chown -R "$OPS_USER:$OPS_USER" "/home/$OPS_USER/.ssh"

# ── 7. 配置 /etc/hosts（节点间解析）──
# 注：内网 IP 在 cloud-init 运行时可能还未完全分配
# Ansible Playbook 00 会补充完整的 /etc/hosts
echo "# K3s cluster hosts (managed by Ansible)" >> /etc/hosts

# ── 8. 禁用 firewalld（K3s 自行管理网络规则）──
systemctl disable --now firewalld 2>/dev/null || true

# ── 9. 标记 cloud-init 完成 ──
touch /tmp/cloud-init-k3s-done
