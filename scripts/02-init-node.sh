#!/bin/bash
# 02-init-node.sh
# Run inside each WSL2 distro BEFORE Ansible takes over
# This script only handles wsl.conf setup (requires WSL restart)
# After restart, use Ansible playbook 00-init-system.yml for the rest
#
# Usage: bash 02-init-node.sh <node-name> <node-ip>
# Example: bash 02-init-node.sh node-01 192.168.50.11

set -euo pipefail

NODE_NAME="${1:?Usage: $0 <node-name> <node-ip>}"
NODE_IP="${2:?Usage: $0 <node-name> <node-ip>}"

echo "=== Initializing $NODE_NAME ($NODE_IP) ==="

# 1. Configure wsl.conf (enables systemd + sets hostname)
echo "[1/4] Writing /etc/wsl.conf ..."
cat > /etc/wsl.conf << EOF
[boot]
systemd=true

[network]
hostname=${NODE_NAME}
generateHosts=false
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=false
EOF

echo "  Done. systemd will be enabled after WSL restart."

# 2. Configure /etc/hosts
echo "[2/4] Writing /etc/hosts ..."
cat > /etc/hosts << EOF
127.0.0.1   localhost
192.168.50.11  node-01
192.168.50.12  node-02
192.168.50.13  node-03
EOF

# 3. Set hostname immediately (will persist after restart via wsl.conf)
echo "[3/4] Setting hostname ..."
hostnamectl set-hostname "$NODE_NAME" 2>/dev/null || hostname "$NODE_NAME"

# 4. Create ops user (so Ansible can connect after restart)
echo "[4/4] Creating ops user ..."
if ! id -u ops &>/dev/null; then
    useradd -m -s /bin/bash ops
    echo 'ops:ops123' | chpasswd
    echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops
    chmod 0440 /etc/sudoers.d/ops
    echo "  Created user 'ops' with password 'ops123'"
else
    echo "  User 'ops' already exists"
fi

echo ""
echo "=== Phase 1 setup complete for $NODE_NAME ==="
echo ""
echo "IMPORTANT: You must restart WSL for systemd to take effect."
echo "  In PowerShell:  wsl --shutdown"
echo "  Then re-enter:   wsl -d k3s-$(NODE_NAME)"
echo ""
echo "After restart, run the Ansible playbook from node-01:"
echo "  ansible-playbook -i inventory.ini playbooks/00-init-system.yml"
