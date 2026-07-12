
# ==============================================================================
# Helm Releases — Observability Cluster
#
# Install dependency order:
#   cert-manager  →  otel-operator      (webhook TLS)
#   aws-lb-controller                   (Pod Identity must exist first)
#   lgtm (all-in-one)                   (S3 IAM must exist first)
#   karpenter  →  karpenter-provisioner
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. cert-manager
#    Required by OTel Operator for webhook TLS certificates.
#    atomic=true    — rolls back on failure; keeps state clean for re-apply.
#    wait_for_jobs  — waits for the CRD-install Job to complete before Terraform
#                     marks this resource done. Without this, OTel Operator
#                     fires before CRDs exist and the webhook admission call fails.
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
  timeout       = 600 # fresh spot nodes need time to pull images + run startupapicheck Job

  # installCRDs is the correct value name for cert-manager v1.14.x.
  # crds.enabled was introduced in v1.15+. Using the wrong key silently
  # skips CRD installation, causing OTel Operator webhook to fail.
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

# 3.1 AWS LB Controller — IAM
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
# 4. LGTM All-in-One Stack  (grafana/lgtm chart)
#
#    Single Helm release — Grafana + Loki + Tempo + Mimir running as
#    lightweight single-binary instances backed by S3.
#
#    ~8 pods total, fits on t3.medium × 2 nodes.
#    Install time: ~3-4 minutes.
#
#    For production-grade distributed topology (separate charts, per-component
#    replicas, zone-aware replication) see the feat/lgtm-distributed branch.
# ==============================================================================
resource "helm_release" "lgtm" {
  count = var.deploy_observability_stack ? 1 : 0

  name             = "lgtm"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "lgtm-distributed"
  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

  # ── S3 storage config (using sets for simple direct injection) ─────────────
  set {
    name  = "loki.loki.storage.type"
    value = "s3"
  }
  set {
    name  = "loki.loki.storage.s3.region"
    value = var.aws_region
  }
  set {
    name  = "loki.loki.storage.bucketNames.chunks"
    value = aws_s3_bucket.loki_data.bucket
  }
  set {
    name  = "loki.loki.storage.bucketNames.ruler"
    value = aws_s3_bucket.loki_data.bucket
  }
  set {
    name  = "loki.loki.storage.bucketNames.admin"
    value = aws_s3_bucket.loki_data.bucket
  }
  set {
    name  = "loki.loki.auth_enabled"
    value = "false"
  }
  set {
    name  = "loki.loki.useTestSchema"
    value = "true"
  }
  set {
    name  = "loki.minio.enabled"
    value = "false"
  }

  set {
    name  = "tempo.tempo.storage.trace.backend"
    value = "s3"
  }
  set {
    name  = "tempo.tempo.storage.trace.s3.bucket"
    value = aws_s3_bucket.tempo_data.bucket
  }
  set {
    name  = "tempo.tempo.storage.trace.s3.endpoint"
    value = "s3.${var.aws_region}.amazonaws.com"
  }
  set {
    name  = "tempo.tempo.storage.trace.s3.region"
    value = var.aws_region
  }

  set {
    name  = "mimir.mimir.structuredConfig.blocks_storage.backend"
    value = "s3"
  }
  set {
    name  = "mimir.mimir.structuredConfig.blocks_storage.s3.bucket_name"
    value = aws_s3_bucket.mimir_blocks.bucket
  }
  set {
    name  = "mimir.mimir.structuredConfig.blocks_storage.s3.endpoint"
    value = "s3.${var.aws_region}.amazonaws.com"
  }
  set {
    name  = "mimir.mimir.structuredConfig.alertmanager_storage.backend"
    value = "s3"
  }
  set {
    name  = "mimir.mimir.structuredConfig.alertmanager_storage.s3.bucket_name"
    value = aws_s3_bucket.mimir_alertmanager.bucket
  }
  set {
    name  = "mimir.mimir.structuredConfig.alertmanager_storage.s3.endpoint"
    value = "s3.${var.aws_region}.amazonaws.com"
  }
  set {
    name  = "mimir.mimir.structuredConfig.ruler_storage.backend"
    value = "s3"
  }
  set {
    name  = "mimir.mimir.structuredConfig.ruler_storage.s3.bucket_name"
    value = aws_s3_bucket.mimir_ruler.bucket
  }
  set {
    name  = "mimir.mimir.structuredConfig.ruler_storage.s3.endpoint"
    value = "s3.${var.aws_region}.amazonaws.com"
  }
  set {
    name  = "mimir.minio.enabled"
    value = "false"
  }


  # ── Stack Component Tuning and Resource Management ────────────────────────
  values = [
    yamlencode({
      # 1. Loki Sub-chart overrides
      loki = {
        loki = {
          commonConfig = {
            replication_factor = 1
          }
        }
        ingester = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        querier = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        queryFrontend = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        distributor = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        compactor = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }

      # 2. Tempo Sub-chart overrides
      tempo = {
        distributor = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        ingester = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        querier = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        queryFrontend = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        compactor = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        metricsGenerator = {
          enabled = false
        }
      }

      # 3. Mimir Sub-chart overrides
      mimir = {
        mimir = {
          structuredConfig = {
            ingester = {
              ring = {
                replication_factor = 1
              }
            }
          }
        }
        ingester = {
          replicas = 1
          zoneAwareReplication = {
            enabled = false
          }
          resources = {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }
        store_gateway = {
          replicas = 1
          zoneAwareReplication = {
            enabled = false
          }
          resources = {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        distributor = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        querier = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        query_frontend = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        query_scheduler = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        compactor = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        alertmanager = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        ruler = {
          replicas = 1
          resources = {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        overrides_exporter = {
          resources = {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
      }

      # 4. Grafana Sub-chart overrides
      grafana = {
        sidecar = {
          dashboards = {
            enabled = true
            label   = "grafana_dashboard"
          }
        }
        resources = {
          requests = {
            cpu    = "25m"
            memory = "128Mi"
          }
          limits = {
            memory = "256Mi"
          }
        }
        datasources = {
          "datasources.yaml" = {
            apiVersion = 1
            datasources = [
              {
                name      = "Mimir (Prometheus)"
                type      = "prometheus"
                access    = "proxy"
                url       = "http://lgtm-mimir-nginx.monitoring.svc.cluster.local/prometheus"
                uid       = "prometheus"
                isDefault = true
              },
              {
                name   = "Loki"
                type   = "loki"
                access = "proxy"
                url    = "http://lgtm-loki.monitoring.svc.cluster.local:3100"
                uid    = "loki"
              },
              {
                name   = "Tempo"
                type   = "tempo"
                access = "proxy"
                url    = "http://lgtm-tempo.monitoring.svc.cluster.local:3200"
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
      }
    })
  ]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.lgtm_loki,
    aws_eks_pod_identity_association.lgtm_tempo,
    aws_eks_pod_identity_association.lgtm_mimir,
    helm_release.cert_manager,
  ]
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
