# ==============================================================================
# Amazon Elastic Container Registry (ECR) Repositories
# ==============================================================================

resource "aws_ecr_repository" "golang_checkout_service" {
  name                 = "golang-checkout-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_repository" "python_payment_service" {
  name                 = "python-payment-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}
