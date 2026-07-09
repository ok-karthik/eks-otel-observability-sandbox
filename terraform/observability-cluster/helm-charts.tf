
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
