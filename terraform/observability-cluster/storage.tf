# 1. S3 Buckets for LGTM Stack
resource "aws_s3_bucket" "loki_data" {
  bucket_prefix = "${var.cluster_name}-loki-data-"
  force_destroy = true
}

resource "aws_s3_bucket" "tempo_data" {
  bucket_prefix = "${var.cluster_name}-tempo-data-"
  force_destroy = true
}

resource "aws_s3_bucket" "mimir_blocks" {
  bucket_prefix = "${var.cluster_name}-mimir-blocks-"
  force_destroy = true
}

resource "aws_s3_bucket" "mimir_ruler" {
  bucket_prefix = "${var.cluster_name}-mimir-ruler-"
  force_destroy = true
}

resource "aws_s3_bucket" "mimir_alertmanager" {
  bucket_prefix = "${var.cluster_name}-mimir-alert-"
  force_destroy = true
}

# 2. IAM Policy for S3 Access
#    s3:GetBucketLocation is required by Loki on startup to resolve the AWS
#    region from the bucket name. Omitting it causes a 403 CrashLoopBackOff.
data "aws_iam_policy_document" "grafana_stack_s3_access" {
  statement {
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject"
    ]
    resources = [
      aws_s3_bucket.loki_data.arn,
      "${aws_s3_bucket.loki_data.arn}/*",
      aws_s3_bucket.tempo_data.arn,
      "${aws_s3_bucket.tempo_data.arn}/*",
      aws_s3_bucket.mimir_blocks.arn,
      "${aws_s3_bucket.mimir_blocks.arn}/*",
      aws_s3_bucket.mimir_ruler.arn,
      "${aws_s3_bucket.mimir_ruler.arn}/*",
      aws_s3_bucket.mimir_alertmanager.arn,
      "${aws_s3_bucket.mimir_alertmanager.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "grafana_stack_s3" {
  name        = "${var.cluster_name}-grafana-stack-s3"
  description = "Allow Grafana stack components to access S3"
  policy      = data.aws_iam_policy_document.grafana_stack_s3_access.json
}

# 3. IAM Role for EKS Pod Identity
resource "aws_iam_role" "grafana_stack" {
  name = "${var.cluster_name}-grafana-stack"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_stack_s3_attach" {
  role       = aws_iam_role.grafana_stack.name
  policy_arn = aws_iam_policy.grafana_stack_s3.arn
}

# 4. EKS Pod Identity Associations for the LGTM Stack
#    The lgtm-distributed chart creates separate ServiceAccounts for Loki, Tempo,
#    and Mimir, prefixed by the release name (lgtm).
resource "aws_eks_pod_identity_association" "lgtm_loki" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "lgtm-loki"
  role_arn        = aws_iam_role.grafana_stack.arn
}

resource "aws_eks_pod_identity_association" "lgtm_tempo" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "lgtm-tempo"
  role_arn        = aws_iam_role.grafana_stack.arn
}

resource "aws_eks_pod_identity_association" "lgtm_mimir" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "lgtm-mimir"
  role_arn        = aws_iam_role.grafana_stack.arn
}


