
# ==============================================================================
# Helm Releases — Observability Cluster
#
# All four LGTM components are deployed using their individual official Helm charts.
# Loki and Tempo are run in monolithic (single-pod) mode. Mimir is run using the
# mimir-distributed chart but scaled down to single-replica, low-resource mode.
# This yields a total of only ~11 pods, which fits cleanly on 2x t3.medium nodes.
#
# Install dependency order:
#   cert-manager  →  otel-operator      (webhook TLS)
#   aws-lb-controller                   (Pod Identity must exist first)
#   loki / tempo / mimir / grafana      (S3 IAM must exist first)
#   karpenter  →  karpenter-provisioner
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. cert-manager
# ------------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.5"
  namespace        = "cert-manager"
  create_namespace = true

  wait          = true
  atomic        = true
  wait_for_jobs = true
  timeout       = 600

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "resources.requests.memory"
    value = "32Mi"
  }
  set {
    name  = "webhook.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "webhook.resources.requests.memory"
    value = "32Mi"
  }
  set {
    name  = "cainjector.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "cainjector.resources.requests.memory"
    value = "32Mi"
  }

  depends_on = [module.eks]
}

# ------------------------------------------------------------------------------
# 2. OpenTelemetry Operator
# ------------------------------------------------------------------------------
resource "helm_release" "otel_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  namespace        = "opentelemetry-operator-system"
  create_namespace = true

  wait    = true
  atomic  = true
  timeout = 300

  set {
    name  = "manager.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "manager.resources.requests.memory"
    value = "64Mi"
  }

  depends_on = [helm_release.cert_manager, module.eks]
}

# ------------------------------------------------------------------------------
# 3. AWS Load Balancer Controller
# ------------------------------------------------------------------------------
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  wait    = true
  atomic  = true
  timeout = 180

  set {
    name  = "clusterName"
    value = var.cluster_name
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
  set {
    name  = "replicaCount"
    value = "1"
  }
  set {
    name  = "resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }

  depends_on = [helm_release.cert_manager, module.eks, aws_eks_pod_identity_association.aws_lb_controller]
}

# 3.1 AWS LB Controller — IAM (fetched from main branch to include DescribeListenerAttributes)
data "http" "aws_lb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "aws_lb_controller" {
  name        = "${var.cluster_name}-aws-lb-controller-policy"
  path        = "/"
  description = "IAM policy for the AWS Load Balancer Controller in EKS"
  policy      = data.http.aws_lb_controller_iam_policy.response_body
}

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

resource "aws_iam_role_policy_attachment" "aws_lb_controller" {
  policy_arn = aws_iam_policy.aws_lb_controller.arn
  role       = aws_iam_role.aws_lb_controller.name
}

resource "aws_eks_pod_identity_association" "aws_lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_lb_controller.arn
}

# ==============================================================================
# Observatory Backends — Individual Monolithic and Downscaled Charts
# ==============================================================================

# ------------------------------------------------------------------------------
# 4. Loki (grafana/loki chart — SingleBinary mode)
#    Deploys exactly 1 pod.
# ------------------------------------------------------------------------------
resource "helm_release" "loki" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

  set {
    name  = "deploymentMode"
    value = "SingleBinary"
  }
  set {
    name  = "singleBinary.replicas"
    value = "1"
  }
  set {
    name  = "read.replicas"
    value = "0"
  }
  set {
    name  = "write.replicas"
    value = "0"
  }
  set {
    name  = "backend.replicas"
    value = "0"
  }
  set {
    name  = "loki.auth_enabled"
    value = "false"
  }
  set {
    name  = "loki.useTestSchema"
    value = "true"
  }
  set {
    name  = "loki.commonConfig.replication_factor"
    value = "1"
  }
  set {
    name  = "loki.storage.type"
    value = "s3"
  }
  set {
    name  = "loki.storage.s3.region"
    value = var.aws_region
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
  set {
    name  = "minio.enabled"
    value = "false"
  }

  set {
    name  = "singleBinary.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "singleBinary.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "singleBinary.resources.limits.memory"
    value = "256Mi"
  }

  depends_on = [module.eks, aws_eks_pod_identity_association.loki]
}

