# ADR-004: Active-Passive Multi-Cluster DR Topology

## Status

Accepted

## Context and Problem Statement

GreenPay's `k8s/` manifests describe a single-cluster deployment. A total
loss of that cluster's region — a real, if infrequent, failure mode for
any cloud region — currently has no recovery path beyond restoring from a
nightly `pg_dump` backup (`.github/workflows/database-backup.yml`), which
implies hours of downtime and up to 24h of data loss. For an application
handling escrowed funds (`contracts/escrow-contract`) and donation
records, that is not an acceptable disaster-recovery posture, even though
the core donation transaction itself settles on Stellar and does not
depend on GreenPay's own infrastructure (see
[ADR-002](ADR-002-why-direct-to-wallet-payments-over-platform-custody.md)).

This ADR decides the multi-cluster topology: active-active or
active-passive, and if active-passive, how failover is triggered and how
fast it can realistically be.

## Decision Drivers

- The backend's Postgres database is the source of truth for donation
  *records* (leaderboard, donor badges, project totals, update feed) —
  the underlying fund movement is not (Stellar/Soroban is), but the
  indexer that populates Postgres from the chain has **no backfill or
  reconciliation mechanism** (`docs/indexer.md`: "There is currently no
  reconciliation mechanism"). A missed write is a *permanently* missed
  write today, not just a delayed one. This makes the choice of database
  replication strategy the dominant factor in the topology decision.
- A financial application should not add write-latency to every donation
  request in the common case just to protect against a rare regional
  outage.
- The team operating this is small — the failover mechanism needs to be
  simple enough to reason about during an actual incident, not just in
  the design doc.
- RTO/RPO targets need to be real numbers derived from the actual
  mechanism chosen, not aspirational round numbers.

## Considered Options

- Active-active with synchronous (or quorum) cross-region Postgres writes
- Active-active with asynchronous multi-master replication (conflict-prone)
- Active-passive with asynchronous physical streaming replication

## Decision Outcome

Chosen option: **active-passive, with asynchronous physical (WAL)
streaming replication** from a primary-region Postgres to a
secondary-region standby.

- **Synchronous cross-region replication was rejected**: committing every
  donation-record write only after a round trip to another region adds
  tens to a hundred-plus milliseconds to every write, permanently, to
  protect against an event (total region loss) that should be rare. That
  trade is backwards for this workload — donation writes are already the
  non-critical path (per ADR-002, the payment itself doesn't wait on
  this).
- **Active-active multi-master was rejected**: it reintroduces exactly the
  conflict-resolution problem plain Postgres isn't built for, and the
  data it's protecting (donation records, badges, leaderboard rank) has
  no natural merge function for "both regions accepted a write to the
  same row during a partition." Async active-passive avoids ever needing
  one, at the cost of a bounded window of possible data loss during an
  actual failover (see RPO below).
- The **indexer's lack of reconciliation** (see Decision Drivers) is
  treated as a real, already-existing constraint, not something this ADR
  fixes. It means the RPO target below is a genuine business risk
  commitment, not a formality — see `docs/disaster-recovery.md` for the
  numbers and `docs/indexer.md`'s own "future enhancement" section for
  the follow-up (indexer cursor persistence + gap reconciliation) that
  would let RPO for indexed data approach zero. That follow-up is out of
  scope for this issue.
- The **existing indexer design already tolerates concurrent instances**
  (`backend/src/services/indexerService.js`'s dedup-by-`transaction_hash`
  is exactly why running `replicas: 2` in a single cluster today is safe).
  The DR topology deliberately extends this instead of fighting it: the
  secondary region keeps a warm standby of the backend running (indexer
  included) at all times, not a cold/scaled-to-zero copy. This removes
  what would otherwise be the topology's biggest hidden gap — an indexer
  with an in-memory, non-persisted cursor (`docs/indexer.md`: "On process
  restart, the indexer starts from `now` again") restarting cold in the
  secondary region at exactly the moment of a primary outage.

## Positive Consequences

- No added write latency on the donation-record path in normal operation.
- Failover only requires one irreversible, well-understood action
  (`SELECT pg_promote()`), automatable and testable in isolation — see
  `k8s/overlays/secondary/dr-controller-entrypoint.sh`.
- Warm standby app pods (not scaled to zero) mean RTO is bounded by
  "promote DB + shift DNS", not "cold-start an entire region", and the
  indexer gap described above doesn't reopen.
- Blue/green deployments (`scripts/blue-green-deploy.sh`) work identically
  in both regions since both always have live traffic-capable pods.

## Negative Consequences

- RPO is bounded by replication lag, not zero — a sufficiently violent
  failure (primary destroyed mid-transaction) can lose the last few
  seconds of donation-record writes, permanently, given the indexer
  constraint above. This must be monitored, not just assumed.
- Two regions' worth of backend/frontend/indexer run continuously, which
  costs more than a cold-standby topology would.
- Manual promotion is required if the automation can't confirm it's safe
  (see `docs/runbooks/dr-failover.md`) — active-passive does not remove
  the need for a human runbook, only narrows how often it's needed.

## Pros and Cons of the Options

### Active-active, synchronous/quorum writes

- Good, because RPO could approach zero.
- Bad, because it adds permanent cross-region latency to every donation-record write.
- Bad, because it requires a consensus-aware Postgres topology (e.g. a multi-node quorum setup) well beyond the current single-primary StatefulSet, for a workload that doesn't need it.

### Active-active, asynchronous multi-master

- Good, because both regions can accept writes without cross-region latency.
- Bad, because it requires conflict resolution for concurrent writes to the same donation/project/donor row, which the current schema and application code have no concept of.
- Bad, because "which write wins" for financial-adjacent records is a correctness question, not an ops question, and shouldn't be decided implicitly by a replication tool's default conflict policy.

### Active-passive, asynchronous physical streaming replication (chosen)

- Good, because it matches Postgres's native, well-understood replication model — no new conflict semantics.
- Good, because it keeps the donation-record write path exactly as fast as it is today.
- Bad, because RPO is bounded by replication lag rather than zero, which matters more than it otherwise would given the indexer's lack of reconciliation.

## More Information

- [docs/disaster-recovery.md](../disaster-recovery.md) — RTO/RPO targets and full topology
- [docs/runbooks/dr-failover.md](../runbooks/dr-failover.md) — operational procedure
- [docs/indexer.md](../indexer.md) — the reconciliation gap this ADR works around rather than fixes
- [ADR-002](ADR-002-why-direct-to-wallet-payments-over-platform-custody.md) — why the donation payment itself isn't on this critical path
