# EventBridge custom bus for SmartOps-Lite incidents.
#
# The controller (Module 4) publishes structured pod-failure events here.
# Downstream (Module 5) an RCA Lambda will target this bus with a rule.
#
# Design decisions:
#   - CUSTOM bus (not default). Isolates our traffic and lets us grant
#     PutEvents on ONE resource ARN instead of the default bus which every
#     service dumps into.
#   - Archive is OPTIONAL (var.enable_archive). ~$0 for our volume but off
#     by default to keep Modules 1-4 truly minimal-cost.
#   - No KMS key: events don't contain secrets — just pod-status metadata.
#     Fine at rest with EventBridge's own encryption.

resource "aws_cloudwatch_event_bus" "this" {
  name = var.bus_name

  tags = merge(var.tags, {
    Name = var.bus_name
  })
}

# ---- Optional 30-day event archive (turn on when Module 5 lands) ----------
# Archive lets Module 12 replay historical events into a fresh bus for
# regression testing. Storage: $0.023/GB/mo — well under free-tier noise.
resource "aws_cloudwatch_event_archive" "this" {
  count            = var.enable_archive ? 1 : 0
  name             = "${var.bus_name}-archive"
  event_source_arn = aws_cloudwatch_event_bus.this.arn
  retention_days   = var.archive_retention_days
  description      = "30-day archive of SmartOps-Lite incident events (replay for regression)."
}
