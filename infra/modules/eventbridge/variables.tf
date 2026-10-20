variable "bus_name" {
  description = "Name of the custom EventBridge bus (e.g. smartops-dev)."
  type        = string
}

variable "enable_archive" {
  description = <<-EOT
    If true, create a 30-day archive on the bus. Used by Module 12 for
    replay. Off by default so Modules 1-4 stay minimal-cost.
  EOT
  type        = bool
  default     = false
}

variable "archive_retention_days" {
  description = "How long to retain archived events (days). 0 = infinite (not recommended)."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to the bus + archive."
  type        = map(string)
  default     = {}
}
