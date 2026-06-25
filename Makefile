# ==============================================================================
# EKS & Local OpenTelemetry Observability Sandbox Makefile
# ==============================================================================

# Variables
CLUSTER_NAME ?= production-otel-demo-cluster
AWS_REGION ?= us-east-1
LOCAL_ENV_DIR = local-env

.PHONY: help local-up local-down local-test k8s-create k8s-destroy k8s-context k8s-infra k8s-deploy k8s-undeploy

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Local Development Targets:"
	@echo "  local-up           Start the local Docker Compose observability stack"
	@echo "  local-down         Stop the local Docker Compose observability stack"
	@echo "  local-test         Send test request to local Go app to generate traces"
	@echo ""
	@echo "AWS EKS Infrastructure Targets:"
	@echo "  k8s-create         Create EKS cluster, node groups, and ECR repos using Terraform"
	@echo "  k8s-destroy        Destroy EKS cluster and all associated AWS resources using Terraform"
	@echo "  k8s-context        Update local kubeconfig to point to EKS cluster"
	@echo ""
	@echo "AWS EKS Targets (OpenTelemetry Operator Method):"
	@echo "  k8s-infra          Install cert-manager, OTel operator, and AWS Ingress Controller on EKS"
	@echo "  k8s-deploy         Apply K8s manifests for apps, Redis, and OTel operator configs"
	@echo "  k8s-undeploy       Remove K8s manifests for apps, Redis, and OTel operator configs"

local-up: ## Start local Docker Compose stack
	cd $(LOCAL_ENV_DIR) && docker compose up --build -d

local-down: ## Stop local Docker Compose stack
	cd $(LOCAL_ENV_DIR) && docker compose down --remove-orphans

local-test: ## Send a curl request to Go app (generates traces)
	curl -i http://localhost:8080/checkout

k8s-create: ## Create AWS EKS cluster and ECR repositories using Terraform
	cd terraform && terraform init && terraform apply

k8s-destroy: ## Destroy AWS EKS cluster and ECR repositories using Terraform
	cd terraform && terraform destroy

k8s-context: ## Update kubeconfig context using AWS CLI
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER_NAME)

k8s-infra: ## Install operator and load balancer controller on EKS
	@echo "Installing cert-manager..."
	bash scripts/install-cert-manager.sh
	@echo "Installing OTel operator..."
	bash scripts/install-otel-operator.sh
	@echo "Installing AWS ALB controller..."
	CLUSTER_NAME=$(CLUSTER_NAME) AWS_REGION=$(AWS_REGION) bash scripts/install-aws-alb-controller.sh

k8s-deploy: ## Apply OTel Operator-based manifests in correct order
	@echo "Applying Namespace configurations..."
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@echo "Applying OTel Operator configs (instrumentation, agent, gateway)..."
	kubectl apply -f k8s/otel/otel-instrumentation.yaml
	kubectl apply -f k8s/otel/otel-collector-daemonset.yaml
	kubectl apply -f k8s/otel/otel-collector-gateway.yaml
	@echo "Applying applications (Redis cache, Go checkout, Python payment)..."
	kubectl apply -f k8s/apps/redis-cache.yaml
	kubectl apply -f k8s/apps/golang-checkout-service.yaml
	kubectl apply -f k8s/apps/python-payment-service.yaml
	@echo "Applying ingress routing..."
	kubectl apply -f k8s/ingress.yaml

k8s-undeploy: ## Delete OTel Operator-based manifests
	kubectl delete -f k8s/ingress.yaml --ignore-not-found=true
	kubectl delete -f k8s/apps/golang-checkout-service.yaml --ignore-not-found=true
	kubectl delete -f k8s/apps/python-payment-service.yaml --ignore-not-found=true
	kubectl delete -f k8s/apps/redis-cache.yaml --ignore-not-found=true
	kubectl delete -f k8s/otel/otel-collector-gateway.yaml --ignore-not-found=true
	kubectl delete -f k8s/otel/otel-collector-daemonset.yaml --ignore-not-found=true
	kubectl delete -f k8s/otel/otel-instrumentation.yaml --ignore-not-found=true


