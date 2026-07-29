#!/bin/sh
# k8s/overlays/secondary/dr-controller-entrypoint.sh
#
# Runs inside the dr-controller Deployment in the SECONDARY region
# (see dr-controller.yaml in this directory). Embedded into that
# Deployment's ConfigMap via kustomize's configMapGenerator (kustomization.yaml
# in this directory) so this file is the single source of truth for both
# "how it's documented" and "what actually runs". It lives under
# k8s/overlays/secondary/ rather than scripts/ because kustomize's default
# load restrictions forbid a configMapGenerator file source from resolving
# outside the kustomization root.
#
# Continuously health-checks the PRIMARY region directly (never through the
# public GSLB/DNS-managed domain — see the comment on PRIMARY_HEALTH_URL in
# k8s/overlays/secondary/dr-secrets.yaml for why). After FAILURE_THRESHOLD
# consecutive failures, promotes the local Postgres standby via
# `SELECT pg_promote();`. Route53 failover routing (infra/dr/route53-failover.tf)
# handles shifting traffic independently, based on its own health check
# against the same primary endpoint.
#
# This script intentionally does NOT touch DNS, scale Deployments, or do
# anything beyond the one irreversible action (DB promotion) that has to
# happen locally in-cluster. Anything it can't safely resolve on its own —
# see the "unknown" branch below — is an alert, not an action; the human
# runbook (docs/runbooks/dr-failover.md) takes over from there.

set -eu

PRIMARY_HEALTH_URL="${PRIMARY_HEALTH_URL:?PRIMARY_HEALTH_URL is required}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-6}"
STANDBY_PGHOST="${STANDBY_PGHOST:-postgres-svc}"
STANDBY_PGPORT="${STANDBY_PGPORT:-5432}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"

log() { echo "[dr-controller] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

alert() {
  msg="$1"
  log "ALERT: $msg"
  if [ -n "$ALERT_WEBHOOK_URL" ]; then
    wget -q -O /dev/null \
      --header="Content-Type: application/json" \
      --post-data="{\"text\":\"$msg\"}" \
      "$ALERT_WEBHOOK_URL" 2>/dev/null || log "webhook delivery failed (non-fatal)"
  fi
}

consecutive_failures=0

log "watching $PRIMARY_HEALTH_URL every ${POLL_INTERVAL_SECONDS}s; promoting standby after $FAILURE_THRESHOLD consecutive failures"

while true; do
  if wget -q -T 5 -O /dev/null "$PRIMARY_HEALTH_URL" 2>/dev/null; then
    if [ "$consecutive_failures" -gt 0 ]; then
      log "primary recovered after $consecutive_failures failed check(s) — resetting counter"
    fi
    consecutive_failures=0
  else
    consecutive_failures=$((consecutive_failures + 1))
    log "primary health check failed ($consecutive_failures/$FAILURE_THRESHOLD)"
  fi

  if [ "$consecutive_failures" -ge "$FAILURE_THRESHOLD" ]; then
    is_replica=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$STANDBY_PGHOST" -p "$STANDBY_PGPORT" \
      -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "unknown")

    case "$is_replica" in
      t)
        outage_seconds=$((consecutive_failures * POLL_INTERVAL_SECONDS))
        alert "primary unreachable for ~${outage_seconds}s — promoting local standby now"
        PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$STANDBY_PGHOST" -p "$STANDBY_PGPORT" \
          -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_promote();" >/dev/null
        log "pg_promote() issued"
        alert "standby promoted. Confirm traffic shifts within the documented RTO window (docs/disaster-recovery.md); if not, follow docs/runbooks/dr-failover.md manual DNS override."
        consecutive_failures=0
        ;;
      f)
        log "already promoted (pg_is_in_recovery=false) — no action needed"
        ;;
      *)
        alert "cannot reach local standby Postgres to check replication state — refusing to guess. Follow the manual-intervention procedure in docs/runbooks/dr-failover.md."
        ;;
    esac
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done
