#!/usr/bin/env bash
# scripts/blue-green-deploy.sh
#
# Zero-downtime blue/green rollout for a single Deployment (backend or
# frontend), built directly on top of the existing k8s/ manifests — no
# Argo Rollouts or other CRD is required.
#
# How it works:
#   1. Read the *active* color off the stable Service's selector
#      (backend-svc / frontend-svc — see k8s/backend.yaml, k8s/frontend.yaml).
#   2. Clone the active color's Deployment, swap in the new image, and apply
#      it as the *other* color (this is what "using the existing k8s/
#      manifests as a base" means here — the green Deployment is derived
#      from whatever blue currently looks like, not a separately maintained
#      YAML file).
#   3. Wait for the new color's rollout + readiness.
#   4. Run smoke tests directly against the new color's dedicated Service
#      (backend-svc-green etc.) — this traffic never goes through the
#      stable Service, so a bad rollout never reaches production.
#   5. Cut over: patch the stable Service's selector.color to the new color.
#      This is the only moment production traffic moves, and it is instant.
#   6. Monitor the stable Service through the smoke tests for a post-cutover
#      window. On any failure, roll back automatically by flipping the
#      selector back and scaling the bad color to 0.
#   7. On success, scale the old color down to 0 (kept around, not deleted,
#      for a fast manual rollback — see docs/runbooks/dr-failover.md).
#
# Usage:
#   blue-green-deploy.sh <backend|frontend> <image> [namespace] [context]
#
# Env overrides:
#   SMOKE_TEST_SCRIPT       path to smoke-test.sh (default: alongside this script)
#   ROLLOUT_TIMEOUT         kubectl rollout status timeout (default: 120s)
#   POST_CUTOVER_WINDOW_S   seconds to monitor after cutover (default: 120)
#   POST_CUTOVER_INTERVAL_S seconds between post-cutover checks (default: 10)
#   POST_CUTOVER_FAILURE_THRESHOLD  consecutive failures that trigger rollback (default: 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_TEST_SCRIPT="${SMOKE_TEST_SCRIPT:-$SCRIPT_DIR/smoke-test.sh}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"
POST_CUTOVER_WINDOW_S="${POST_CUTOVER_WINDOW_S:-120}"
POST_CUTOVER_INTERVAL_S="${POST_CUTOVER_INTERVAL_S:-10}"
POST_CUTOVER_FAILURE_THRESHOLD="${POST_CUTOVER_FAILURE_THRESHOLD:-2}"

SERVICE_NAME="${1:-}"
NEW_IMAGE="${2:-}"
NAMESPACE="${3:-greenpay}"
KCONTEXT="${4:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${YELLOW}ℹ${NC} $*"; }
log_ok()    { echo -e "${GREEN}✓${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }

if [[ -z "$SERVICE_NAME" || -z "$NEW_IMAGE" ]]; then
  echo "Usage: $0 <backend|frontend> <image> [namespace] [context]"
  exit 2
fi
if [[ "$SERVICE_NAME" != "backend" && "$SERVICE_NAME" != "frontend" ]]; then
  log_error "service must be 'backend' or 'frontend', got '$SERVICE_NAME'"
  exit 2
fi

KUBECTL=(kubectl -n "$NAMESPACE")
if [[ -n "$KCONTEXT" ]]; then
  KUBECTL=(kubectl --context "$KCONTEXT" -n "$NAMESPACE")
fi

PORT=4000
[[ "$SERVICE_NAME" == "frontend" ]] && PORT=3000

STABLE_SVC="${SERVICE_NAME}-svc"

active_color="$("${KUBECTL[@]}" get svc "$STABLE_SVC" -o jsonpath='{.spec.selector.color}')"
if [[ "$active_color" != "blue" && "$active_color" != "green" ]]; then
  log_error "could not determine active color from $STABLE_SVC (got '$active_color')"
  exit 1
fi
target_color="green"
[[ "$active_color" == "green" ]] && target_color="blue"

log_info "service=$SERVICE_NAME active=$active_color target=$target_color image=$NEW_IMAGE"

active_deploy="$SERVICE_NAME"
[[ "$active_color" != "blue" ]] && active_deploy="${SERVICE_NAME}-${active_color}"
target_deploy="${SERVICE_NAME}-${target_color}"
[[ "$target_color" == "blue" ]] && target_deploy="$SERVICE_NAME"

log_info "cloning $active_deploy -> $target_deploy with image=$NEW_IMAGE"

"${KUBECTL[@]}" get deployment "$active_deploy" -o json \
  | jq --arg name "$target_deploy" \
       --arg color "$target_color" \
       --arg image "$NEW_IMAGE" '
    .metadata.name = $name
    | .metadata.labels.color = $color
    | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
          .metadata.generation, .metadata.selfLink, .status)
    | .spec.selector.matchLabels.color = $color
    | .spec.template.metadata.labels.color = $color
    | .spec.template.spec.containers[0].image = $image
  ' > /tmp/"${target_deploy}".json

