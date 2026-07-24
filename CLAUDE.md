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
    ├── Trivy image scan (HIGH/CRITICAL → block, SARIF → Code Scanning)
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

6. **PSS levels differ by namespace** — `app-layer` enforces `restricted` (shortlink runs as non-root UID 10001). `data-layer` enforces `baseline` only — ProxySQL and Orchestrator upstream images require root and neither project ships a non-root variant. `audit`/`warn` labels are set to `restricted` on data-layer to track gaps without breaking workloads.

7. **Secret placeholder + init container pattern** — for config files that need passwords at runtime (ProxySQL, Orchestrator), the ConfigMap stores `__PLACEHOLDER__` tokens, never plaintext. An init container reads the real password from a Secret via `env.valueFrom.secretKeyRef` and fills it in with `sed`. This keeps secrets out of Git while leaving config templates version-controlled.

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

### kubectl (no local install — use SSH)

```bash
# kubectl is NOT installed on the Windows dev machine.
# All kubectl commands go through node-01 via SSH:
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl get pods -A"
ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl auth can-i get pods --as=developer -n app-layer"

# For frequent use, alias in .bashrc:
# alias k='ssh k3s-node-01 "sudo /usr/local/bin/k3s kubectl'
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
# Use daocloud mirror: docker.m.daocloud.io/library/golang:1.23-alpine
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

## Common Pitfalls

### StatefulSet + SecurityContext file permission trap

When an init container runs as **root** (default) and generates files for a main container that runs as **non-root** (SecurityContext `runAsUser`), the generated files inherit the init container's ownership and default umask (644 = no group write). Even with pod-level `fsGroup`, the file's group write bit must be set explicitly.

**Symptom**: StatefulSet pods crash with `Permission denied` writing to a volume that `fsGroup` should have granted access to.

**Fix**: Add `chmod g+w <file>` to the init container script after generating the file. See `k8s/data-layer/sentinel-statefulset.yaml:98`.

### FluxCD reconciliation when pods are unhealthy

FluxCD KustomizeController runs health checks before reconciling. If all pods of a resource are CrashLoopBackOff, the health check may fail and FluxCD won't reconcile — even if the StatefulSet/Deployment spec in Git has already been updated with the fix.

**Workaround**: After pushing a fix commit, manually delete the failing pods. The StatefulSet controller re-creates them with the updated template (already synced by FluxCD to the cluster, just not rolled out to existing pods).
