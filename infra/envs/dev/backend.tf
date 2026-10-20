# Remote state configuration.
#
# The bucket name embeds the AWS account ID (see scripts/bootstrap-tf-backend.sh),
# so we can't hardcode it here without breaking portability. We declare a
# PARTIAL backend and fill it in at `terraform init` time via -backend-config.
#
# The Makefile's `tf-init` target does this automatically by sourcing
# scripts/.backend-values (git-ignored, written by bootstrap-tf-backend.sh).

terraform {
  backend "s3" {
    # bucket, key, region, dynamodb_table are all injected at init.
    encrypt = true
  }
}
