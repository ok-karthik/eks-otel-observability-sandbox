output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "The endpoint URL for the Kubernetes API server"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_arn" {
  description = "The ARN of the EKS cluster"
  value       = aws_eks_cluster.this.arn
}

output "node_group_name" {
  description = "The name of the managed worker node group"
  value       = aws_eks_node_group.this.node_group_name
}

output "kubeconfig_update_command" {
  description = "AWS CLI command to configure local kubectl context"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}

output "golang_checkout_service_repository_url" {
  description = "The ECR repository URL for the Go checkout service"
  value       = aws_ecr_repository.golang_checkout_service.repository_url
}

output "python_payment_service_repository_url" {
  description = "The ECR repository URL for the Python payment service"
  value       = aws_ecr_repository.python_payment_service.repository_url
}

