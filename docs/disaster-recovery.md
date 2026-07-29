# Disaster Recovery — Multi-Cluster Topology

Companion to [ADR-004](adr/ADR-004-active-passive-multi-cluster-dr-topology.md)
(why active-passive) and [docs/runbooks/dr-failover.md](runbooks/dr-failover.md)
(what to actually do during an incident). This document covers the
topology, the RTO/RPO targets and where those numbers come from, and how
the pieces fit together.

## Topology

```
                     ┌─────────────────────────┐
                     │   Route53 (GSLB / DNS)   │
                     │  failover routing policy │
                     │  health check: /health/  │
                     │  ready every 10s          │
                     └────────────┬─────────────┘
                    healthy? primary : secondary
              ┌────────────────────┴────────────────────┐
              ▼                                         ▼
┌───────────────────────────┐             ┌───────────────────────────┐
│      PRIMARY REGION        │             │     SECONDARY REGION      │
│  k8s/overlays/primary       │  async WAL  │  k8s/overlays/secondary    │
│                             │  streaming  │                            │
│  frontend (2 replicas)      │◄───────────►│  frontend (2, warm)        │
│  backend  (2 replicas)      │ replication │  backend  (2, warm)        │
│    - indexer runs in every  │             │    - indexer ALSO runs     │
│      backend pod (dedup by  │             │      here — see ADR-004,  │
│      tx_hash; already true  │             │      this is what removes │
│      today with replicas:2) │             │      the "cold indexer on │
│  postgres (primary)         │             │      failover" gap        │
│    - wal_level=replica      │             │  postgres (standby)       │
│    - postgres-replication-  │             │    - bootstrapped via      │
│      svc (internal-only)    │             │      pg_basebackup -R      │
│                             │             │  dr-controller (1 replica)│
│                             │             │    - polls primary's       │
│                             │             │      /health/ready DIRECTLY│
│                             │             │      (not via public DNS) │
│                             │             │    - SELECT pg_promote()  │
│                             │             │      after sustained      │
│                             │             │      failure               │
└───────────────────────────┘             └───────────────────────────┘
```

- **Primary/secondary Postgres**: `k8s/overlays/primary/postgres-primary-patch.yaml`
  and `k8s/overlays/secondary/postgres-standby-patch.yaml`, built on the
  same `k8s/base/postgres.yaml` StatefulSet.
