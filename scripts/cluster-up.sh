#!/usr/bin/env bash
# Builds the local cluster the rest of the tooling assumes: Kind, plus a CNI
# that enforces NetworkPolicy, plus an ingress controller reachable from the
# host. Idempotent, and identical on a laptop and on a CI runner.
#
# Every version is pinned. An unpinned CNI or controller means the cluster
# drifts under you and a passing test yesterday says nothing about today.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-echo-pong-k8s}"
CLUSTER_CONFIG="${CLUSTER_CONFIG:-$ROOT_DIR/kind/cluster.yaml}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"
CALICO_INSTALLATION="${CALICO_INSTALLATION:-$ROOT_DIR/kind/calico-installation.yaml}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.15.1}"
# Set RECREATE=1 to tear down an existing cluster first. Off by default so
# repeated runs are cheap; CI always starts from nothing anyway.
RECREATE="${RECREATE:-0}"

CALICO_OPERATOR_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
INGRESS_NGINX_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

for BIN in docker kind kubectl; do
  command -v "$BIN" >/dev/null 2>&1 || { echo "$BIN not on PATH." >&2; exit 1; }
done

if ! docker info >/dev/null 2>&1; then
  echo "Cannot reach the Docker daemon. Start Docker and retry." >&2
  exit 1
fi

echo "1. Cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  if [[ "$RECREATE" == "1" ]]; then
    echo "   deleting existing cluster $CLUSTER_NAME"
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null
  else
    echo "   reusing existing cluster $CLUSTER_NAME (RECREATE=1 to rebuild)"
  fi
fi

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  # No --wait: the config disables the default CNI, so nodes cannot go Ready
  # until Calico is installed below and waiting here would always time out.
  if ! kind create cluster --name "$CLUSTER_NAME" --config "$CLUSTER_CONFIG"; then
    echo >&2
    echo "Cluster creation failed. If the error mentions binding port 80 or 443," >&2
    echo "something on the host already holds them; stop it, or edit the" >&2
    echo "extraPortMappings in $CLUSTER_CONFIG." >&2
    exit 1
  fi
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# The ingress-nginx kind manifest pins its controller to this label with a
# nodeSelector. Checked here because the failure mode otherwise is a Pending
# pod with no obvious cause, and the usual reason is a kubeadmConfigPatch
# written in the pre-v1beta4 map form, which this Kubernetes version ignores.
if ! kubectl get nodes -l ingress-ready=true --no-headers 2>/dev/null | grep -q .; then
  echo >&2
  echo "No node carries ingress-ready=true, so the ingress controller will never" >&2
  echo "schedule. Check the kubeadmConfigPatches in $CLUSTER_CONFIG." >&2
  exit 1
fi

echo
echo "2. Calico ${CALICO_VERSION}"
# Server-side apply: the operator bundle's CRDs are far larger than the 256KB
# ceiling on the last-applied-configuration annotation that a client-side apply
# would try to write.
kubectl apply --server-side -f "$CALICO_OPERATOR_URL" >/dev/null
# The bundle ships the CRDs alongside the operator, and a successful apply does
# not mean they are servable yet. Applying the Installation too early fails with
# "no matches for kind Installation", which reads like a missing manifest rather
# than a race.
#
# Existence is polled before waiting on the condition, because `kubectl wait`
# errors out immediately on an object it cannot find rather than waiting for one
# to appear.
for _ in $(seq 1 60); do
  kubectl get crd installations.operator.tigera.io >/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=condition=Established \
  crd/installations.operator.tigera.io --timeout=120s >/dev/null
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s
kubectl apply -f "$CALICO_INSTALLATION" >/dev/null

echo "   waiting for the operator to create calico-node"
for _ in $(seq 1 60); do
  if kubectl -n calico-system get ds calico-node >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl -n calico-system rollout status ds/calico-node --timeout=300s
kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
echo "   nodes Ready"

echo
echo "3. ingress-nginx ${INGRESS_NGINX_VERSION}"
kubectl apply -f "$INGRESS_NGINX_URL" >/dev/null
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s
# The controller serves traffic before its admission webhook has a certificate,
# and applying an Ingress in that window fails. Wait for the job that issues it.
kubectl -n ingress-nginx wait --for=condition=Complete job \
  -l app.kubernetes.io/component=admission-webhook --timeout=180s >/dev/null 2>&1 || true

echo
echo "Cluster ready."
kubectl get nodes -o wide
echo
echo "Next: ./scripts/smoke-test.sh"
