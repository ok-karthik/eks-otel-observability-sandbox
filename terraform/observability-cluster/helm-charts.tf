
# ==============================================================================
# Helm Releases — Observability Cluster
#
# All four LGTM components are kept as individual distributed Helm charts
# (same charts as production) but configured for single-replica/monolithic
# mode to fit a demo cluster. This preserves the production config topology
# while keeping resource consumption to ~8-12 GB RAM total.
#
# Key resource-reduction techniques applied per chart:
#   Loki           → deploymentMode=SingleBinary (1 pod, same S3 backend)
#   Tempo          → all component replicas=1, metricsGenerator disabled
#   Mimir          → zoneAwareReplication disabled (was secretly 3× replicas),
#                    replication_factor=1, all components at 1 replica
#   Grafana        → replicas=1
#
# Install dependency order (serial):
#   cert-manager → otel-operator (webhook TLS deps)
#   aws-lb-controller            (needs Pod Identity association)
#   loki / tempo / mimir / grafana  (independent, start in parallel)
#   karpenter → karpenter-provisioner
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. cert-manager
#    Required by OTel Operator for webhook TLS certificates.
#    atomic=true    — rolls back on failure so broken CRDs don't block re-apply.
#    wait_for_jobs  — waits for the CRD-install Job before marking done.
#                     Without this, OTel Operator fires before CRDs exist
#                     and the ValidatingWebhookConfiguration rejects its install.
# ------------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.5" # pin for repeatability
  namespace        = "cert-manager"
  create_namespace = true

  wait          = true
  atomic        = true
  wait_for_jobs = true
  timeout       = 300

  set {
    name  = "crds.enabled"
    value = "true"
  }

  # Lean resource requests — adequate for a demo cluster
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
#    Depends on cert-manager being fully healthy (CRDs registered, webhook live).
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
  # Single replica is sufficient for a demo
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

# ------------------------------------------------------------------------------
# 3.1 AWS LB Controller — IAM resources (pinned policy version)
# ------------------------------------------------------------------------------
data "http" "aws_lb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json"
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
# LGTM Stack — Individual Distributed Helm Charts
#
# All four are gated behind deploy_observability_stack so Stage 1 never
# touches them. They are independent of each other so Terraform will
# apply them in parallel (up to -parallelism=20).
# ==============================================================================

# ------------------------------------------------------------------------------
# 4. Loki  (grafana/loki chart — distributed chart, SingleBinary deploy mode)
#
#    deploymentMode=SingleBinary runs all Loki roles in one pod (distributor,
#    ingester, querier, etc.) while still using the full S3 backend. This is
#    the correct way to run the production Loki chart on a demo cluster —
#    same chart, same config shape, just one replica.
#
#    Resource footprint: ~1 pod, ~256 Mi RAM request
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

  # ── Deployment mode ──────────────────────────────────────────────────────
  set {
    name  = "deploymentMode"
    value = "SingleBinary"
  }
  set {
    name  = "singleBinary.replicas"
    value = "1"
  }
  # Disable the distributed read/write/backend components that are not
  # needed in SingleBinary mode — they would otherwise be created with 0
  # replicas but still generate PodDisruptionBudgets that block upgrades.
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

  # ── Core config ──────────────────────────────────────────────────────────
  set {
    name  = "loki.auth_enabled"
    value = "false"
  }
  set {
    name  = "loki.useTestSchema"
    value = "true"
  }
  # Replication factor 1 for demo — no need for HA
  set {
    name  = "loki.commonConfig.replication_factor"
    value = "1"
  }

  # ── S3 storage ───────────────────────────────────────────────────────────
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

  # ── Disable bundled MinIO (using AWS S3 directly) ─────────────────────
  set {
    name  = "minio.enabled"
    value = "false"
  }

  # ── Resource requests (demo-sized) ───────────────────────────────────────
  set {
    name  = "singleBinary.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "singleBinary.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "singleBinary.resources.limits.memory"
    value = "512Mi"
  }

  depends_on = [module.eks, aws_eks_pod_identity_association.loki]
}

