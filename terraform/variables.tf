variable "aws_region" {
  description = "AWS target deployment region"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "production-otel-demo-cluster"
}

variable "vpc_id" {
  description = "VPC ID for EKS nodes and control plane elastic interfaces"
  type        = string
}

variable "subnet_ids" {
  description = "List of private subnet IDs for EKS node interfaces"
  type        = list(string)
}

variable "node_group_name" {
  description = "Name of the EKS managed node group"
  type        = string
  default     = "general-compute-nodes"
}

variable "node_group_instance_types" {
  description = "EC2 instance types for the worker nodes"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_group_desired_capacity" {
  description = "Initial number of nodes in the node group"
  type        = number
  default     = 2
}

variable "node_group_min_size" {
  description = "Minimum number of nodes for autoscaling"
  type        = number
  default     = 1
}

variable "node_group_max_size" {
  description = "Maximum number of nodes for autoscaling"
  type        = number
  default     = 4
}

variable "node_group_type" {
  description = "Pricing model for EKS worker nodes (spot or on-demand)"
  type        = string
  default     = "on-demand"
}
