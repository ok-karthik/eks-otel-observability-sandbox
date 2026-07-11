
# 1. Deploy Cert-Manager (Required by OTel Operator for webhook TLS certificates)
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  # Enforce correct destruction order (Helm uninstalled before nodes are deleted)
  depends_on = [module.eks]
}

# 2. Deploy the OpenTelemetry Operator
resource "helm_release" "otel_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  namespace        = "opentelemetry-operator-system"
  create_namespace = true

  # Ensure cert-manager is fully running and nodes are active before installing
  depends_on = [helm_release.cert_manager, module.eks]
}

# 3. Deploy the AWS Load Balancer Controller via Helm
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = var.cluster_name # Your EKS Cluster Name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "vpcId"
    value = aws_vpc.main.id
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  # Ensure the cert-manager, pod identity agent, and nodes are ready before installing
  # EKS module handles certs and pod-identity-agent natively
  depends_on = [helm_release.cert_manager, module.eks]
}

# 4.0. Fetch the official AWS Load Balancer Controller IAM Policy and create IAM Policy
data "http" "aws_lb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "aws_lb_controller" {
  name        = "${var.cluster_name}-aws-lb-controller-policy"
  path        = "/"
  description = "IAM policy for the AWS Load Balancer Controller in EKS"
  policy      = data.http.aws_lb_controller_iam_policy.response_body
}

# 4.1. Create the IAM Role with the EKS Pod Identity trust relationship
resource "aws_iam_role" "aws_lb_controller" {
  name = "${var.cluster_name}-aws-lb-controller"

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

# 4.2. Attach the Load Balancer Controller IAM Policy to the Role
resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  policy_arn = aws_iam_policy.aws_lb_controller.arn # Same policy from before
  role       = aws_iam_role.aws_lb_controller.name
}

# 4.3. Associate the Role with the Service Account
resource "aws_eks_pod_identity_association" "aws_lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_lb_controller.arn
}

# 5. Grafana Stack
resource "helm_release" "loki" {
  count            = var.deploy_observability_stack ? 1 : 0
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900
  wait             = false

  set {
    name  = "loki.useTestSchema"
    value = "true"
  }

  set {
    name  = "loki.auth_enabled"
    value = "false"
  }

  set {
    name  = "loki.storage.type"
    value = "s3"
  }
  set {
    name  = "loki.storage.s3.s3"
    value = "s3://${var.aws_region}/${aws_s3_bucket.loki_data.bucket}"
  }
  set {
    name  = "loki.storage.bucketNames.chunks"
    value = aws_s3_bucket.loki_data.bucket
  }
  set {
    name  = "loki.storage.bucketNames.ruler"
    value = aws_s3_bucket.loki_data.bucket
  }
  set {
    name  = "loki.storage.bucketNames.admin"
    value = aws_s3_bucket.loki_data.bucket
  }
  
  depends_on = [module.eks, aws_eks_pod_identity_association.loki]
}

resource "helm_release" "tempo" {
  count            = var.deploy_observability_stack ? 1 : 0
  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo-distributed"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900
  wait             = false

  set {
    name  = "storage.trace.backend"
    value = "s3"
  }
  set {
    name  = "storage.trace.s3.bucket"
    value = aws_s3_bucket.tempo_data.bucket
  }
  set {
    name  = "storage.trace.s3.endpoint"
    value = "s3.${var.aws_region}.amazonaws.com"
  }

  set {
    name  = "traces.otlp.grpc.enabled"
    value = "true"
  }

  depends_on = [module.eks, aws_eks_pod_identity_association.tempo]
}

resource "helm_release" "mimir" {
  count            = var.deploy_observability_stack ? 1 : 0
  name             = "mimir"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "mimir-distributed"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900
  wait             = false

  set {
    name  = "mimir.structuredConfig.blocks_storage.backend"
    value = "s3"
  }
  set {
    name  = "mimir.structuredConfig.blocks_storage.s3.bucket_name"
    value = aws_s3_bucket.mimir_blocks.bucket
  }
  set {
    name  = "mimir.structuredConfig.blocks_storage.s3.endpoint"
    value = "s3.${var.aws_region}.amazonaws.com"
  }
  set {
    name  = "minio.enabled"
    value = "false"
  }
  set {
    name  = "mimir.structuredConfig.alertmanager_storage.backend"
    value = "s3"
  }
  set {
    name  = "mimir.structuredConfig.alertmanager_storage.s3.bucket_name"
    value = aws_s3_bucket.mimir_alertmanager.bucket
  }
  set {
    name  = "mimir.structuredConfig.alertmanager_storage.s3.endpoint"
    value = "s3.${var.aws_region}.amazonaws.com"
  }
  set {
    name  = "mimir.structuredConfig.ruler_storage.backend"
    value = "s3"
  }
  set {
    name  = "mimir.structuredConfig.ruler_storage.s3.bucket_name"
    value = aws_s3_bucket.mimir_ruler.bucket
  }
  set {
    name  = "mimir.structuredConfig.ruler_storage.s3.endpoint"
    value = "s3.${var.aws_region}.amazonaws.com"
  }

  depends_on = [module.eks, aws_eks_pod_identity_association.mimir]
}

resource "helm_release" "grafana" {
  count            = var.deploy_observability_stack ? 1 : 0
  name             = "grafana"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "grafana"
  namespace        = "monitoring"
  create_namespace = true

  set {
    name  = "sidecar.dashboards.enabled"
    value = "true"
  }

  set {
    name  = "sidecar.dashboards.label"
    value = "grafana_dashboard"
  }

  values = [
    yamlencode({
      datasources = {
        "datasources.yaml" = {
          apiVersion = 1
          datasources = [
            {
              name      = "Mimir (Prometheus)"
              type      = "prometheus"
              access    = "proxy"
              url       = "http://mimir-gateway.monitoring.svc.cluster.local/prometheus"
              uid       = "prometheus"
              isDefault = true
            },
            {
              name   = "Loki"
              type   = "loki"
              access = "proxy"
              url    = "http://loki-gateway.monitoring.svc.cluster.local"
              uid    = "loki"
            },
            {
              name   = "Tempo"
              type   = "tempo"
              access = "proxy"
              url    = "http://tempo-query-frontend.monitoring.svc.cluster.local:3200"
              uid    = "tempo"
              jsonData = {
                tracesToLogsV2 = {
                  datasourceUid      = "loki"
                  spanStartTimeShift = "-1m"
                  spanEndTimeShift   = "1m"
                  filterByTraceID    = true
                  filterBySpanID     = false
                  customQuery        = true
                  query              = "{$${__tags}} |= \"$${__trace.traceId}\""
                  tags = [
                    {
                      key   = "service.name"
                      value = "service_name"
                    }
                  ]
                }
              }
            }
          ]
        }
      }
    })
  ]
  
  depends_on = [module.eks]
}

# ==============================================================================
# Karpenter
# ==============================================================================
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "kube-system"
  create_namespace = true
  version          = "v0.34.0"

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = module.karpenter.service_account
  }

  depends_on = [module.eks, module.karpenter]
}

resource "helm_release" "karpenter_provisioner" {
  name      = "karpenter-provisioner"
  chart     = "${path.module}/karpenter-provisioner"
  namespace = "kube-system"

  set {
    name  = "karpenterRoleName"
    value = module.karpenter.node_iam_role_name
  }
  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "cpuLimit"
    value = var.karpenter_cpu_limit
  }
  set {
    name  = "memoryLimit"
    value = var.karpenter_memory_limit
  }

  depends_on = [helm_release.karpenter]
}
