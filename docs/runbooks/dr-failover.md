# Runbook: Disaster Recovery Failover

Companion to [docs/disaster-recovery.md](../disaster-recovery.md) (topology
and targets) and [ADR-004](../adr/ADR-004-active-passive-multi-cluster-dr-topology.md)
(why this design). This runbook covers what actually happens during an
incident — both the automated path and the points where a human must
step in.

## How to tell you're in this scenario

- PagerDuty/Slack/whatever your on-call tool is fires from
  `aws_cloudwatch_metric_alarm.primary_health` (`infra/dr/route53-failover.tf`)
  and/or an alert from `dr-controller` (its `alert()` function logs and,
  if `ALERT_WEBHOOK_URL` is configured, posts to a webhook —
  `k8s/overlays/secondary/dr-controller-entrypoint.sh`).
- `curl https://<primary-region-direct-endpoint>/health/ready` fails or
  times out from outside the primary region.

## Automated path (expected in most cases)

You do not need to do anything for this part — it's documented here so
you can verify it's actually happening, not so you trigger it manually.

1. Route53 health check against the primary's `/health/ready` fails 3
   consecutive times (~30s) → Route53 starts answering the secondary
   region's record for new DNS lookups.
2. `dr-controller` in the secondary region (polling the primary's direct
   endpoint independently of Route53) fails 6 consecutive checks (~30s)
   → runs `SELECT pg_promote();` against the local standby.
3. Standby Postgres exits recovery mode; `dr-controller` logs "already
   promoted" on its next check and stops attempting promotion.
4. New traffic lands on the secondary region's already-running (warm
   standby) backend/frontend pods, which are now backed by a writable
   database.

### Verify it worked

```bash
# From outside both regions:
dig +short greenpay.app                 # should now resolve to the secondary region's LB
curl -sf https://greenpay.app/health/ready

# Against the secondary cluster directly:
kubectl --context <secondary> -n greenpay logs deploy/dr-controller --tail=50
kubectl --context <secondary> -n greenpay exec -it postgres-0 -- \
  psql -U postgres -d greenpay -c "SELECT pg_is_in_recovery();"   # should be 'f'
```

If both checks pass, the automated failover succeeded. Move to
"After a failover" below.

## Manual intervention scenarios

The automation is intentionally conservative — it takes exactly one
irreversible action (`pg_promote()`) and refuses to guess in ambiguous
cases. These are the cases that fall to a human, in the order you're
likely to hit them:

### 1. `dr-controller` can't reach the local standby to check its state

Its log will show the `unknown` branch alert: *"cannot reach local
standby Postgres to check replication state — refusing to guess."* This
usually means the secondary region's own Postgres pod is unhealthy, which
is a bigger problem than a primary-region outage.

- `kubectl --context <secondary> -n greenpay get pods -l app=postgres`
- If the standby pod itself is crash-looping, fix that first — promoting
  a database you can't confirm the state of is how you get split-brain.
- Once the standby is reachable and confirmed to still be in recovery
  (`pg_is_in_recovery()` = `t`), promote manually:
  ```bash
  kubectl --context <secondary> -n greenpay exec -it postgres-0 -- \
    psql -U postgres -d greenpay -c "SELECT pg_promote();"
  ```

### 2. Split-brain risk: primary comes back while secondary is already promoted

This is the scenario the automation is explicitly not allowed to resolve
on its own — two writable Postgres instances that both think they're
authoritative is a correctness incident, not an availability one.

- **Do not** let the recovered primary rejoin traffic automatically.
  Before anything else: `kubectl --context <primary> -n greenpay scale
  deployment backend frontend --replicas=0` (or, if using blue/green,
  scale both colors) to guarantee nothing writes to the old primary.
- Compare `pg_current_wal_lsn()` on the (now potentially stale) old
  primary against the promoted standby's last-applied LSN
  (`pg_last_wal_replay_lsn()` captured before promotion, or from
  `dr-controller`'s logs) to determine which one has newer data. In
  practice, since promotion only happens after the primary was confirmed
  unreachable, the promoted secondary is authoritative — the old primary
  is treated as the one to be rebuilt, not the source of truth.
- Rebuild the old primary as a fresh standby of the newly-promoted
  region (this is now a role reversal — see "Failback" below) rather than
  attempting to merge data from both.

### 3. Route53 fails over but the database never gets promoted (or vice versa)

These two mechanisms are intentionally independent (see
[docs/disaster-recovery.md](../disaster-recovery.md)), which means they
can, in principle, disagree.

- **DNS moved, DB not promoted**: secondary's backend pods will fail
  their `/health/ready` readiness probe (database still read-only), so
  Kubernetes itself stops routing to them — this fails safe, but presents
  as an outage to users, not silently. Manually promote as in scenario 1.
- **DB promoted, DNS didn't move**: `dr-controller`'s own health check
  against the primary must have started passing again (transient blip),
  so it stopped short of a second promotion — but the standby is now
  writable and receiving no traffic. Check
  `aws_route53_health_check.primary` status directly; if the primary
  region is actually down despite the health check passing, the check
  itself is the bug (e.g. checking a component that doesn't reflect real
  health) — fix the check, and manually flip DNS via the AWS console /
  `aws route53 change-resource-record-sets` in the meantime.

## Failback (after the original primary is confirmed genuinely healthy again)

**Do not simply fail back immediately.** The formerly-primary region has
been offline and its data is now behind. Failing back means turning it
into the new standby, not just reversing a switch:

1. Rebuild the old primary's Postgres as a standby of the *new* primary
   (the region currently serving traffic) using the same
   `pg_basebackup -R` bootstrap the secondary overlay uses — swap which
   overlay (`primary`/`secondary`) is conceptually applied to which
   physical region, since these overlays describe roles, not fixed
   regions.
2. Let it fully catch up (`pg_is_in_recovery()` = `t` and replication lag
   near zero) before considering a failback.
3. Only then, during a planned maintenance window (not urgently), reverse
   Route53's PRIMARY/SECONDARY assignment and run the same promotion
   procedure in reverse.

There is no automated failback — this is deliberate. An automated system
flipping production back and forth based on transient health signals
(flapping) is worse than a slightly slower, human-confirmed failback.

## After a failover — regardless of path

- File an incident review: when detection happened, when promotion
  happened, actual measured downtime, actual data loss (compare last
  indexer-processed ledger before/after against Horizon — see
  `docs/indexer.md`), against the targets in
  [docs/disaster-recovery.md](../disaster-recovery.md).
- Do not scale down the old primary's resources yet — see split-brain
  and failback sections above.
- Rotate `greenpay-dr-secrets` if there's any chance the primary region's
  compromise (rather than just an outage) triggered the failover.
