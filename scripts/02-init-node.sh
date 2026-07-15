#!/bin/bash
# 02-init-node.sh
# Run inside each WSL2 distro BEFORE WSL restart
# Sets up: wsl.conf, hostname, hosts, ops user, openssh-server, IP alias service, sshd config
# After restart, use 03-post-restart.sh to start services and set up SSH keys
#
# Usage: bash 02-init-node.sh <node-name> <node-ip>
# Example: bash 02-init-node.sh node-01 192.168.50.11

set -euo pipefail

NODE_NAME="${1:?Usage: $0 <node-name> <node-ip>}"
NODE_IP="${2:?Usage: $0 <node-name> <node-ip>}"

echo "=== Initializing $NODE_NAME ($NODE_IP) ==="

# 1. Configure wsl.conf (enables systemd + sets hostname)
echo "[1/7] Writing /etc/wsl.conf ..."
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
echo "[2/7] Writing /etc/hosts ..."
cat > /etc/hosts << EOF
127.0.0.1   localhost
192.168.50.11  node-01
192.168.50.12  node-02
192.168.50.13  node-03
EOF

# 3. Set hostname immediately (will persist after restart via wsl.conf)
echo "[3/7] Setting hostname ..."
hostnamectl set-hostname "$NODE_NAME" 2>/dev/null || hostname "$NODE_NAME"

# 4. Create ops user
echo "[4/7] Creating ops user ..."
if ! id -u ops &>/dev/null; then
    useradd -m -s /bin/bash ops
    echo 'ops:ops123' | chpasswd
    echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops
    chmod 0440 /etc/sudoers.d/ops
    echo "  Created user 'ops' with password 'ops123'"
else
    echo "  User 'ops' already exists"
fi

# 5. Install openssh-server and iproute2 (needed for SSH and IP alias)
echo "[5/7] Installing openssh-server and iproute2 ..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server iproute2 > /dev/null 2>&1
echo "  Done."

# 6. Write IP alias systemd service file
#    This will be activated by systemd after WSL restart
echo "[6/7] Creating wsl-ip-alias service ..."
cat > /etc/systemd/system/wsl-ip-alias.service << EOF
[Unit]
Description=WSL2 IP Alias for K3s node
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ip addr add ${NODE_IP}/24 dev eth0
ExecStop=/sbin/ip addr del ${NODE_IP}/24 dev eth0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
echo "  Service file written. Will be enabled after restart."

# 7. Configure sshd to listen on this node's IP only
echo "[7/7] Configuring sshd ..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Remove existing ListenAddress lines
sed -i '/^#\?\s*ListenAddress/d' "$SSHD_CONFIG"
# Add our ListenAddress
echo "ListenAddress ${NODE_IP}" >> "$SSHD_CONFIG"

# Ensure Port 22
sed -i 's/^#\?\s*Port.*/Port 22/' "$SSHD_CONFIG"

# Ensure PubkeyAuthentication is enabled
sed -i 's/^#\?\s*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

# Generate host keys if they don't exist
ssh-keygen -A 2>/dev/null

echo "  sshd configured to listen on ${NODE_IP}:22"

echo ""
echo "=== Pre-restart setup complete for $NODE_NAME ==="
echo ""
echo "IMPORTANT: You must restart WSL for systemd to take effect."
echo "  In PowerShell:  wsl --shutdown"
echo "  Then re-enter:   wsl -d k3s-${NODE_NAME}"
echo ""
echo "After restart, run the post-restart script:"
echo "  bash /mnt/d/Study/Note/project/k8s/scripts/03-post-restart.sh ${NODE_NAME} ${NODE_IP}"
