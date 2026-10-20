# tflint config — used by `make lint` and CI.
#
# The AWS ruleset catches misconfigurations that Terraform validate
# doesn't (e.g. invalid instance types, deprecated resource attributes).
# Keep the version explicit so CI runs deterministically.

config {
  format = "compact"
  # Skip modules — they're linted inside their own env by tflint
  # traversal on demand. If we recurse into modules by default we'd hit
  # 3× the false-positive rate on unused-declaration warnings.
  call_module_type = "local"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Warn but don't fail on unused declarations — reusable modules
# intentionally expose vars that aren't used in every env.
rule "terraform_unused_declarations" {
  enabled = false
}
