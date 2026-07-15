# 01-create-distros.ps1
# Run on Windows PowerShell to create 3 WSL2 distro instances for K3s cluster
# Usage: .\01-create-distros.ps1

$ErrorActionPreference = "Stop"

$BaseDistro = "Ubuntu-22.04"
$StoragePath = "D:\WSL\k3s-cluster"
$TarballPath = "$StoragePath\ubuntu-base.tar"

$Nodes = @(
    @{ Name = "k3s-node-01"; Path = "$StoragePath\node-01" }
    @{ Name = "k3s-node-02"; Path = "$StoragePath\node-02" }
    @{ Name = "k3s-node-03"; Path = "$StoragePath\node-03" }
)

Write-Host "=== K3s Cluster WSL2 Distro Creation ===" -ForegroundColor Cyan

# Check if base distro exists
$distroList = wsl -l -q
if ($distroList -notcontains $BaseDistro) {
    Write-Host "Base distro $BaseDistro not found. Installing..." -ForegroundColor Yellow
    wsl --install -d Ubuntu-22.04 --no-launch
    Write-Host "Please complete the initial setup of $BaseDistro, then re-run this script." -ForegroundColor Yellow
    exit 1
}

# Create storage directory
if (-not (Test-Path $StoragePath)) {
    New-Item -ItemType Directory -Path $StoragePath -Force | Out-Null
    Write-Host "Created storage directory: $StoragePath" -ForegroundColor Green
}

# Export base image if not already done
if (-not (Test-Path $TarballPath)) {
    Write-Host "Exporting $BaseDistro to $TarballPath ..." -ForegroundColor Yellow
    wsl --export $BaseDistro $TarballPath
    Write-Host "Export complete." -ForegroundColor Green
} else {
    Write-Host "Tarball already exists, skipping export." -ForegroundColor DarkGray
}

# Import 3 instances
foreach ($node in $Nodes) {
    $existing = wsl -l -q
    if ($existing -contains $node.Name) {
        Write-Host "$($node.Name) already exists, skipping." -ForegroundColor DarkGray
        continue
    }

    if (-not (Test-Path $node.Path)) {
        New-Item -ItemType Directory -Path $node.Path -Force | Out-Null
    }

    Write-Host "Importing $($node.Name) ..." -ForegroundColor Yellow
    wsl --import $node.Name $node.Path $TarballPath --version 2
    Write-Host "Created $($node.Name) at $($node.Path)" -ForegroundColor Green
}

# Verify
Write-Host "`n=== Verification ===" -ForegroundColor Cyan
wsl -l -v

Write-Host "`nDone. 3 WSL2 instances created." -ForegroundColor Green
Write-Host "Next: enter each distro and run the init script." -ForegroundColor Yellow
Write-Host "  wsl -d k3s-node-01" -ForegroundColor White
Write-Host "  wsl -d k3s-node-02" -ForegroundColor White
Write-Host "  wsl -d k3s-node-03" -ForegroundColor White
