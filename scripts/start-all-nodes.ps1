# start-all-nodes.ps1
# Starts all 3 WSL distros simultaneously and keeps them alive

$ErrorActionPreference = "Stop"

Write-Host "Starting all 3 K3s nodes simultaneously ..." -ForegroundColor Cyan

# Start each distro with a persistent process using cmd /c
cmd /c "start /b wsl -d k3s-node-02 -u root -- sleep infinity"
cmd /c "start /b wsl -d k3s-node-03 -u root -- sleep infinity"

Write-Host "Waiting 10s for systemd and IP aliases ..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

# Verify
Write-Host "`n=== WSL Status ===" -ForegroundColor Cyan
wsl -l -v

Write-Host "`n=== IP Aliases on eth0 (from node-01) ===" -ForegroundColor Cyan
wsl -d k3s-node-01 -u root -- ip addr show eth0 2>&1 | Select-String "inet "

Write-Host "`n=== Ping Tests (from node-01) ===" -ForegroundColor Cyan
wsl -d k3s-node-01 -u root -- ping -c 1 -W 2 192.168.50.12 2>&1
wsl -d k3s-node-01 -u root -- ping -c 1 -W 2 192.168.50.13 2>&1

Write-Host "`n=== SSH Tests (from node-01 as ops) ===" -ForegroundColor Cyan
wsl -d k3s-node-01 -u ops -- bash -c "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o PasswordAuthentication=no ops@192.168.50.12 hostname" 2>&1
wsl -d k3s-node-01 -u ops -- bash -c "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o PasswordAuthentication=no ops@192.168.50.13 hostname" 2>&1

Write-Host "`nDone." -ForegroundColor Green
