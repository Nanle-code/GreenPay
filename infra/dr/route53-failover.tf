# Global load balancing for GreenPay's active-passive multi-cluster DR
# topology (see docs/disaster-recovery.md).
#
# Health-check-driven DNS failover: Route53 continuously probes each
# region's deep readiness endpoint (/health/ready — verifies DB
# connectivity, not just process liveness) and serves the PRIMARY record
# as long as it's healthy, falling back to SECONDARY automatically when it
# isn't. This is independent of, and complementary to, the in-cluster
# dr-controller (k8s/overlays/secondary/dr-controller.yaml) which promotes
# the standby database — Route53 only ever redirects traffic, it never
# touches Postgres.
#
# Prerequisites this file assumes are already provisioned (not created
# here, since they're one-time account/network setup rather than
# per-deploy infra):
#   - Both clusters' ingress controllers exposed via their own regional
#     load balancers (aws_lb / ALB/NLB per region, referenced below by
#     DNS name — plug in your actual values).
#   - A Route53 public hosted zone for the apex domain.
#   - VPC peering / PrivateLink between the two regions so the secondary's
#     standby-bootstrap and dr-controller can reach the primary directly
#     (see postgres-replication-svc.yaml's internal-NLB annotation and
#     dr-secrets.yaml's PRIMARY_POSTGRES_HOST / PRIMARY_HEALTH_URL).
#
# This is reference infrastructure-as-code, not something applied
# automatically by any pipeline in this repo — a human runs `terraform
# apply` here as part of standing up a region, same as any other
# account-level infra change.

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the apex domain (e.g. greenpay.app)"
  type        = string
}

variable "domain_name" {
  description = "Public domain name traffic is served from"
  type        = string
  default     = "greenpay.app"
}

variable "primary_lb_dns_name" {
  description = "DNS name of the primary region's ingress load balancer"
  type        = string
}

variable "primary_lb_zone_id" {
  description = "Hosted zone ID of the primary region's ingress load balancer (for the ALIAS record)"
  type        = string
}

variable "secondary_lb_dns_name" {
  description = "DNS name of the secondary region's ingress load balancer"
  type        = string
}

variable "secondary_lb_zone_id" {
  description = "Hosted zone ID of the secondary region's ingress load balancer (for the ALIAS record)"
  type        = string
}

# Fast health check: 10s interval is the fastest Route53 supports
# ("fast" health checks, billed accordingly). Combined with a 3-failure
# threshold, detection takes ~30s worst case. This is the single biggest
# lever on RTO — see docs/disaster-recovery.md's RTO breakdown.
resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary_lb_dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health/ready"
  failure_threshold = 3
  request_interval  = 10

  tags = {
    Name = "greenpay-primary-health"
  }
}

resource "aws_route53_health_check" "secondary" {
  fqdn              = var.secondary_lb_dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health/ready"
  failure_threshold = 3
  request_interval  = 10

  tags = {
    Name = "greenpay-secondary-health"
  }
}

# PRIMARY/SECONDARY failover routing: Route53 answers with the primary
# record whenever aws_route53_health_check.primary is healthy, and
# switches to the secondary record when it isn't — no manual DNS change
# required for the automated path.
resource "aws_route53_record" "primary" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = var.primary_lb_dns_name
    zone_id                = var.primary_lb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "secondary" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  set_identifier  = "secondary"
  health_check_id = aws_route53_health_check.secondary.id

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = var.secondary_lb_dns_name
    zone_id                = var.secondary_lb_zone_id
    evaluate_target_health = true
  }
}

# Alert on the same signal the dr-controller polls, so humans and the
# in-cluster controller notice a primary outage at the same time — see
# docs/runbooks/dr-failover.md for what to do when this fires.
resource "aws_cloudwatch_metric_alarm" "primary_health" {
  alarm_name          = "greenpay-primary-region-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 10
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Primary region /health/ready has failed 3 consecutive Route53 checks. Automated failover (Route53 DNS + dr-controller DB promotion) should already be in progress. See docs/runbooks/dr-failover.md."
  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }
  alarm_actions = [] # wire to your on-call notification target (SNS topic ARN, etc.)
}

output "domain_name" {
  value = var.domain_name
}
