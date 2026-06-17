###############################################################################
# Module: ECR (Elastic Container Registry)
#
# Creates:
#   • One ECR repo per service
#   • Image scanning on push (ECR enhanced scanning)
#   • Lifecycle policy: keep last 10 tagged + remove untagged after 1 day
###############################################################################

locals {
  services = ["keeper", "indexer", "ws-gateway"]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)

  name                 = "gmsol/${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "gmsol-${each.key}"
  }
}

###############################################################################
# Lifecycle Policy — keep last 10 tagged images, delete untagged after 1 day
###############################################################################

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
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
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

###############################################################################
# ECR Pull-through cache (optional: cache public images to avoid Docker Hub limits)
###############################################################################

resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}