# ------------------------------------------------------------------------------
# 5. Tempo (grafana/tempo monolithic chart)
#    Deploys exactly 1 pod.
# ------------------------------------------------------------------------------
resource "helm_release" "tempo" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo"
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

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
    name  = "storage.trace.s3.region"
    value = var.aws_region
  }
  set {
    name  = "tempo.metricsGenerator.enabled"
    value = "false"
  }
  set {
    name  = "tempo.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "tempo.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "tempo.resources.limits.memory"
    value = "256Mi"
  }

  values = [
    yamlencode({
      traces = {
        otlp = {
          grpc = {
            enabled = true
          }
        }
      }
    })
  ]

  depends_on = [module.eks, aws_eks_pod_identity_association.tempo]
}

# ------------------------------------------------------------------------------
# 6. Mimir (grafana/mimir-distributed chart — downscaled)
#    Deploys ~9 pods total. Alertmanager and Ruler are disabled to save resources.
# ------------------------------------------------------------------------------
resource "helm_release" "mimir" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "mimir"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "mimir-distributed"
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 900

  # Disable HA replication and Alertmanager/Ruler to keep it extremely light
  set {
    name  = "ingester.zoneAwareReplication.enabled"
    value = "false"
  }
  set {
    name  = "store_gateway.zoneAwareReplication.enabled"
    value = "false"
  }
  set {
    name  = "alertmanager.enabled"
    value = "false"
  }
  set {
    name  = "ruler.enabled"
    value = "false"
  }

  set {
    name  = "ingester.replicas"
    value = "1"
  }
  set {
    name  = "distributor.replicas"
    value = "1"
  }
  set {
    name  = "querier.replicas"
    value = "1"
  }
  set {
    name  = "query_frontend.replicas"
    value = "1"
  }
  set {
    name  = "query_scheduler.replicas"
    value = "1"
  }
  set {
    name  = "store_gateway.replicas"
    value = "1"
  }
  set {
    name  = "compactor.replicas"
    value = "1"
  }

  set {
    name  = "mimir.structuredConfig.ingester.ring.replication_factor"
    value = "1"
  }

  # S3 configurations
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
  set {
    name  = "minio.enabled"
    value = "false"
  }

  # Resource trims
  set {
    name  = "ingester.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "ingester.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "store_gateway.resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "store_gateway.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "distributor.resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "distributor.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "querier.resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "querier.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "compactor.resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "compactor.resources.requests.memory"
    value = "128Mi"
  }

  depends_on = [module.eks, aws_eks_pod_identity_association.mimir]
}

# ------------------------------------------------------------------------------
# 7. Grafana (grafana/grafana chart)
#    Deploys exactly 1 pod.
# ------------------------------------------------------------------------------
resource "helm_release" "grafana" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "grafana"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "grafana"
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 300

  set {
    name  = "sidecar.dashboards.enabled"
    value = "true"
  }
  set {
    name  = "sidecar.dashboards.label"
    value = "grafana_dashboard"
  }
  set {
    name  = "resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "resources.requests.memory"
    value = "128Mi"
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
              url    = "http://tempo.monitoring.svc.cluster.local:3200"
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
                    { key = "service.name", value = "service_name" }
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
  version          = "1.0.6"

  wait    = true
  atomic  = true
  timeout = 300

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
  set {
    name  = "controller.resources.requests.cpu"
    value = "250m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "512Mi"
  }

  depends_on = [module.eks, module.karpenter]
}

resource "helm_release" "karpenter_provisioner" {
  name      = "karpenter-provisioner"
  chart     = "${path.module}/karpenter-provisioner"
  namespace = "kube-system"

  wait    = true
  timeout = 120

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
