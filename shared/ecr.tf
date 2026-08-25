# ---------------------------------------------------------------------------
# ECR — one repository, every environment
#
# The image is environment-agnostic on purpose: it carries no endpoint, no
# password, and no env name. Everything it needs is discovered at boot from
# the /<project>-<env>/db/* parameters the per-env stack publishes, so dev and
# prod are two tags of the same bytes rather than two builds.
#
# That is why this lives in the shared stack. A per-env repository would mean
# pushing identical layers twice and would make "is prod running what dev
# tested?" a question you cannot answer by comparing digests.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "rag_map" {
  name = "${var.project_name}-rag-map"

  # MUTABLE because the deploy flow retags `latest` on every push. Pin a tag
  # or a digest in the per-env stack when you want prod immune to that.
  image_tag_mutability = "MUTABLE"

  # Without this, `terraform destroy` fails on a repository that still holds
  # images — which it always does — and leaves the shared stack half torn down.
  force_delete = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ---------------------------------------------------------------------------
# Lifecycle policy
#
# Rules are evaluated in priority order and the first match wins, so the
# `any` rule has to sort last — ECR rejects a policy where it does not.
#
# Untagged images are the layers `latest` used to point at. They are pure cost
# once nothing references them, but they are also what an accidental push has
# to be rolled back to, so they get a day rather than an hour.
# ---------------------------------------------------------------------------

resource "aws_ecr_lifecycle_policy" "rag_map" {
  repository = aws_ecr_repository.rag_map.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent ${var.ecr_max_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_max_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
