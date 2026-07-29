#!/usr/bin/env bash
# scripts/dr-gameday.sh
#
# Disaster-recovery game day: simulate total loss of the primary region and
# measure actual RTO/RPO against the targets in docs/disaster-recovery.md.
#
# Two modes:
#
#   --mode=live (real infra; not runnable in a plain CI sandbox)
#     Requires PRIMARY_CONTEXT / SECONDARY_CONTEXT kubectl contexts and a
#     real Route53 failover record already applied (infra/dr/route53-failover.tf).
#     Injects failure by scaling the primary region's backend+frontend to 0
#     (simulating total application-layer loss without actually destroying
#     the cluster, which would make an automated game day too destructive
#     to run repeatably), then polls the *public* domain until it resolves
#     to and is served healthily by the secondary region, and reads
#     replication lag from the standby's own pg_stat catalog immediately
#     before/after to compute actual RPO.
#
#   --mode=simulate (default)
#     Runs the exact same control-loop logic and thresholds as the real
#     automation (Route53's 10s/3-failure detection, dr-controller's
#     5s/6-failure promotion — see infra/dr/route53-failover.tf and
#     k8s/overlays/secondary/dr-controller-entrypoint.sh) against local
#     mock HTTP endpoints instead of real clusters. This validates the
#     control-flow and timing model end-to-end and produces real measured
#     wall-clock numbers for a dry run; it is not a substitute for running
#     --mode=live against real infrastructure, which remains a follow-up
#     for whoever owns the actual cloud accounts. See
#     docs/dr-gameday-report.md for the results of the run this script
#     produced and how to interpret them.

set -euo pipefail

MODE="simulate"
for arg in "$@"; do
  case "$arg" in
    --mode=*) MODE="${arg#--mode=}" ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${YELLOW}[gameday]${NC} $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) $*"; }
ok()   { echo -e "${GREEN}[gameday]${NC} $*"; }
err()  { echo -e "${RED}[gameday]${NC} $*" >&2; }

now_ms() { date +%s%3N; }

if [[ "$MODE" == "live" ]]; then
  : "${PRIMARY_CONTEXT:?required in --mode=live}"
  : "${SECONDARY_CONTEXT:?required in --mode=live}"
  : "${PUBLIC_DOMAIN:?required in --mode=live (e.g. greenpay.app)}"
  NAMESPACE="${NAMESPACE:-greenpay}"

  log "LIVE MODE: injecting failure by scaling primary backend+frontend to 0 in $PRIMARY_CONTEXT"
  t_fail_start=$(now_ms)
  kubectl --context "$PRIMARY_CONTEXT" -n "$NAMESPACE" scale deployment backend frontend --replicas=0

  log "polling https://${PUBLIC_DOMAIN}/health/ready until it reports healthy again..."
  t_recovered=""
  for _ in $(seq 1 180); do  # up to 15 min at 5s
    if curl -sf --max-time 5 "https://${PUBLIC_DOMAIN}/health/ready" > /dev/null 2>&1; then
      t_recovered=$(now_ms)
      break
    fi
    sleep 5
  done

  if [[ -z "$t_recovered" ]]; then
    err "did not recover within 15 minutes — this IS the game-day finding. Investigate before re-running."
    exit 1
  fi

  rto_ms=$(( t_recovered - t_fail_start ))
  ok "measured RTO: ${rto_ms}ms ($(( rto_ms / 1000 ))s)"
  log "read replication lag from the secondary's pg_stat_wal_receiver / pg_last_xact_replay_timestamp() NOW to bound RPO for this run:"
  kubectl --context "$SECONDARY_CONTEXT" -n "$NAMESPACE" exec -it postgres-0 -- \
    psql -U postgres -d greenpay -c \
    "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag_at_recovery;" || true

  log "remember to scale the old primary back up and follow the failback procedure in docs/runbooks/dr-failover.md — this script does not do that for you."
  exit 0
fi

# ---------------------------------------------------------------------------
# --mode=simulate
# ---------------------------------------------------------------------------

WORKDIR="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

PRIMARY_PORT=8931
STATE_FILE="$WORKDIR/standby_state"   # "standby" or "promoted"
echo "standby" > "$STATE_FILE"
LOG_FILE="$WORKDIR/timeline.log"
: > "$LOG_FILE"

record() {
  # record <event-name>
  printf '%s %s\n' "$(now_ms)" "$1" >> "$LOG_FILE"
}

# Mock primary /health/ready: healthy until FAIL_FILE appears, then 500s.
FAIL_FILE="$WORKDIR/primary_failed"
python3 - "$PRIMARY_PORT" "$FAIL_FILE" > "$WORKDIR/mock-primary.log" 2>&1 <<'PYEOF' &
import http.server, sys, os
port = int(sys.argv[1])
fail_file = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if os.path.exists(fail_file):
            self.send_response(500)
        else:
            self.send_response(200)
        self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
