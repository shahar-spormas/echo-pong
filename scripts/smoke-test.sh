#!/usr/bin/env bash
# End-to-end proof for issues #4, #5, #6 and #12: build state to serving
# traffic, asserted rather than eyeballed.
#
# The same script runs on a laptop and in .github/workflows/ci.yml. Nothing
# is verified in CI that you cannot run here, and nothing here goes unverified
# in CI, which is the only way a "repeatable local test path" stays true.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENT="${DEPLOYMENT:-ping-pong}"
SERVICE="${SERVICE:-ping-pong}"
SELECTOR="${SELECTOR:-app.kubernetes.io/name=ping-pong}"
SECRET_NAME="${SECRET_NAME:-ping-pong-secret}"
SECRET_FILE="${SECRET_FILE:-$ROOT_DIR/secrets/token}"
CLUSTER_NAME="${CLUSTER_NAME:-echo-pong-k8s}"

INGRESS_HOSTNAME="${INGRESS_HOSTNAME:-ping-pong.local}"
INGRESS_ADDR="${INGRESS_ADDR:-http://localhost}"

# Namespace for the blocked-by-policy probe. Deliberately not the app's, and
# deliberately unlabelled, so the NetworkPolicy has no reason to allow it.
PROBE_NS="${PROBE_NS:-netpol-probe}"
PROBE_POD="${PROBE_POD:-netpol-probe}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.11.1}"

# Off by default: pull-request builds have nothing in the registry yet and load
# the image with `kind load`, where asserting a registry pull would be a lie.
ASSERT_REGISTRY_PULL="${ASSERT_REGISTRY_PULL:-0}"
REGISTRY_PREFIX="${REGISTRY_PREFIX:-ghcr.io/}"

# Names the image to test instead of the one in k8s/deployment.yaml, whose tag
# is an already published release. CI points this at the build for the current
# commit, so a run that failed to side-load cannot pull the old one and pass.
IMAGE_OVERRIDE="${IMAGE_OVERRIDE:-}"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS  $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $*"; SKIP=$((SKIP + 1)); }
info() { echo "        $*"; }

MANIFEST_DIR="$ROOT_DIR/k8s"
RENDERED_DIR=""

cleanup() {
  kubectl delete namespace "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  [[ -n "$RENDERED_DIR" ]] && rm -rf "$RENDERED_DIR"
  return 0
}
trap cleanup EXIT

# Runs curl inside the probe pod and echoes "<exit_code> <http_code>". A blocked
# connection is the interesting case: a NetworkPolicy DROP makes curl hang until
# --max-time and exit 28, where a refused connection would exit 7. Asserting on
# "not 200" would pass for a broken cluster, so both fields are returned.
probe_curl() {
  local url="$1" rc out
  set +e
  out="$(kubectl -n "$PROBE_NS" exec "$PROBE_POD" -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)"
  rc=$?
  set -e
  echo "${rc} ${out:-000}"
}

# curl from the host, through the published ingress port.
ingress_curl() {
  local path="$1"
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Host: ${INGRESS_HOSTNAME}" "$@" "${INGRESS_ADDR}${path}" 2>/dev/null || echo "000"
}

ingress_body() {
  local path="$1"
  shift
  curl -s --max-time 10 -H "Host: ${INGRESS_HOSTNAME}" "$@" \
    "${INGRESS_ADDR}${path}" 2>/dev/null || true
}

echo "0. Preflight"
for BIN in kubectl kind; do
  command -v "$BIN" >/dev/null 2>&1 || { echo "$BIN not on PATH." >&2; exit 1; }
done

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "cluster $CLUSTER_NAME missing, building it"
  "$ROOT_DIR/scripts/cluster-up.sh"
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

if ! kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
  echo "No ingress controller. Run ./scripts/cluster-up.sh first." >&2
  exit 1
fi
info "context kind-${CLUSTER_NAME}, node arch $(kubectl get nodes \
  -o jsonpath='{.items[0].status.nodeInfo.architecture}')"

# The token never enters git: secrets/ is gitignored, and CI generates a
# throwaway one on every run.
if [[ ! -f "$SECRET_FILE" ]]; then
  mkdir -p "$(dirname "$SECRET_FILE")"
  openssl rand -hex 16 > "$SECRET_FILE"
  info "generated a test token at $SECRET_FILE"
