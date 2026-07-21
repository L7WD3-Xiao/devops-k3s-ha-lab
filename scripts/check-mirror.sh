#!/bin/bash
echo "=== Killing stuck processes ==="
sudo pkill -f "k3s-install.sh" 2>/dev/null
sudo pkill -f "curl.*k3s" 2>/dev/null
sleep 2
ps aux | grep -E "k3s|curl" | grep -v grep || echo "All killed"

echo "=== Test rancher mirror (HEAD only) ==="
curl -sI --max-time 15 https://rancher-mirror.rancher.cn/k3s/k3s-linux-amd64 | head -10 || echo "rancher-mirror failed"

echo "=== Check K3s version we need ==="
grep -r "k3s_version\|K3S_VERSION" /home/ops/ansible/group_vars/ 2>/dev/null