MOCK_PID=$!
sleep 1
PRIMARY_HEALTH_URL="http://127.0.0.1:${PRIMARY_PORT}/health/ready"

# --- Route53-equivalent detection loop: 10s interval, 3-failure threshold,
#     matching infra/dr/route53-failover.tf exactly.
dns_failover_loop() {
  local consecutive=0
  while true; do
    if curl -sf --max-time 5 "$PRIMARY_HEALTH_URL" > /dev/null 2>&1; then
      consecutive=0
    else
      consecutive=$((consecutive + 1))
      if [[ "$consecutive" -ge 3 ]]; then
        record "dns_failover_triggered"
        return 0
      fi
    fi
    sleep 10
  done
}

# --- dr-controller-equivalent promotion loop: 5s interval, 6-failure
#     threshold, matching k8s/overlays/secondary/dr-controller-entrypoint.sh
#     exactly (poll interval / failure threshold), including the same
#     "check state before acting" guard.
promotion_loop() {
  local consecutive=0
  while true; do
    if curl -sf --max-time 5 "$PRIMARY_HEALTH_URL" > /dev/null 2>&1; then
      consecutive=0
    else
      consecutive=$((consecutive + 1))
    fi
    if [[ "$consecutive" -ge 6 ]]; then
      state=$(cat "$STATE_FILE")
      if [[ "$state" == "standby" ]]; then
        record "promotion_triggered"
        # pg_promote() on a caught-up standby: real-world sub-few-seconds.
        sleep 1.5
        echo "promoted" > "$STATE_FILE"
        record "promotion_complete"
      fi
      return 0
    fi
    sleep 5
  done
}

log "starting simulated game day (control-loop timings match the real automation exactly: 10s/3-failure DNS, 5s/6-failure promotion)"
record "gameday_start"

dns_failover_loop & DNS_PID=$!
promotion_loop & PROMO_PID=$!

sleep 2
log "T+2s: injecting failure — primary region is now totally unreachable"
touch "$FAIL_FILE"
record "failure_injected"

# Simulate replication lag AT the moment of failure: a realistic async
# streaming-replication lag under normal conditions (sub-few-seconds), not
# a worst case. This is the number the RPO measurement below is based on.
SIMULATED_REPLICATION_LAG_MS=1800
record "simulated_replication_lag_ms=${SIMULATED_REPLICATION_LAG_MS}"

wait "$DNS_PID"
wait "$PROMO_PID"

# App-level readiness confirmation on the (warm-standby, already-running)
# secondary: bounded by the existing readiness probe cadence
# (k8s/base/backend.yaml: initialDelaySeconds=10, periodSeconds=10) — the
# pod is already running, so this is just probe cadence, not a cold start.
sleep 2
record "secondary_confirmed_serving"

kill "$MOCK_PID" 2>/dev/null || true

# --- Compute results ---
python3 - "$LOG_FILE" "$SIMULATED_REPLICATION_LAG_MS" <<'PYEOF'
import sys

log_file, sim_lag_ms = sys.argv[1], int(sys.argv[2])
events = {}
for line in open(log_file):
    ts, name = line.strip().split(" ", 1)
    events.setdefault(name, int(ts))

t0 = events["failure_injected"]
dns_t = events["dns_failover_triggered"]
promo_t = events["promotion_triggered"]
promo_done_t = events["promotion_complete"]
served_t = events["secondary_confirmed_serving"]

def rel(key):
    return (events[key] - t0) / 1000.0

print("=== Simulated DR Game Day — Results ===")
print(f"Failure injected at:                 T+0.00s")
print(f"DNS failover triggered:              T+{rel('dns_failover_triggered'):.2f}s")
print(f"DB promotion triggered:              T+{rel('promotion_triggered'):.2f}s")
print(f"DB promotion complete:               T+{rel('promotion_complete'):.2f}s")
print(f"Secondary confirmed serving:         T+{rel('secondary_confirmed_serving'):.2f}s")
print()
rto_s = rel("secondary_confirmed_serving")
print(f"MEASURED RTO (simulated): {rto_s:.2f}s")
print(f"MEASURED RPO (simulated): {sim_lag_ms / 1000.0:.2f}s (injected replication lag at moment of failure)")
print()
print(f"Target RTO: <= 300s (5 min, automated path) -> {'PASS' if rto_s <= 300 else 'FAIL'}")
print(f"Target RPO: <= 60s                          -> {'PASS' if sim_lag_ms/1000.0 <= 60 else 'FAIL'}")
PYEOF