fi
TOKEN="$(tr -d '[:space:]' < "$SECRET_FILE")"

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-file=token="$SECRET_FILE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Rendered to a temp directory rather than patched after applying, so there is
# one rollout to wait on rather than two racing each other.
if [[ -n "$IMAGE_OVERRIDE" ]]; then
  RENDERED_DIR="$(mktemp -d)"
  cp "$ROOT_DIR"/k8s/*.yaml "$RENDERED_DIR/"
  sed -E "s|^([[:space:]]+image:[[:space:]]+).*$|\1${IMAGE_OVERRIDE}|" \
    "$ROOT_DIR/k8s/deployment.yaml" > "$RENDERED_DIR/deployment.yaml"
  grep -q "image: ${IMAGE_OVERRIDE}$" "$RENDERED_DIR/deployment.yaml" \
    || { echo "could not substitute the image into deployment.yaml" >&2; exit 1; }
  MANIFEST_DIR="$RENDERED_DIR"
  info "testing $IMAGE_OVERRIDE in place of the image in k8s/deployment.yaml"
fi

kubectl -n "$NAMESPACE" apply -f "$MANIFEST_DIR/" >/dev/null
kubectl -n "$NAMESPACE" rollout status "deploy/$DEPLOYMENT" --timeout=300s >/dev/null
info "deployment rolled out"

kubectl create namespace "$PROBE_NS" --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
kubectl -n "$PROBE_NS" delete pod "$PROBE_POD" --ignore-not-found >/dev/null 2>&1
kubectl -n "$PROBE_NS" run "$PROBE_POD" --image="$PROBE_IMAGE" --restart=Never \
  --command -- sleep 3600 >/dev/null
kubectl -n "$PROBE_NS" wait --for=condition=Ready "pod/$PROBE_POD" --timeout=120s >/dev/null

echo
echo "1. Is the app kept off the public path?"
# The claim in issue #4 is not "an Ingress exists", it is "nothing else is a way
# in". A NodePort added later would satisfy the first and break the second.
EXPOSED="$(kubectl -n "$NAMESPACE" get svc -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.spec.type} {end}' 2>/dev/null || true)"
if [[ -z "$EXPOSED" ]]; then
  fail "no Service selects $SELECTOR"
elif [[ "$EXPOSED" == *NodePort* || "$EXPOSED" == *LoadBalancer* ]]; then
  fail "a Service publishes the pods directly: $EXPOSED"
else
  pass "ClusterIP only: $EXPOSED"
fi

echo
echo "2. Does traffic reach the app through the ingress?"
CODE="$(ingress_curl /health)"
if [[ "$CODE" == "200" ]]; then
  pass "/health returned 200 via ${INGRESS_ADDR} (Host: ${INGRESS_HOSTNAME})"
else
  fail "/health returned ${CODE} via the ingress, expected 200"
fi

CODE="$(ingress_curl /)"
[[ "$CODE" == "200" ]] && pass "/ returned 200" || fail "/ returned ${CODE}"

echo
echo "3. Is the mounted secret actually enforcing auth?"
# This is the real test of the #5 wiring. A 401 without a token and a 200 with
# it can only both happen if the process read the file from the path the
# ConfigMap gave it, so it proves the ConfigMap and Secret plumbing end to end.
for EP in /ping /pong; do
  CODE="$(ingress_curl "$EP")"
  if [[ "$CODE" == "401" ]]; then
    pass "${EP} without a token returned 401"
  else
    fail "${EP} without a token returned ${CODE}, expected 401"
  fi
done

CODE="$(ingress_curl /ping -H "Authorization: Bearer ${TOKEN}")"
BODY="$(ingress_body /ping -H "Authorization: Bearer ${TOKEN}")"
if [[ "$CODE" == "200" && "$BODY" == *'"message":"pong"'* ]]; then
  pass "/ping with the token returned 200 and answered pong"
else
  fail "/ping with the token returned ${CODE}: ${BODY:0:120}"
fi

CODE="$(ingress_curl /pong -H "Authorization: Bearer ${TOKEN}")"
BODY="$(ingress_body /pong -H "Authorization: Bearer ${TOKEN}")"
if [[ "$CODE" == "200" && "$BODY" == *'"message":"ping"'* ]]; then
  pass "/pong with the token returned 200 and answered ping"
else
  fail "/pong with the token returned ${CODE}: ${BODY:0:120}"
fi

CODE="$(ingress_curl /ping -H "Authorization: Bearer not-the-token")"
[[ "$CODE" == "401" ]] \
  && pass "/ping with a wrong token returned 401" \
  || fail "/ping with a wrong token returned ${CODE}, expected 401"

echo
echo "4. Is runtime config external to the image?"
INLINE_ENV="$(kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null || true)"
FROM_CM="$(kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}' 2>/dev/null || true)"
if [[ -n "$INLINE_ENV" ]]; then
  fail "the container still hardcodes env in the Deployment: $INLINE_ENV"
elif [[ -z "$FROM_CM" ]]; then
  fail "no configMapRef on the container; config is baked into the image"
else
  pass "config comes from ConfigMap/${FROM_CM}, so a change needs no rebuild"
fi

echo
echo "5. Where did the running image come from?"
IMAGE_IDS="$(kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}' \
  2>/dev/null | sort -u)"
info "$(echo "$IMAGE_IDS" | tr '\n' ' ')"
if [[ "$ASSERT_REGISTRY_PULL" != "1" ]]; then
  skip "ASSERT_REGISTRY_PULL is not 1; not claiming a registry pull"
elif echo "$IMAGE_IDS" | grep -q "^${REGISTRY_PREFIX}"; then
  pass "pulled from ${REGISTRY_PREFIX}, resolved to a digest"
else
  # A `kind load`-ed image reports docker.io/library/import-<date>, which is the
  # tell that nothing was fetched from a registry.
  fail "not a registry pull; the image was side-loaded into the node"
fi

NODE_ARCH="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
RUNNING="$(kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
  --field-selector status.phase=Running --no-headers 2>/dev/null | grep -c . || true)"
if [[ "$RUNNING" -gt 0 ]]; then
  pass "$RUNNING pods running on ${NODE_ARCH}, so the manifest resolved for this arch"
else
  fail "no running pods on ${NODE_ARCH}; the image may lack this architecture"
fi

echo
echo "6. Is the NetworkPolicy actually enforced?"
POD_IP="$(kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
  --field-selector status.phase=Running \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
if [[ -z "$POD_IP" ]]; then
  skip "no running pod IP to aim at"
else
  # Negative control first. Without it, every later assertion is satisfied by a
  # cluster where the probe pod simply cannot reach anything, and a policy that
  # does nothing looks identical to one that works. kindnet, the default CNI,
  # ignores NetworkPolicy entirely and would pass a one-sided test.
  kubectl -n "$NAMESPACE" delete -f "$ROOT_DIR/k8s/networkpolicy.yaml" >/dev/null 2>&1 || true
  sleep 3
  read -r RC CODE <<<"$(probe_curl "http://${POD_IP}:8080/health")"
  if [[ "$RC" == "0" && "$CODE" == "200" ]]; then
    pass "control: with no policy, ${PROBE_NS} reached the pod IP directly (200)"
  else
    fail "control: ${PROBE_NS} could not reach ${POD_IP} even with no policy (curl ${RC}, http ${CODE}); the rest of this check would be meaningless"
  fi

  kubectl -n "$NAMESPACE" apply -f "$ROOT_DIR/k8s/networkpolicy.yaml" >/dev/null
  sleep 5
  read -r RC CODE <<<"$(probe_curl "http://${POD_IP}:8080/health")"
  if [[ "$RC" == "28" ]]; then
    pass "with the policy, the same request timed out (curl 28, dropped)"
  elif [[ "$RC" == "7" ]]; then
    pass "with the policy, the same request was refused (curl 7)"
  else
    fail "the policy did not block ${PROBE_NS}: curl ${RC}, http ${CODE}"
  fi

  CODE="$(ingress_curl /health)"
  [[ "$CODE" == "200" ]] \
    && pass "the ingress path still returns 200, so the allow rule works" \
    || fail "the policy also blocked the ingress: /health returned ${CODE}"

  # Kubelet probes come from the node, not a pod, and nothing in the policy
  # allows them. If the CNI applies policy to host-to-pod traffic, readiness
  # collapses here and the whole Deployment silently leaves the Service.
  sleep 10
  NOT_READY="$(kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    | grep -v ' True$' | grep -c . || true)"
  if [[ "$NOT_READY" -eq 0 ]]; then
    pass "all pods still Ready, so kubelet probes survived the default-deny"
  else
    fail "$NOT_READY pods went NotReady under the policy; probes are being dropped"
    info "add an ipBlock allow for the node CIDR to k8s/networkpolicy.yaml"
  fi
fi

echo
echo "passed $PASS, failed $FAIL, skipped $SKIP"
if [[ "$FAIL" -eq 0 ]]; then
  echo
  echo "Rollout availability is a separate claim: ./scripts/verify-zdd.sh"
fi
[[ "$FAIL" -eq 0 ]]
