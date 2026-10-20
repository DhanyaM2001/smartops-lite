variable "table_name" {
  description = "Fully-qualified table name, e.g. 'smartops-incidents'."
  type        = string
}

variable "hash_key_name" {
  description = "Partition key attribute name."
  type        = string
  default     = "incidentId"
}

variable "hash_key_type" {
  description = "Partition key attribute type (S=string, N=number, B=binary)."
  type        = string
  default     = "S"

  validation {
    condition     = contains(["S", "N", "B"], var.hash_key_type)
    error_message = "hash_key_type must be one of: S, N, B."
  }
}

variable "enable_pitr" {
  description = <<-EOT
    Enable Point-in-Time Recovery. Costs ~$0.20/GB/mo on top of storage; off
    by default in dev. Turn on for prod / long-lived data.
  EOT
  type        = bool
  default     = false
}

variable "enable_ttl" {
  description = <<-EOT
    Enable native DynamoDB TTL. Rows whose <ttl_attribute> Unix timestamp is
    in the past are auto-deleted (free). Off by default so debugging can see
    historical incidents.
  EOT
  type        = bool
  default     = false
}

variable "ttl_attribute" {
  description = "Attribute name that stores the TTL Unix timestamp when enable_ttl=true."
  type        = string
  default     = "ttl"
}

variable "tags" {
  description = "Additional tags applied to the table."
  type        = map(string)
  default     = {}
}