- **Global load balancing**: `infra/dr/route53-failover.tf` — health-check-driven
  DNS failover, AWS Route53 as the reference implementation (see that
  file's header for the GCP/Cloud DNS equivalent shape).
- **Automated DB promotion**: `k8s/overlays/secondary/dr-controller.yaml` +
  `dr-controller-entrypoint.sh` — the piece Route53 alone can't do, since
  Route53 has no concept of Postgres replication state.
- **Blue/green deployment**: `scripts/blue-green-deploy.sh`, applies
  identically in both regions — see "Blue/green deployment" below.

Why active-passive rather than active-active, and why async rather than
sync replication, is covered in
[ADR-004](adr/ADR-004-active-passive-multi-cluster-dr-topology.md) — this
document takes that decision as given and focuses on the resulting
numbers and mechanics.

## RTO / RPO targets

| Scenario | RTO target | RPO target |
|---|---|---|
| Automated failover (primary region health check fails, standby promotes cleanly) | **≤ 5 minutes** | **≤ 60 seconds** of donation-record writes (async replication lag) |
| Manual intervention required (see runbook) | **≤ 30 minutes** | Same ≤ 60s baseline, plus whatever the manual investigation itself costs |
| Both primary AND streaming standby lost (double failure) | Hours (restore from nightly backup) | **≤ 24 hours** (nightly `pg_dump` cadence — `.github/workflows/database-backup.yml`) |

These are not round numbers picked for optics — they're derived from the
actual mechanism:

### RTO breakdown (automated path)

| Step | Time | Source |
|---|---|---|
| Route53 health check detects failure | ~30s | 10s check interval × 3-failure threshold (`infra/dr/route53-failover.tf`) |
| DNS answer changes for new lookups | near-immediate at the resolver Route53 controls; up to the record's TTL (30s, set low deliberately) for resolvers that already cached the old answer | Route53 failover routing behavior |
| dr-controller detects failure and promotes standby | ~30s | 5s poll interval × 6-failure threshold (`dr-controller-entrypoint.sh`), chosen deliberately close to, but independent of, Route53's own threshold — both trip at roughly the same time without one depending on the other |
| `pg_promote()` completion | low single-digit seconds | Standard for a caught-up standby; no data to catch up on beyond in-flight WAL |
| Secondary already serving traffic (warm standby, not cold-started) | 0 — this is the entire reason app pods run continuously in the secondary | ADR-004 |

Sum with buffer for scheduling jitter and alerting: **~5 minutes**, all
automated, no human action required. This is why the topology insists on
warm-standby app pods rather than scaling the secondary to zero — a cold
start would add pod scheduling + image pull + readiness-probe warm-up
(the existing `initialDelaySeconds: 10` + `periodSeconds: 10` on the
backend readiness probe alone) on top of everything else in this table.

The 30-minute manual-intervention target exists for the cases the
automation is deliberately built to refuse to guess about — see
`dr-controller-entrypoint.sh`'s `unknown` branch and
[docs/runbooks/dr-failover.md](runbooks/dr-failover.md).

### RPO breakdown

The ≤60s target is a **replication-lag budget**, not a guess:

- Async streaming replication lag under normal conditions is typically
  sub-second to a few seconds on a healthy link; 60s is a deliberately
  conservative ceiling that leaves headroom for transient network blips
  between regions.
- **Alert before the target is breached**: replication lag should be
  monitored continuously (`pg_stat_replication.replay_lag` on the
  primary, or `pg_last_xact_replay_timestamp()` age on the standby) with
  an alert at 30s lag — half the RPO budget — so a degrading link is
  caught before it becomes a real data-loss incident, not after.
- **Why 60s and not 0**: per [ADR-004](adr/ADR-004-active-passive-multi-cluster-dr-topology.md),
  synchronous cross-region replication was explicitly rejected as a
  latency trade that doesn't fit this workload. Given that, some
  nonzero RPO is inherent to the chosen topology, and 60s is the number
  we commit to monitoring and alerting against, not merely hoping for.
- **This is a genuine business risk, not a formality**: `docs/indexer.md`
  documents that the indexer has "no backfill mode, no gap detection, and
  no periodic comparison against Horizon" — so a donation-record write
  lost within the RPO window during an actual failover is lost
  permanently, not just delayed. The donation itself is never lost (it's
  on the Stellar ledger regardless), but its leaderboard entry, badge
  update, and feed entry could be. Closing this gap for real (persisting
  the indexer's cursor + adding reconciliation, per `docs/indexer.md`'s
  own "future enhancement" section) is explicitly out of scope for this
  issue but is the natural follow-up that would let RPO approach zero for
  indexed data too.

## Secrets and object storage in the failover target

A DR plan that only covers stateless pods is incomplete — this topology
also needs:

- **Database**: covered above (streaming replication).
- **Secrets/config**: `k8s/overlays/{primary,secondary}/dr-secrets.yaml`
  ship as committed placeholders for reviewability, but production should
  source both from one External-Secrets-Operator-backed store instead of
  two independently-edited committed Secrets — see
  [`infra/dr/README.md`](../infra/dr/README.md#secrets-and-config-replication)
  for why and how.
- **Object storage** (the nightly backup bucket): needs cross-region
  replication (S3 CRR / GCS dual-region) so it isn't lost in the same
  event as the primary region — see
  [`infra/dr/README.md`](../infra/dr/README.md#object-storage-replication).
  This is the fallback path for a double failure (primary AND standby
  both lost), distinct from and much slower than the live streaming
  standby — see the RTO/RPO table above.

## Blue/green deployment

`scripts/blue-green-deploy.sh` converts routine releases (in either
region, independently) to zero-downtime blue/green using the existing
`k8s/base/backend.yaml` / `k8s/base/frontend.yaml` Deployments as the
template for the "other" color — see that script's header comment for the
full mechanics (clone → smoke test against a dedicated per-color Service →
cutover via a Service selector patch → post-cutover monitoring window →
automatic rollback on failure). `scripts/smoke-test.sh` is the shared gate
used both pre-cutover and during the post-cutover monitoring window; it
checks `/health/ready` specifically (not just `/health`) so a new color
that boots but can't reach the database never gets promoted to serving
production traffic.

This is deliberately independent of the region-failover mechanism above —
a blue/green release and a regional failover are different events, and
conflating them would make each harder to reason about during an
incident.

## Game day

See [docs/dr-gameday-report.md](dr-gameday-report.md) for the executed
game day, measured RTO/RPO against these targets, and the gap it found and
fixed.
