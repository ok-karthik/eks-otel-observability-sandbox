#!/bin/bash
# ==============================================================================
# Install AWS Load Balancer Controller on EKS
# ==============================================================================
# Why it's needed: The AWS Load Balancer Controller watches for 'Ingress' resources
# with the 'alb' class and automatically provisions AWS Application Load Balancers.
#
# Authentication: It uses IAM Roles for Service Accounts (IRSA) to grant the 
# Kubernetes controller pod permission to call AWS APIs (EC2/ELB) to create ALBs.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-production-otel-demo-cluster}"
AWS_REGION="${AWS_REGION:-us-west-2}"

echo "1. Downloading IAM policy for AWS Load Balancer Controller..."
curl -fsSL -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

echo "2. Creating IAM Policy in AWS..."
# Check if policy already exists
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" --output text)

if [ -z "$POLICY_ARN" ]; then
  POLICY_ARN=$(aws iam create-policy \
      --policy-name AWSLoadBalancerControllerIAMPolicy \
      --policy-document file://iam_policy.json \
      --query 'Policy.Arn' \
      --output text)
  echo "Created Policy ARN: $POLICY_ARN"
else
  echo "Policy AWSLoadBalancerControllerIAMPolicy already exists: $POLICY_ARN"
fi

echo "3. Creating IAM Role and Service Account (using eksctl / IRSA)..."
# IRSA associates the IAM policy with the kubernetes service account 'aws-load-balancer-controller'
eksctl create iamserviceaccount \
  --cluster="$CLUSTER_NAME" \
  --region="$AWS_REGION" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn="$POLICY_ARN" \
  --approve || echo "IAM Service Account might already exist, continuing..."

echo "4. Adding EKS Helm Chart repo..."
helm repo add eks https://aws.github.io/eks-charts || true
helm repo update

echo "5. Installing AWS Load Balancer Controller via Helm..."
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

echo "AWS Load Balancer Controller successfully installed!"
