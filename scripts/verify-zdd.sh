#!/usr/bin/env bash
# Proves the zero-downtime claim in issue #3 instead of asserting it.
#
# A broken preStop hook is indistinguishable from a working one at rest: the
# kubelet emits an event and lets termination continue, so the manifest still
# looks correct. These four checks are the only way to tell the difference.

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
DEPLOYMENT="${DEPLOYMENT:-ping-pong}"
SELECTOR="${SELECTOR:-app.kubernetes.io/name=ping-pong}"
PROBE_POD="${PROBE_POD:-zdd-probe}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.11.1}"
# Check 4 probes through the ingress controller rather than straight at the
# Service. k8s/networkpolicy.yaml now permits only the ingress-nginx namespace
# to reach the pods, so a probe pod in this namespace is blocked by design.
INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
INGRESS_SVC="${INGRESS_SVC:-ingress-nginx-controller}"
INGRESS_HOSTNAME="${INGRESS_HOSTNAME:-ping-pong.local}"
# The hook sleeps 10s. Anything at or above this proves it ran; a hook that
# silently failed returns in about 1s.
MIN_DRAIN_SECONDS="${MIN_DRAIN_SECONDS:-8}"
# lifecycle.preStop.sleep: beta and on by default in 1.30, GA in 1.32.
MIN_KUBELET_MINOR="${MIN_KUBELET_MINOR:-30}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib/checks.sh
. "$ROOT_DIR/scripts/lib/checks.sh"

cleanup() {
  kubectl -n "$NAMESPACE" delete pod "$PROBE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" >/dev/null 2>&1; then
  echo "Deployment $DEPLOYMENT not found in namespace $NAMESPACE." >&2
  echo "Run ./scripts/smoke-test.sh first; it creates the Secret and applies k8s/." >&2
  exit 1
fi

# Preflight, silent unless it fails. The sleep action is executed by the kubelet,
# so every node that could host this pod needs to understand it, not just the API
# server. Beta and on by default from 1.30, GA in 1.32. An older kubelet ignores
# the hook without failing anything, which is the whole reason this script exists.
OLD_NODES=""
for KUBELET_VERSION in $(kubectl get nodes \
    -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}' 2>/dev/null); do
  V="${KUBELET_VERSION#v}"
  MAJOR="${V%%.*}"
  MINOR="${V#*.}"; MINOR="${MINOR%%.*}"; MINOR="${MINOR//[!0-9]/}"
  if (( MAJOR < 1 || (MAJOR == 1 && MINOR < MIN_KUBELET_MINOR) )); then
    OLD_NODES="$OLD_NODES $KUBELET_VERSION"
  fi
done
if [[ -n "$OLD_NODES" ]]; then
  echo "Cluster too old for lifecycle.preStop.sleep (needs >= v1.${MIN_KUBELET_MINOR})." >&2
  echo "Nodes below that:$OLD_NODES" >&2
  echo "An older kubelet ignores the hook silently. See docs/deployment-design.md" >&2
  echo "for the static-sleep-binary fallback." >&2
  exit 1
fi

check_title "Zero-downtime :: rollout availability and connection draining"

check_section "1. Did the API server keep the preStop field?"
# An unsupported field can be dropped rather than rejected, so a successful
# apply proves nothing on its own. Reading it back does.
PRESTOP="$(kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop}' 2>/dev/null || true)"
if [[ -z "$PRESTOP" ]]; then
  fail "no preStop hook on the deployment: the field was dropped or never set"
elif [[ "$PRESTOP" != *sleep* ]]; then
  fail "preStop is set but is not a sleep action: $PRESTOP"
else
  pass "preStop retained: $PRESTOP"
fi

check_section "2. Does termination actually wait?"
POD="$(kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
  --field-selector status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$POD" ]]; then
  fail "no running pod to delete; cannot time a termination"
else
  # kubectl delete waits for the object to disappear by default, so wall-clock
  # time here is the full preStop plus SIGTERM path.
  START="$(date +%s)"
  kubectl -n "$NAMESPACE" delete pod "$POD" >/dev/null
  ELAPSED=$(( $(date +%s) - START ))
  if (( ELAPSED >= MIN_DRAIN_SECONDS )); then
    pass "deleting $POD took ${ELAPSED}s (hook ran)"
  else
    fail "deleting $POD took ${ELAPSED}s, expected >= ${MIN_DRAIN_SECONDS}s (hook did not run)"
  fi
  kubectl -n "$NAMESPACE" rollout status "deploy/$DEPLOYMENT" --timeout=120s >/dev/null
fi

check_section "3. Did the kubelet complain?"
EVENTS="$(kubectl -n "$NAMESPACE" get events \
  --field-selector reason=FailedPreStopHook \
  --no-headers 2>/dev/null || true)"
if [[ -z "$EVENTS" ]]; then
  pass "no FailedPreStopHook events"
else
  fail "FailedPreStopHook events present:"
  echo "$EVENTS" | while IFS= read -r line; do info "$line"; done
fi

check_section "4. Does traffic survive a rollout?"
if ! kubectl -n "$INGRESS_NS" get svc "$INGRESS_SVC" >/dev/null 2>&1; then
  # A port-forward is not a substitute. It connects straight to one pod and
  # never consults EndpointSlices or kube-proxy, so it cannot exercise the
  # endpoint-removal race that the preStop hook exists to mitigate.
  skip "Service $INGRESS_SVC not found in $INGRESS_NS; run ./scripts/cluster-up.sh"
else
  kubectl -n "$NAMESPACE" delete pod "$PROBE_POD" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$NAMESPACE" run "$PROBE_POD" \
    --image="$PROBE_IMAGE" --restart=Never --command -- \
    sh -c "while true; do
             code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
                     -H 'Host: ${INGRESS_HOSTNAME}' \
                     http://${INGRESS_SVC}.${INGRESS_NS}.svc.cluster.local/health || true)
             echo \"\${code:-000}\"
             sleep 0.2
           done" >/dev/null

  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$PROBE_POD" --timeout=60s >/dev/null
  sleep 3

  kubectl -n "$NAMESPACE" rollout restart "deploy/$DEPLOYMENT" >/dev/null
  kubectl -n "$NAMESPACE" rollout status "deploy/$DEPLOYMENT" --timeout=300s >/dev/null
  sleep 3

  RESULTS="$(kubectl -n "$NAMESPACE" logs "$PROBE_POD" 2>/dev/null || true)"
  TOTAL="$(echo "$RESULTS" | grep -c . || true)"
  BAD="$(echo "$RESULTS" | grep -vc '^200$' || true)"

  info "$TOTAL requests during the rollout"
  echo "$RESULTS" | sort | uniq -c | while IFS= read -r line; do info "$line"; done

  if [[ "$TOTAL" -eq 0 ]]; then
    fail "probe recorded no requests"
  elif [[ "$BAD" -eq 0 ]]; then
    pass "zero non-200 responses across the rollout"
  else
    fail "$BAD of $TOTAL requests did not return 200"
  fi
fi

check_summary