# ------------------------------------------------------------------------------
# 5. Tempo Distributed  (grafana/tempo-distributed)
#
#    All components at replicas=1. metricsGenerator disabled (optional
#    component that adds ~128 Mi RAM and requires Prometheus remote-write).
#    Service account "tempo" maps to the shared grafana_stack S3 IAM role.
#
#    Resource footprint: ~5 pods, ~640 Mi RAM request total
# ------------------------------------------------------------------------------
resource "helm_release" "tempo" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo-distributed"
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

  # ── Component replicas — all at 1 for demo ────────────────────────────
  set {
    name  = "distributor.replicas"
    value = "1"
  }
  set {
    name  = "ingester.replicas"
    value = "1"
  }
  set {
    name  = "querier.replicas"
    value = "1"
  }
  set {
    name  = "queryFrontend.replicas"
    value = "1"
  }
  set {
    name  = "compactor.replicas"
    value = "1"
  }
  # metricsGenerator is optional — skip to save ~128 Mi and avoid
  # needing a Prometheus remote-write endpoint wired up
  set {
    name  = "metricsGenerator.enabled"
    value = "false"
  }

  # ── S3 trace storage ─────────────────────────────────────────────────
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

  # ── Enable OTLP gRPC receiver ─────────────────────────────────────────
  set {
    name  = "traces.otlp.grpc.enabled"
    value = "true"
  }

  # ── Resource requests — per component ────────────────────────────────
  set {
    name  = "distributor.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "distributor.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "ingester.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "ingester.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "querier.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "querier.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "queryFrontend.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "queryFrontend.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "compactor.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "compactor.resources.requests.memory"
    value = "128Mi"
  }

  depends_on = [module.eks, aws_eks_pod_identity_association.tempo]
}

# ------------------------------------------------------------------------------
# 6. Mimir Distributed  (grafana/mimir-distributed)
#
#    TWO critical resource-reduction settings:
#
#    (a) ingester.zoneAwareReplication.enabled = false
#        By default, Mimir replicates ingesters across 3 zones, creating
#        3 ingester pods even when replicas=1. Disabling this drops to 1 pod.
#        Default ingester memory limit is 4.8 Gi — on t3.medium this single
#        pod would fill an entire node. We override to 1 Gi.
#
#    (b) store_gateway.zoneAwareReplication.enabled = false
#        Same issue: 3 store-gateway pods by default. Disable for demo.
#
#    (c) replication_factor = 1
#        Without this, Mimir requires 3 ingester replicas to satisfy its
#        quorum requirement and rejects writes when only 1 is running.
#
#    Resource footprint after fixes: ~9 pods, ~2.5 Gi RAM request total
# ------------------------------------------------------------------------------
resource "helm_release" "mimir" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "mimir"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "mimir-distributed"
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 900 # Mimir has the most components; give it 15 min

  # ── Zone-aware replication: DISABLE for demo ──────────────────────────
  # This is the #1 hidden resource killer. Default: 3 zones × replicas.
  set {
    name  = "ingester.zoneAwareReplication.enabled"
    value = "false"
  }
  set {
    name  = "store_gateway.zoneAwareReplication.enabled"
    value = "false"
  }

  # ── Component replicas — all at 1 ────────────────────────────────────
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
    name  = "alertmanager.replicas"
    value = "1"
  }
  set {
    name  = "ruler.replicas"
    value = "1"
  }

  # ── Replication factor: 1 for single-replica setup ────────────────────
  # Without this, Mimir requires 3 ingesters for quorum and will refuse
  # writes when running only 1 ingester replica.
  set {
    name  = "mimir.structuredConfig.ingester.ring.replication_factor"
    value = "1"
  }

  # ── S3 backends ───────────────────────────────────────────────────────
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
    name  = "mimir.structuredConfig.blocks_storage.s3.region"
    value = var.aws_region
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

  # ── Disable bundled MinIO ─────────────────────────────────────────────
  set {
    name  = "minio.enabled"
    value = "false"
  }

  # ── Resource requests — override heavy defaults ────────────────────────
  # Mimir's production defaults are intentionally large (ingester: 4.8 Gi).
  # These values are appropriate for a demo/staging environment.
  set {
    name  = "ingester.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "ingester.resources.requests.memory"
    value = "512Mi"
  }
  set {
    name  = "ingester.resources.limits.memory"
    value = "1Gi"
  }
  set {
    name  = "distributor.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "distributor.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "querier.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "querier.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "query_frontend.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "query_frontend.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "query_scheduler.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "query_scheduler.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "store_gateway.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "store_gateway.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "store_gateway.resources.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "compactor.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "compactor.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "compactor.resources.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "ruler.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "ruler.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "alertmanager.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "alertmanager.resources.requests.memory"
    value = "128Mi"
  }

  depends_on = [module.eks, aws_eks_pod_identity_association.mimir]
}

# ------------------------------------------------------------------------------
# 7. Grafana  (standalone chart, datasources pre-wired to co-located LGTM)
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
    value = "50m"
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
              url       = "http://mimir-nginx.monitoring.svc.cluster.local/prometheus"
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

# ------------------------------------------------------------------------------
# 8. Karpenter controller
#    Pinned to 1.0.6 (stable v1 release — aligns with karpenter.sh/v1 CRDs in
#    the provisioner chart below). Pod Identity association is handled by
#    module.karpenter in eks.tf.
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 9. Karpenter Provisioner (NodePool + EC2NodeClass)
#    Local Helm chart rendering the karpenter.sh/v1 manifests.
# ------------------------------------------------------------------------------
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