"${KUBECTL[@]}" apply -f /tmp/"${target_deploy}".json
"${KUBECTL[@]}" rollout status deployment "$target_deploy" --timeout "$ROLLOUT_TIMEOUT"

target_svc="${SERVICE_NAME}-svc-${target_color}"
target_url="http://${target_svc}.${NAMESPACE}.svc.cluster.local:${PORT}"

log_info "running smoke tests against new color: $target_url"
if ! "$SMOKE_TEST_SCRIPT" "$target_url"; then
  log_error "smoke tests failed against $target_deploy — aborting cutover, scaling it down"
  "${KUBECTL[@]}" scale deployment "$target_deploy" --replicas=0
  exit 1
fi
log_ok "smoke tests passed against $target_deploy"

log_info "cutting over $STABLE_SVC: color $active_color -> $target_color"
"${KUBECTL[@]}" patch svc "$STABLE_SVC" -p "{\"spec\":{\"selector\":{\"color\":\"$target_color\"}}}"
log_ok "cutover complete — $STABLE_SVC now routes to $target_deploy"

stable_url="http://${STABLE_SVC}.${NAMESPACE}.svc.cluster.local:${PORT}"
log_info "monitoring $stable_url for ${POST_CUTOVER_WINDOW_S}s (rollback on $POST_CUTOVER_FAILURE_THRESHOLD consecutive failures)"

elapsed=0
consecutive_failures=0
while [[ "$elapsed" -lt "$POST_CUTOVER_WINDOW_S" ]]; do
  if "$SMOKE_TEST_SCRIPT" "$stable_url" > /tmp/smoke-post-cutover.log 2>&1; then
    consecutive_failures=0
  else
    consecutive_failures=$((consecutive_failures + 1))
    log_error "post-cutover check failed ($consecutive_failures/$POST_CUTOVER_FAILURE_THRESHOLD)"
    cat /tmp/smoke-post-cutover.log >&2

    if [[ "$consecutive_failures" -ge "$POST_CUTOVER_FAILURE_THRESHOLD" ]]; then
      log_error "post-cutover health check failed — automatic rollback to $active_color"
      "${KUBECTL[@]}" patch svc "$STABLE_SVC" -p "{\"spec\":{\"selector\":{\"color\":\"$active_color\"}}}"
      "${KUBECTL[@]}" scale deployment "$target_deploy" --replicas=0
      log_error "rolled back. $target_deploy scaled to 0. Investigate before retrying."
      exit 1
    fi
  fi
  sleep "$POST_CUTOVER_INTERVAL_S"
  elapsed=$((elapsed + POST_CUTOVER_INTERVAL_S))
done

log_ok "post-cutover window clean — scaling down old color $active_deploy"
"${KUBECTL[@]}" scale deployment "$active_deploy" --replicas=0
log_ok "blue/green deploy of $SERVICE_NAME complete: $target_color is now active, $active_color is scaled to 0"
