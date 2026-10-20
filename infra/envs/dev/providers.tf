# AWS provider config.
# default_tags apply to EVERY resource that supports tags — critical for our
# cost tracking + orphan detection.

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = var.project
      env        = var.env
      owner      = var.owner
      managed_by = "terraform"
    }
  }
}
