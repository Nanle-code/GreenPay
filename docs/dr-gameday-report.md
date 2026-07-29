# DR Game Day Report

Companion to [docs/disaster-recovery.md](disaster-recovery.md) (targets)
and [scripts/dr-gameday.sh](../scripts/dr-gameday.sh) (the tool that
produced this run).

## Scope of this run — read this first

This run used `scripts/dr-gameday.sh --mode=simulate`, **not**
`--mode=live` against real clusters. The environment this PR was built in
has no `kubectl`/`docker`/cloud credentials available, so a real
multi-region failover could not be executed here. `--mode=simulate`
exercises the exact same control-loop logic and thresholds as the real
automation — the same 10s-interval/3-failure DNS detection window as
`infra/dr/route53-failover.tf`, and the same 5s-interval/6-failure
promotion window as `k8s/overlays/secondary/dr-controller-entrypoint.sh`
— against local mock HTTP endpoints instead of real regions. It validates
that the control flow and timing model are correct and produces real
measured wall-clock numbers, but it is **not** a substitute for running
`--mode=live` against provisioned infrastructure, which is the natural
next step once `infra/dr/` is actually applied to real cloud accounts —
see `infra/dr/README.md` for prerequisites.

Everything below is reported honestly on that basis: real numbers from a
real (local) run of the real control-loop code, against a simulated
network/failure rather than a simulated result written by hand.

## Scenario

Total, instantaneous loss of the primary region (mock `/health/ready`
starts returning 500 at T+2s and stays down) — the full scenario the
issue asks for, minus it being a real region.

## Results (representative run; two consecutive runs agreed within ~30ms)

| Event | Time |
|---|---|
| Failure injected | T+0.00s |
| DNS failover triggered (10s/3-failure detection) | T+28.10s |
| DB promotion triggered (5s/6-failure detection) | T+28.15s |
| DB promotion complete (`pg_promote()`, simulated 1.5s) | T+29.66s |
| Secondary confirmed serving | T+31.68s |

| Metric | Target ([docs/disaster-recovery.md](disaster-recovery.md)) | Measured (simulated) | Result |
|---|---|---|---|
| RTO (automated path) | ≤ 300s (5 min) | **31.68s** | **PASS** |
| RPO | ≤ 60s | **1.80s** (injected replication lag) | **PASS** |

The measured RTO is well under target because the target's 5-minute
budget deliberately includes buffer for DNS TTL propagation to resolvers
that already cached an answer, scheduling jitter, and alerting overhead —
none of which a local simulation with no real DNS or real scheduler
exercises. The control-loop timing itself (the part this run *can*
validate) lines up with the breakdown in
[docs/disaster-recovery.md](disaster-recovery.md#rto-breakdown-automated-path)
almost exactly (~28s detection + ~1.5s promotion + probe cadence).

## Gaps found and fixed

Two real gaps were found while building this topology (not by the timing
simulation itself, which only validates control flow — these were found
during design review and fixed before this PR):

1. **The DR controller would have watched the wrong endpoint.** An
   earlier draft had `dr-controller` poll the public, GSLB-managed domain
   to decide whether to promote the standby. Once Route53 fails over,
   that public domain starts resolving to the secondary region itself —
   the controller would have been checking its own health and never
   detected that the primary was actually down. Fixed by requiring
   `PRIMARY_HEALTH_URL` to be the primary region's direct, non-GSLB
   endpoint — see the comment in
   `k8s/overlays/secondary/dr-secrets.yaml`.
2. **The indexer would have restarted cold in the secondary region at
   the exact moment it matters most.** `backend/src/services/indexerService.js`'s
   cursor is in-memory only (`docs/indexer.md`: "On process restart, the
   indexer starts from `now` again, missing any operations that occurred
   during the downtime"). A secondary region scaled to zero until
   failover would start a fresh indexer with no cursor exactly when a
   primary-region outage is happening — the worst possible time to miss
   donation events. Fixed by keeping the secondary's backend (indexer
   included) running continuously as a warm standby rather than
   scaled-to-zero; this is safe because the indexer already dedups by
   `transaction_hash` (already relied on today via `replicas: 2` in a
   single cluster) — see [ADR-004](adr/ADR-004-active-passive-multi-cluster-dr-topology.md).

## Known residual gap (explicitly out of scope for this issue)

The indexer still has **no backfill or reconciliation mechanism**
(`docs/indexer.md`). The warm-standby fix above closes the specific
failover-timing gap, but the underlying limitation — a missed SSE event
for any reason is lost permanently, with no way to detect or backfill the
gap — remains. This bounds the RPO target's honesty: 60s is a real,
monitored budget, not a guarantee that nothing is ever lost within it, and
this run does not claim to have fixed that underlying limitation.
`docs/indexer.md`'s own "future enhancement" section (persisted cursor +
periodic reconciliation) is the correct follow-up and is out of scope
here.

## Next step

Run `scripts/dr-gameday.sh --mode=live` against the actual provisioned
primary/secondary clusters once `infra/dr/` (see `infra/dr/README.md`) is
applied to real cloud accounts, and update this report with those
numbers.
