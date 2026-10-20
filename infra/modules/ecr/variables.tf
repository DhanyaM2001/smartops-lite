variable "project" {
  description = "Project short name; prefixes resource names."
  type        = string
}

variable "repository_names" {
  description = <<-EOT
    List of ECR repository short names to create. Each becomes
    <repository_name>. Example: ["smartops/crashy-app", "smartops/controller"].
    Path-style names group images under a project prefix in the ECR console.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.repository_names) > 0
    error_message = "At least one repository name is required."
  }
}

variable "image_tag_mutability" {
  description = "MUTABLE lets us retag :latest during dev. IMMUTABLE is stricter — pick when doing supply-chain hardening."
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "scan_on_push" {
  description = "Enable ECR native image scanning on push (free, uses AWS Inspector CVE DB)."
  type        = bool
  default     = true
}

variable "keep_tagged" {
  description = "Number of most-recent tagged images to keep per repo. Older tagged images are deleted."
  type        = number
  default     = 20
}

variable "keep_untagged" {
  description = "Number of most-recent untagged images to keep per repo (dangling from failed pushes)."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Extra tags merged onto every ECR resource."
  type        = map(string)
  default     = {}
}
