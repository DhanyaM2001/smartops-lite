# Reusable DynamoDB table module.
#
# Design decisions:
#   - PAY_PER_REQUEST (on-demand): our workload is bursty and low-volume
#     (one write per crashy-app failure). Provisioned throughput would
#     waste money and add capacity-planning overhead.
#   - Server-side encryption ON with the AWS-owned CMK (default). No extra
#     KMS charge; sufficient for non-regulated workloads.
#   - PITR + TTL are opt-in. Off by default in dev to stay in free-tier.
#     Module 12 (chaos-testing) can enable PITR when it wants replay.
#   - Only ONE key attribute is defined at module level (hash_key). GSI/LSI
#     support is deliberately NOT here — YAGNI, we can add it in a v2.

resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = var.hash_key_name

  attribute {
    name = var.hash_key_name
    type = var.hash_key_type
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = var.enable_pitr
  }

  # TTL: when enabled, DynamoDB automatically deletes rows whose <ttl_attribute>
  # Unix timestamp is in the past. Costs nothing to enable; we leave it off in
  # dev so incident rows stick around for debugging.
  dynamic "ttl" {
    for_each = var.enable_ttl ? [1] : []
    content {
      attribute_name = var.ttl_attribute
      enabled        = true
    }
  }

  tags = merge(var.tags, {
    Name = var.table_name
  })
}
