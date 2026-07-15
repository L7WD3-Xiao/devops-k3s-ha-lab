#!/bin/bash
# 03-post-restart.sh
# Run inside each WSL2 distro AFTER WSL restart (when systemd is active)
# Starts: wsl-ip-alias service, sshd
# On node-01: generates SSH keys for Ansible
#
# Usage: bash 03-post-restart.sh <node-name> <node-ip>
# Example: bash 03-post-restart.sh node-01 192.168.50.11

set -euo pipefail

NODE_NAME="${1:?Usage: $0 <node-name> <node-ip>}"
NODE_IP="${2:?Usage: $0 <node-name> <node-ip>}"

echo "=== Post-restart setup for $NODE_NAME ($NODE_IP) ==="

# 1. Verify systemd is running
echo "[1/5] Checking systemd ..."
if ! systemctl is-system-running &>/dev/null; then
    echo "  ERROR: systemd is not running. Did you restart WSL?"
    echo "  Run 'wsl --shutdown' in PowerShell, then re-enter this distro."
    exit 1
fi
SYSTEMD_STATE=$(systemctl is-system-running 2>/dev/null || true)
echo "  systemd state: $SYSTEMD_STATE"

# 2. Enable and start IP alias service
echo "[2/5] Starting wsl-ip-alias service ..."
systemctl daemon-reload
systemctl enable wsl-ip-alias.service 2>/dev/null || true
systemctl start wsl-ip-alias.service 2>/dev/null || true

# Verify IP alias
if ip addr show eth0 | grep -q "$NODE_IP"; then
    echo "  IP alias $NODE_IP is active on eth0"
else
    echo "  WARNING: IP alias not found, adding manually ..."
    ip addr add "${NODE_IP}/24" dev eth0 2>/dev/null || true
    if ip addr show eth0 | grep -q "$NODE_IP"; then
        echo "  IP alias $NODE_IP added manually"
    else
        echo "  ERROR: Could not add IP alias $NODE_IP"
        exit 1
    fi
fi

# 3. Enable and start sshd
echo "[3/5] Starting sshd ..."
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# Verify sshd is listening
sleep 1
if ss -tlnp | grep -q ":22\b"; then
    echo "  sshd is listening on port 22"
else
    echo "  ERROR: sshd is not listening"
    systemctl status ssh 2>/dev/null || systemctl status sshd 2>/dev/null || true
    exit 1
fi

# 4. Verify connectivity to other nodes
echo "[4/5] Testing connectivity to other nodes ..."
for IP in 192.168.50.11 192.168.50.12 192.168.50.13; do
    if [ "$IP" != "$NODE_IP" ]; then
        if ping -c 1 -W 2 "$IP" &>/dev/null; then
            echo "  $IP reachable"
        else
            echo "  WARNING: $IP not reachable (other nodes may not be up yet)"
        fi
    fi
done

# 5. On node-01: generate SSH keys for Ansible
echo "[5/5] SSH key setup ..."
if [ "$NODE_NAME" = "node-01" ]; then
    echo "  This is the Ansible control node. Setting up SSH keys ..."
    su - ops -c '
        if [ ! -f ~/.ssh/id_ed25519 ]; then
            ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
            echo "  SSH key pair generated for ops user"
        else
            echo "  SSH key already exists"
        fi
    '
    echo ""
    echo "  To distribute SSH keys to other nodes, run:"
    echo "    su - ops"
    echo "    ssh-copy-id ops@192.168.50.11"
    echo "    ssh-copy-id ops@192.168.50.12"
    echo "    ssh-copy-id ops@192.168.50.13"
    echo ""
    echo "  Then install Ansible:"
    echo "    su - ops"
    echo "    pip3 install ansible"
    echo ""
    echo "  Then run the playbook:"
    echo "    cd /mnt/d/Study/Note/project/k8s/ansible"
    echo "    ansible-playbook -i inventory.ini playbooks/00-init-system.yml"
else
    echo "  This is a worker node. No SSH key setup needed."
    echo "  Waiting for node-01 to distribute SSH keys."
fi

echo ""
echo "=== Post-restart setup complete for $NODE_NAME ==="
