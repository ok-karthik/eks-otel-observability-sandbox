# ==============================================================================
# EKS & Local OpenTelemetry Observability Sandbox Makefile
# ==============================================================================

# Variables
CLUSTER_NAME ?= production-otel-demo-cluster
AWS_REGION ?= us-east-1
LOCAL_ENV_DIR = local-env

.PHONY: help local-up local-down local-test k8s-context k8s-infra k8s-deploy k8s-undeploy k8s-deploy-raw k8s-undeploy-raw

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Local Development Targets:"
	@echo "  local-up           Start the local Docker Compose observability stack"
	@echo "  local-down         Stop the local Docker Compose observability stack"
	@echo "  local-test         Send test request to local Go app to generate traces"
	@echo ""
	@echo "AWS EKS Targets (OpenTelemetry Operator Method):"
	@echo "  k8s-context        Update local kubeconfig to point to EKS cluster"
	@echo "  k8s-infra          Install cert-manager, OTel operator, and AWS Ingress Controller on EKS"
	@echo "  k8s-deploy         Apply K8s manifests for apps, Redis, and OTel operator configs"
	@echo "  k8s-undeploy       Remove K8s manifests for apps, Redis, and OTel operator configs"
	@echo ""
	@echo "AWS EKS Targets (Raw Kubernetes Manifests Method - Operator-free):"
	@echo "  k8s-deploy-raw     Apply Raw K8s configs (ConfigMaps, DaemonSet, Gateway Deployment)"
	@echo "  k8s-undeploy-raw   Remove Raw K8s configs"

local-up: ## Start local Docker Compose stack
	cd $(LOCAL_ENV_DIR) && docker compose up --build -d

local-down: ## Stop local Docker Compose stack
	cd $(LOCAL_ENV_DIR) && docker compose down --remove-orphans

local-test: ## Send a curl request to Go app (generates traces)
	curl -i http://localhost:8080/checkout

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

k8s-deploy-raw: ## Apply Raw Kubernetes manifests (No Operator required)
	@echo "Applying Namespace configurations..."
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@echo "Applying Raw OTel ConfigMaps, DaemonSet, and Gateway Deployment..."
	kubectl apply -f k8s/otel-raw/otel-agent-config.yaml
	kubectl apply -f k8s/otel-raw/otel-agent-daemonset.yaml
	kubectl apply -f k8s/otel-raw/otel-gateway-config.yaml
	kubectl apply -f k8s/otel-raw/otel-gateway-deployment.yaml
	@echo "Applying applications (Redis cache, Go checkout, Python payment)..."
	kubectl apply -f k8s/apps/redis-cache.yaml
	kubectl apply -f k8s/apps/golang-checkout-service.yaml
	kubectl apply -f k8s/apps/python-payment-service.yaml
	@echo "Applying ingress routing..."
	kubectl apply -f k8s/ingress.yaml

k8s-undeploy-raw: ## Delete Raw Kubernetes manifests
	kubectl delete -f k8s/ingress.yaml --ignore-not-found=true
	kubectl delete -f k8s/apps/golang-checkout-service.yaml --ignore-not-found=true
	kubectl delete -f k8s/apps/python-payment-service.yaml --ignore-not-found=true
	kubectl delete -f k8s/apps/redis-cache.yaml --ignore-not-found=true
	kubectl delete -f k8s/otel-raw/otel-gateway-deployment.yaml --ignore-not-found=true
	kubectl delete -f k8s/otel-raw/otel-gateway-config.yaml --ignore-not-found=true
	kubectl delete -f k8s/otel-raw/otel-agent-daemonset.yaml --ignore-not-found=true
	kubectl delete -f k8s/otel-raw/otel-agent-config.yaml --ignore-not-found=true
