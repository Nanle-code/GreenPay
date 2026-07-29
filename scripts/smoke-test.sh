#!/usr/bin/env bash
# scripts/smoke-test.sh
# Post-deploy smoke tests against a single backend/frontend endpoint.
#
# Used by scripts/blue-green-deploy.sh to gate a cutover: run this against
# the *new* color's dedicated Service (backend-svc-green, frontend-svc-green)
# before it is allowed to receive production traffic, and again against the
# stable Service after cutover as the post-cutover health window.
#
# Usage: smoke-test.sh <backend-base-url> [frontend-base-url]
# Example: smoke-test.sh http://backend-svc-green:4000 http://frontend-svc-green:3000

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}✓${NC} $*"; }
log_fail() { echo -e "${RED}✗${NC} $*"; }

BACKEND_URL="${1:-}"
FRONTEND_URL="${2:-}"

if [[ -z "$BACKEND_URL" ]]; then
  echo "Usage: $0 <backend-base-url> [frontend-base-url]"
  exit 2
fi

CURL_OPTS=(--silent --show-error --max-time 5 --fail)
failures=0

check() {
  local description="$1"
  local url="$2"
  if curl "${CURL_OPTS[@]}" "$url" > /dev/null; then
    log_ok "$description ($url)"
  else
    log_fail "$description ($url)"
    failures=$((failures + 1))
  fi
}

# Liveness — process is up.
check "backend liveness"  "${BACKEND_URL}/health"
# Readiness — database is reachable. This is the check that actually matters
# for a DR cutover: a backend that boots fine against an unreachable/still-
# recovering database must not receive traffic.
check "backend readiness (DB reachable)" "${BACKEND_URL}/health/ready"
# A couple of representative, side-effect-free read endpoints.
check "GET /api/projects"    "${BACKEND_URL}/api/projects"
check "GET /api/leaderboard" "${BACKEND_URL}/api/leaderboard"
check "GET /api/stats/global" "${BACKEND_URL}/api/stats/global"

if [[ -n "$FRONTEND_URL" ]]; then
  check "frontend root" "${FRONTEND_URL}/"
fi

if [[ "$failures" -gt 0 ]]; then
  log_fail "$failures smoke test(s) failed"
  exit 1
fi

log_ok "all smoke tests passed"
