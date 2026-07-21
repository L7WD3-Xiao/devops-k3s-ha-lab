#!/usr/bin/env bash
# build-push.sh — Build and push shortlink app image to Alibaba Cloud ACR
#
# Usage:
#   ./scripts/build-push.sh v1           # build and push version v1
#   ./scripts/build-push.sh v1 --no-cache  # build without cache
#   ./scripts/build-push.sh latest       # build and push as latest
#
# Prerequisites:
#   - Docker installed locally
#   - ACR Personal Edition activated
#   - ACR credentials set in ansible/group_vars/all.yml or environment vars

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
ACR_REGISTRY="${ACR_REGISTRY:-registry-vpc.cn-hangzhou.aliyuncs.com}"
# For push from local machine, use public domain (VPC domain only works from ECS)
ACR_REGISTRY_PUBLIC="${ACR_REGISTRY_PUBLIC:-registry.cn-hangzhou.aliyuncs.com}"
ACR_NAMESPACE="${ACR_NAMESPACE:-shortlink}"
ACR_REPOSITORY="${ACR_REPOSITORY:-shortlink-app}"

# ── Argument parsing ──────────────────────────────────────────
TAG="${1:-latest}"
CACHE_FLAG=""
if [[ "${2:-}" == "--no-cache" ]]; then
  CACHE_FLAG="--no-cache"
fi

# ── Validate ──────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "Error: Docker not found. Install Docker Desktop first."
  exit 1
fi

# ── Login to ACR ──────────────────────────────────────────────
echo "━━━ Logging in to ACR (${ACR_REGISTRY_PUBLIC}) ━━━"
docker login "${ACR_REGISTRY_PUBLIC}"

# ── Build ─────────────────────────────────────────────────────
IMAGE_LOCAL="shortlink-app:${TAG}"
IMAGE_REMOTE="${ACR_REGISTRY_PUBLIC}/${ACR_NAMESPACE}/${ACR_REPOSITORY}:${TAG}"

echo ""
echo "━━━ Building image: ${IMAGE_LOCAL} ━━━"
docker build ${CACHE_FLAG} -t "${IMAGE_LOCAL}" -f Dockerfile .

# ── Tag for ACR ───────────────────────────────────────────────
echo ""
echo "━━━ Tagging for ACR ━━━"
echo "  Local:  ${IMAGE_LOCAL}"
echo "  Remote: ${IMAGE_REMOTE}"
docker tag "${IMAGE_LOCAL}" "${IMAGE_REMOTE}"

# ── Push ──────────────────────────────────────────────────────
echo ""
echo "━━━ Pushing to ACR ━━━"
docker push "${IMAGE_REMOTE}"

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
echo "   kubectl apply -f k8s/app-layer/shortlink-deployment.yaml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
