#!/usr/bin/env bash
# build-push.sh — Build and push shortlink app image to Alibaba Cloud ACR
#
# Supports both Docker (local) and nerdctl (on K3s nodes without Docker).
# Auto-detects which tool is available.
#
# When using nerdctl on a K3s node:
#   - Requires nerdctl + buildkitd installed
#   - Requires HTTP proxy (SSH reverse tunnel) for Go module downloads
#   - Uses daocloud mirror for Docker Hub images (auth.docker.io is blocked)
#   - Needs sudo for K3s containerd socket access
#
# Usage:
#   ./scripts/build-push.sh v1             # build and push version v1
#   ./scripts/build-push.sh v1 --no-cache  # build without cache
#   ./scripts/build-push.sh latest         # build and push as latest
#
# Prerequisites:
#   - Docker (local) OR nerdctl+buildkitd (on K3s node)
#   - ACR Personal Edition activated
#   - ACR credentials configured
#   - For nerdctl: buildkitd running with daocloud mirror config

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
# K3s pulls via VPC domain (free); local push uses public domain
ACR_REGISTRY="${ACR_REGISTRY:-crpi-vvz6iv4av6k8awep-vpc.cn-hangzhou.personal.cr.aliyuncs.com}"
ACR_REGISTRY_PUBLIC="${ACR_REGISTRY_PUBLIC:-crpi-vvz6iv4av6k8awep.cn-hangzhou.personal.cr.aliyuncs.com}"
ACR_NAMESPACE="${ACR_NAMESPACE:-shortlink123}"
ACR_REPOSITORY="${ACR_REPOSITORY:-shortlink-app}"
ACR_USERNAME="${ACR_USERNAME:-L7WD3-Xiao}"

# Daocloud mirror for Docker Hub (China — auth.docker.io is blocked)
DAOLOUD_PREFIX="docker.m.daocloud.io/library"

# ── Argument parsing ──────────────────────────────────────────
TAG="${1:-latest}"
CACHE_FLAG=""
if [[ "${2:-}" == "--no-cache" ]]; then
  CACHE_FLAG="--no-cache"
fi

# ── Detect container tool (Docker or nerdctl) ─────────────────
USE_NERDCTL=false
if command -v docker &>/dev/null; then
  CT="docker"
elif command -v nerdctl &>/dev/null || [ -x /usr/local/bin/nerdctl ]; then
  CT="nerdctl"
  USE_NERDCTL=true
  NERDCTL_BIN="$(command -v nerdctl 2>/dev/null || echo /usr/local/bin/nerdctl)"
  # nerdctl needs buildkitd running
  if ! pgrep -x buildkitd &>/dev/null; then
    echo "Starting buildkitd..."
    sudo systemctl start buildkitd 2>/dev/null || sudo buildkitd --config /etc/buildkit/buildkitd.toml &
    sleep 2
  fi
else
  echo "Error: Neither docker nor nerdctl found."
  echo "  Install Docker Desktop locally, or nerdctl+buildkitd on a K3s node."
  exit 1
fi

echo "Using: ${CT}"

# ── Prepare Dockerfile ────────────────────────────────────────
# On K3s nodes, Docker Hub's auth.docker.io is blocked.
# Use daocloud mirror URLs directly in a temporary Dockerfile.
DOCKERFILE="Dockerfile"
if $USE_NERDCTL; then
  DOCKERFILE="Dockerfile.daocloud"
  echo "Creating ${DOCKERFILE} with daocloud mirror URLs..."
  sed -e "s|FROM golang:|FROM ${DAOLOUD_PREFIX}/golang:|" \
      -e "s|FROM alpine:|FROM ${DAOLOUD_PREFIX}/alpine:|" \
      Dockerfile > "${DOCKERFILE}"
  echo "  Base images redirected to: ${DAOLOUD_PREFIX}"
fi

# ── Login to ACR ──────────────────────────────────────────────
echo "━━━ Logging in to ACR (${ACR_REGISTRY_PUBLIC}) ━━━"
if $USE_NERDCTL; then
  # nerdctl on K3s needs env vars + sudo for containerd socket
  export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock
  export CONTAINERD_NAMESPACE=k8s.io
  export BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock
  sudo -E env "PATH=/usr/local/bin:/usr/bin:/bin" \
       CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock \
       CONTAINERD_NAMESPACE=k8s.io \
       BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock \
       "${NERDCTL_BIN}" login --username "${ACR_USERNAME}" \
       "${ACR_REGISTRY_PUBLIC}" </dev/null
else
  ${CT} login "${ACR_REGISTRY_PUBLIC}"
fi

# ── Build ─────────────────────────────────────────────────────
IMAGE_REMOTE="${ACR_REGISTRY_PUBLIC}/${ACR_NAMESPACE}/${ACR_REPOSITORY}:${TAG}"

echo ""
echo "━━━ Building image: ${IMAGE_REMOTE} ━━━"
if $USE_NERDCTL; then
  sudo -E env "PATH=/usr/local/bin:/usr/bin:/bin" \
       CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock \
       CONTAINERD_NAMESPACE=k8s.io \
       BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock \
       "${NERDCTL_BIN}" build ${CACHE_FLAG} -t "${IMAGE_REMOTE}" -f "${DOCKERFILE}" .
else
  ${CT} build ${CACHE_FLAG} -t "${IMAGE_REMOTE}" -f "${DOCKERFILE}" .
fi

# ── Push ──────────────────────────────────────────────────────
echo ""
echo "━━━ Pushing to ACR ━━━"
if $USE_NERDCTL; then
  sudo -E env "PATH=/usr/local/bin:/usr/bin:/bin" \
       CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock \
       CONTAINERD_NAMESPACE=k8s.io \
       "${NERDCTL_BIN}" push "${IMAGE_REMOTE}"
else
  ${CT} push "${IMAGE_REMOTE}"
fi

# ── Cleanup ───────────────────────────────────────────────────
if $USE_NERDCTL && [ -f "${DOCKERFILE}" ] && [ "${DOCKERFILE}" != "Dockerfile" ]; then
  rm -f "${DOCKERFILE}"
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Build & push complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Remote image: ${IMAGE_REMOTE}"
echo ""
echo " K3s deployment image (VPC domain, free pull):"
echo "   ${ACR_REGISTRY}/${ACR_NAMESPACE}/${ACR_REPOSITORY}:${TAG}"
echo ""
echo " To deploy:"
echo "   kubectl apply -f k8s/app-layer/shortlink.yaml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
