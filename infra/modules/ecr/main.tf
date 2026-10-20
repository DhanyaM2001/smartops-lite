# Reusable ECR module.
#
# Creates N private ECR repositories with:
#   - configurable tag mutability
#   - scan-on-push (free CVE scan via AWS-managed Inspector DB)
#   - AES256 encryption at rest (AWS-managed key — free; upgrade to KMS
#     in Module 12 if the security review calls for it)
#   - lifecycle policy: keep the most recent `keep_tagged` tagged images
#     and the most recent `keep_untagged` untagged (dangling) ones
#
# Not created here (deliberately, to keep the free-tier posture obvious):
#   - Cross-account replication
#   - Pull-through cache
#   - Registry-level scanning enhanced mode (paid)

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = var.image_tag_mutability
  force_delete         = true # allows `make nuke` to delete the repo even with images inside

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project}-${replace(each.value, "/", "-")}"
    },
  )
}

# ---- Lifecycle policy: prune old images ---------------------------------
#
# Rule numbers matter: ECR evaluates in ascending order, first-match-wins.
#   1. Keep the last N tagged images (any tag).
#   2. Delete untagged images beyond the last M — untagged accumulate from
#      failed/interrupted pushes and cost storage even when useless.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last ${var.keep_tagged} tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.keep_tagged
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.keep_untagged} untagged images, expire older ones"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_untagged
        }
        action = { type = "expire" }
      },
    ]
  })
}
