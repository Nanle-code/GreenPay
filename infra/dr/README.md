# Disaster Recovery Infrastructure

Prerequisites and reference IaC for the multi-cluster DR topology described
in [`docs/disaster-recovery.md`](../../docs/disaster-recovery.md). This
directory is deliberately not wired into any CI pipeline — it's one-time,
account-level infrastructure that a human applies when standing up or
changing a region, the same way you wouldn't want `terraform apply` for a
new VPC to run unattended on every push.

## Prerequisites (provisioned before either `k8s/overlays/*` overlay is applied)

1. **Two Kubernetes clusters in two regions**, each capable of applying
   `k8s/overlays/primary` or `k8s/overlays/secondary` respectively.
2. **Private network path between the regions** (VPC peering, AWS
   Transit Gateway, or a cloud-equivalent) so that:
   - the secondary's `postgres` standby-bootstrap init container can reach
     `postgres-replication-svc` in the primary region (see
     `k8s/overlays/primary/postgres-replication-svc.yaml` — this Service
     must be internal-only, never internet-facing, since it's a raw
     Postgres port carrying the full financial dataset);
   - the secondary's `dr-controller` can reach the primary region's
     ingress directly (`PRIMARY_HEALTH_URL` in
     `k8s/overlays/secondary/dr-secrets.yaml`), bypassing public DNS so it
     isn't fooled by Route53 having already failed over (see the comment
     in that file for why this matters).
3. **A Route53 (or equivalent GSLB) hosted zone** for the public domain —
   see `route53-failover.tf`.
4. **A secret store both regions can read from** — see below.
5. **Cross-region object storage replication** for the nightly backup
   bucket used by `.github/workflows/database-backup.yml` — see below.

## Secrets and config replication

Kubernetes `Secret` objects are cluster-local; there is no built-in
cross-cluster sync. This repo's `k8s/overlays/{primary,secondary}/dr-secrets.yaml`
ship as committed placeholder Secrets purely so `kustomize build` and this
PR's manifests are self-contained and reviewable — **do not run two
independently-edited copies of a real secret in production**. Two
committed copies that must be kept in sync by hand is exactly the kind of
gap this issue asks us not to leave: whoever rotates the replication
password in one region and forgets the other silently breaks DR.

Recommended for a real deployment: install the [External Secrets
Operator](https://external-secrets.io/) in both clusters, both pointing at
the same regional-replicated secret store (AWS Secrets Manager with
[multi-region secret
replication](https://docs.aws.amazon.com/secretsmanager/latest/userguide/create-manage-multi-region-secrets.html),
or GCP Secret Manager, which replicates by design). Replace
`dr-secrets.yaml` and `k8s/base/secret.yaml` in both overlays with
`ExternalSecret` resources referencing the same secret path. This also
resolves the "secrets available in the failover target" acceptance
criterion without a manual sync step, and keeps secret rotation a single
action instead of two.

## Object storage replication

`.github/workflows/database-backup.yml` already ships nightly `pg_dump`
backups to S3 or GCS. For DR, that bucket needs to survive the loss of the
primary region too — enable:

- **S3**: [Cross-Region
  Replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html)
  from the primary bucket to a bucket in the secondary region.
- **GCS**: a [dual-region or multi-region
  bucket](https://cloud.google.com/storage/docs/locations#location-dr),
  or [Storage Transfer
  Service](https://cloud.google.com/storage-transfer/docs/overview) if a
  strict two-region topology is required instead.

This is a second, independent recovery path from the live streaming
standby — see docs/disaster-recovery.md's RPO section for how the two
relate (nightly backups are the fallback if the standby is *also* lost;
they are not the primary DR mechanism and their ~24h RPO should never be
read as this topology's actual RPO target).

## Applying

```bash
cd infra/dr
terraform init
terraform apply \
  -var="hosted_zone_id=<your-zone-id>" \
  -var="domain_name=greenpay.app" \
  -var="primary_lb_dns_name=<primary-ingress-lb-dns>" \
  -var="primary_lb_zone_id=<primary-ingress-lb-zone-id>" \
  -var="secondary_lb_dns_name=<secondary-ingress-lb-dns>" \
  -var="secondary_lb_zone_id=<secondary-ingress-lb-zone-id>"
```
