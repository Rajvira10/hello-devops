#!/usr/bin/env bash
#
# k8s-up.sh — create a local kind cluster and deploy hello-devops to it.
#
# Idempotent: safe to re-run. Steps:
#   1. kind cluster "hello-devops" (1 control plane + 2 workers)
#   2. metrics-server (needed by the HPA)
#   3. Traefik ingress controller (Helm)
#   4. build the app image and load it into the kind nodes
#   5. create the app Secret with a random value (never committed)
#   6. kubectl apply -k k8s/overlays/kind and wait for the rollout
#
# Requires: docker, kind, kubectl, helm, openssl.
# Usage: scripts/k8s-up.sh [IMAGE_TAG]      (default tag: 0.1.0)

set -euo pipefail

CLUSTER=hello-devops
CONTEXT="kind-${CLUSTER}"
NAMESPACE=hello-devops
TAG=${1:-0.1.0}
IMAGE="hello-devops:${TAG}"
METRICS_SERVER_VERSION=v0.9.1
TRAEFIK_CHART_VERSION=42.3.1
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
k() { kubectl --context "$CONTEXT" "$@"; }

for cmd in docker kind kubectl helm openssl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

log "1/6 kind cluster '${CLUSTER}'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster already exists"
else
  kind create cluster --config "$ROOT/k8s/kind/cluster.yaml" --wait 120s
fi

log "2/6 metrics-server ${METRICS_SERVER_VERSION}"
k apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# kind kubelets use self-signed serving certs; this flag is for local clusters only.
if ! k -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  k -n kube-system patch deploy metrics-server --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
k -n kube-system rollout status deploy/metrics-server --timeout=120s

log "3/6 Traefik ingress controller (chart ${TRAEFIK_CHART_VERSION})"
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null
helm upgrade --install traefik traefik/traefik --kube-context "$CONTEXT" \
  --namespace traefik --create-namespace --version "$TRAEFIK_CHART_VERSION" \
  -f "$ROOT/k8s/kind/traefik-values.yaml" --wait --timeout 180s

log "4/6 build and load image ${IMAGE}"
docker build -t "$IMAGE" --build-arg VERSION="$TAG" \
  --build-arg REVISION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROOT"
kind load docker-image "$IMAGE" --name "$CLUSTER"

log "5/6 namespace + secret"
k apply -f "$ROOT/k8s/base/namespace.yaml"
if k -n "$NAMESPACE" get secret hello-devops-secrets >/dev/null 2>&1; then
  echo "secret already exists (not rotated)"
else
  k -n "$NAMESPACE" create secret generic hello-devops-secrets \
    --from-literal=ADMIN_TOKEN="$(openssl rand -hex 24)"
fi

log "6/6 deploy"
k apply -k "$ROOT/k8s/overlays/kind"
if [[ "$TAG" != "0.1.0" ]]; then
  k -n "$NAMESPACE" set image deployment/hello-devops app="$IMAGE"
fi
k -n "$NAMESPACE" rollout status deployment/hello-devops --timeout=180s
k -n "$NAMESPACE" get pods,svc,ingress,hpa -o wide

cat <<EOF

Done. Try:
  curl -s http://hello-devops.localhost:8088/          # via Traefik ingress
  kubectl --context $CONTEXT -n $NAMESPACE port-forward svc/hello-devops 8081:80   # alternative
EOF
