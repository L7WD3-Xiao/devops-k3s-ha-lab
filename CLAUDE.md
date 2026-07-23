# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

K3s HA cluster (3-node, all control-plane+etcd) on Alibaba Cloud, with FluxCD GitOps + GitHub Actions CI/CD. Runs a Go short-link service backed by MySQL (via ProxySQL) and Redis (via Sentinel).

**Cluster endpoint**: `http://<集群公网入口IP>/health`
**SSH tunnel**: Local port 7897 → node-01:8888 (managed by `scripts/autossh-tunnel.sh`)

## Key Architecture

### CI/CD Flow

```
git push (app/** or Dockerfile changed)
    │
    ▼ GitHub Actions
    ├── go vet + go test
    ├── docker build (ldflags injects VERSION into binary)
    ├── docker push → ACR public domain (v1.0.{run_number})
    ├── sed update k8s/app-layer/kustomization.yaml newTag
    └── git commit + push
    │
    ▼ FluxCD (KustomizeController)
    ├── SourceController detects new commit (~1min)
    └── KustomizeController renders + rolling update
    │
    ▼ Traefik → shortlink:8080 (new version)
```

### Directory Layout

```
.github/workflows/build-deploy.yml   # CI pipeline
app/                                   # Go source (main.go, go.mod, go.sum)
Dockerfile                             # Multi-stage Go build
scripts/
  autossh-tunnel.sh                    # SSH tunnel daemon
  build-push.sh                        # Manual push (nerdctl for on-node builds)
  check-tunnel.sh                      # Tunnel health check
k8s/
  data-layer/                          # Redis, Sentinel, ProxySQL, Orchestrator manifests
  app-layer/                           # shortlink Deployment, ConfigMap, Ingress, HPA
    kustomization.yaml                 # image tag updated by CI (not IUA)
clusters/production/
  data-layer.yaml                      # FluxCD Kustomization CR (no dependsOn)
  app-layer.yaml                       # FluxCD Kustomization CR (dependsOn: data-layer)
  image-repo.yaml                      # FluxCD ImageRepository (VPC domain, 5min scan)
  image-policy.yaml                    # FluxCD ImagePolicy (semver >=1.0.0)
  image-update.yaml                    # FluxCD IUA — SUSPENDED (Setters strategy bug)
ansible/playbooks/
  00-init-system.yml                   # OS init
  01-deploy-k3s.yml                    # K3s cluster deployment
  02-deploy-mysql.yml                  # MySQL/Redis data layer
  03-configure-acr.yml                # ACR registry config
docs/                                  # Phase docs + 踩坑 records
terraform/                             # (reserved for future IaC)
```

### Secrets Management

Secrets are NOT in Git — they are created manually on the cluster:
- `mysql-credentials` (data-layer ns)
- `shortlink-secrets` (app-layer ns)
- `acr-credentials` (flux-system ns)
- `k8s/app-layer/secret.yaml` is gitignored; `secret.yaml.example` serves as template

### Image Strategy

- **Public ACR domain** for CI push (GitHub Actions outside VPC)
- **VPC ACR domain** for cluster pull (free, fast, inside Alibaba Cloud VPC)
- Both domains access the same registry — push to public, pull via VPC

### Important Design Decisions

1. **ImageUpdateAutomation is SUSPENDED** — FluxCD v2.9.2 Setters strategy has a bug that writes the full image reference as `newTag`. CI workflow directly updates `kustomization.yaml` via `sed` instead.

2. **Kustomize images.name must match Deployment image exactly** — for ACR's three-segment path (`registry/namespace/repo`), short-form `namespace/repo` does NOT match. Use full VPC domain path.

3. **No base/overlays Kustomize layers** — project size doesn't warrant it. Keep it flat.

4. **FluxCD controllers pinned to node-01** via `nodeSelector` — node-02/03 lack Internet access to pull ghcr.io images.

5. **SSH git remote** instead of HTTPS+PAT — PAT without `workflow` scope cannot push `.github/workflows/*` changes.

## Commands

### Tunnel Management (from Windows dev machine)

```bash
bash scripts/autossh-tunnel.sh start      # Start tunnel daemon
bash scripts/autossh-tunnel.sh stop       # Stop tunnel
bash scripts/autossh-tunnel.sh restart    # Restart
bash scripts/autossh-tunnel.sh status     # Show status + recent log
bash scripts/check-tunnel.sh              # Full health check
```

### Cluster Access (via tunnel)

```bash
# Tunnel forwards local:7897 → node-01:8888
# Set HTTP_PROXY=http://127.0.0.1:7897 in shells that need cluster access

# Direct node-01 SSH (independent of tunnel)
ssh k3s-node-01
```

### FluxCD

```bash
# Check all FluxCD resources
flux get all -A

# Reconcile specific component
flux reconcile kustomization app-layer

# Manual image update (alternative to CI push)
# Edit k8s/app-layer/kustomization.yaml newTag, commit, push
```

### Manual Build & Push (on node-01 without Docker)

```bash
sudo PATH="/usr/local/bin:$PATH" nerdctl build \
  --build-arg VERSION=v1.0.N \
  -t crpi-xxx.cn-hangzhou.personal.cr.aliyuncs.com/shortlink123/shortlink-app:v1.0.N .
# Use daocloud mirror: docker.m.daocloud.io/library/golang:1.22-alpine
```

### Go

```bash
cd app
go mod tidy     # Regenerate go.sum (uses GOPROXY=goproxy.cn)
go vet ./...
go test ./... -v -count=1
go build -ldflags="-s -w -X main.AppVersion=dev" -o shortlink .
```

### Version Injection

The binary version is injected at build time via Docker `ARG VERSION` + `-ldflags`:
- **CI**: passes `VERSION=${{ steps.meta.outputs.tag }}` as build-arg
- **Local**: defaults to `"dev"`
- **health endpoint**: `/health` returns `{"status":"ok","version":"v1.0.N"}`
- **Go requirement**: `var AppVersion` (not `const` — ldflags -X only works with vars)
