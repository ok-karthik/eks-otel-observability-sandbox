# ==============================================================================
# EKS & Local OpenTelemetry Observability Sandbox Makefile
# ==============================================================================

# Variables
APPS_CLUSTER ?= apps-cluster-1
OTEL_CLUSTER ?= otel-cluster
AWS_REGION ?= us-east-1
LOCAL_ENV_DIR = local-env

.PHONY: help local-up local-down local-test k8s-create k8s-destroy k8s-context k8s-deploy-otel k8s-deploy-apps k8s-undeploy-all k8s-dashboards local-k3d-setup local-k3d-destroy

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "Docker Compose Sandbox (Single Machine):"
	@echo "  local-up             Start the local Docker Compose observability stack"
	@echo "  local-down           Stop the local Docker Compose observability stack"
	@echo "  local-test           Send test request to local Go app to generate traces"
	@echo ""
	@echo "Local Multi-Cluster Simulation (k3d + OrbStack):"
	@echo "  local-k3d-setup      Create two local k3d Kubernetes clusters (peered on Docker network)"
	@echo "  local-k3d-destroy    Teardown local k3d clusters"
	@echo ""
	@echo "AWS EKS Infrastructure (Terraform):"
	@echo "  k8s-create           Create both EKS clusters and ECR repos via parent Terraform"
	@echo "  k8s-destroy          Destroy all AWS resources via parent Terraform"
	@echo "  k8s-context          Update kubeconfig context for both EKS clusters"
	@echo ""
	@echo "Deploying Observability (Multi-Cluster):"
	@echo "  k8s-deploy-all       Deploy both the Otel Gateway stack and the microservices stack"
	@echo "  k8s-deploy-otel      Apply LGTM, Gateway, and LB Service to the otel-cluster"
	@echo "  k8s-deploy-apps      Apply DaemonSet, Instrumentation, apps, and Redis to apps-cluster"
	@echo "  k8s-undeploy-all     Remove manifests from both clusters"
	@echo "  k8s-dashboards       Port-forward dashboards from the otel-cluster"

# ==============================================================================
# Docker Compose sandbox
# ==============================================================================
local-up:
	cd $(LOCAL_ENV_DIR) && docker compose up --build -d

local-down:
	cd $(LOCAL_ENV_DIR) && docker compose down --remove-orphans

local-test:
	curl -i http://localhost:8080/checkout

# ==============================================================================
# k3d Multi-Cluster Simulation (Local & Free)
# ==============================================================================
local-k3d-setup: ## Spin up peered k3d clusters
	@echo "Creating local OTel Cluster..."
	k3d cluster create $(OTEL_CLUSTER) --api-port 6550 --port "8080:80@loadbalancer" --port "3000:3000@loadbalancer" --port "4317:4317@loadbalancer" --port "4318:4318@loadbalancer"
	@echo "Creating local Apps Cluster..."
	k3d cluster create $(APPS_CLUSTER) --api-port 6551 --port "8081:80@loadbalancer"
	@echo "Clusters configured! Contexts: k3d-$(APPS_CLUSTER) and k3d-$(OTEL_CLUSTER)"

local-k3d-destroy: ## Delete local k3d clusters
	k3d cluster delete $(OTEL_CLUSTER)
	k3d cluster delete $(APPS_CLUSTER)

# ==============================================================================
# AWS EKS Infrastructure
# ==============================================================================
k8s-create:
	cd terraform && terraform init && terraform apply

k8s-destroy:
	cd terraform && terraform destroy

k8s-context:
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(APPS_CLUSTER) --alias $(APPS_CLUSTER)
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(OTEL_CLUSTER) --alias $(OTEL_CLUSTER)

# ==============================================================================
# EKS Production Deployment Targets
# ==============================================================================
k8s-deploy-all: k8s-context k8s-deploy-otel k8s-deploy-apps ## Deploy everything to EKS in order

k8s-deploy-otel:
	@echo "Waiting for Cert-Manager in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
	@echo "Waiting for OTel Operator in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) wait --for=condition=Available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
	@echo "Applying Namespace in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) create namespace monitoring --dry-run=client -o yaml | kubectl --context $(OTEL_CLUSTER) apply -f -
	@echo "Applying LGTM stack in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f k8s/otel-cluster/lgtm-dashboards.yaml
	kubectl --context $(OTEL_CLUSTER) apply -f k8s/otel-cluster/lgtm.yaml
	@echo "Applying Ingress for Grafana in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f k8s/otel-cluster/grafana-ingress.yaml
	@echo "Applying Gateway in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f k8s/otel-cluster/otel-collector-gateway.yaml
	@echo "Exposing Gateway via AWS NLB in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f k8s/otel-cluster/otel-collector-gateway-lb.yaml

k8s-deploy-apps:
	@echo "Waiting for Cert-Manager in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
	@echo "Waiting for OTel Operator in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
	@echo "Applying Namespace in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) create namespace monitoring --dry-run=client -o yaml | kubectl --context $(APPS_CLUSTER) apply -f -
	@echo "Applying OTel Agent & Instrumentation in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) apply -f k8s/apps-cluster-1/otel-collector-daemonset.yaml
	kubectl --context $(APPS_CLUSTER) apply -f k8s/apps-cluster-1/otel-instrumentation.yaml
	@echo "Applying Common Applications in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) apply -f k8s/apps-cluster-1/golang-checkout-service.yaml
	kubectl --context $(APPS_CLUSTER) apply -f k8s/apps-cluster-1/python-payment-service.yaml
	@echo "Applying Ingress in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) apply -f k8s/ingress.yaml

k8s-undeploy-all:
	kubectl --context $(APPS_CLUSTER) delete -f k8s/ingress.yaml --ignore-not-found=true
	kubectl --context $(APPS_CLUSTER) delete -f k8s/apps-cluster-1/ --ignore-not-found=true
	kubectl --context $(OTEL_CLUSTER) delete -f k8s/otel-cluster/ --ignore-not-found=true

# ==============================================================================
# Local k3d/OrbStack Deployment Targets
# ==============================================================================
local-deploy-otel:
	@echo "Installing Cert-Manager in local k3d-$(OTEL_CLUSTER)..."
	kubectl --context k3d-$(OTEL_CLUSTER) apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml
	@echo "Waiting for Cert-Manager..."
	kubectl --context k3d-$(OTEL_CLUSTER) wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
	@echo "Installing OTel Operator in local k3d-$(OTEL_CLUSTER)..."
	kubectl --context k3d-$(OTEL_CLUSTER) apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/v0.90.0/opentelemetry-operator.yaml
	@echo "Waiting for OTel Operator..."
	kubectl --context k3d-$(OTEL_CLUSTER) wait --for=condition=Available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
	@echo "Applying Namespace in local k3d-$(OTEL_CLUSTER)..."
	kubectl --context k3d-$(OTEL_CLUSTER) create namespace monitoring --dry-run=client -o yaml | kubectl --context k3d-$(OTEL_CLUSTER) apply -f -
	@echo "Applying LGTM stack..."
	kubectl --context k3d-$(OTEL_CLUSTER) apply -f k8s/otel-cluster/lgtm-dashboards.yaml
	kubectl --context k3d-$(OTEL_CLUSTER) apply -f k8s/otel-cluster/lgtm.yaml
	@echo "Applying Gateway..."
	kubectl --context k3d-$(OTEL_CLUSTER) apply -f k8s/otel-cluster/otel-collector-gateway.yaml
	@echo "Exposing Gateway via local LoadBalancer..."
	kubectl --context k3d-$(OTEL_CLUSTER) apply -f k8s/local/otel-collector-gateway-lb.yaml

local-deploy-apps:
	@echo "Installing Cert-Manager in local k3d-$(APPS_CLUSTER)..."
	kubectl --context k3d-$(APPS_CLUSTER) apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml
	@echo "Waiting for Cert-Manager..."
	kubectl --context k3d-$(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
	@echo "Installing OTel Operator in local k3d-$(APPS_CLUSTER)..."
	kubectl --context k3d-$(APPS_CLUSTER) apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/v0.90.0/opentelemetry-operator.yaml
	@echo "Waiting for OTel Operator..."
	kubectl --context k3d-$(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
	@echo "Applying Namespace in local k3d-$(APPS_CLUSTER)..."
	kubectl --context k3d-$(APPS_CLUSTER) create namespace monitoring --dry-run=client -o yaml | kubectl --context k3d-$(APPS_CLUSTER) apply -f -
	@echo "Applying local OTel Agent & Instrumentation..."
	kubectl --context k3d-$(APPS_CLUSTER) apply -f k8s/local/otel-collector-daemonset.yaml
	kubectl --context k3d-$(APPS_CLUSTER) apply -f k8s/local/apps/otel-instrumentation.yaml
	@echo "Applying Common Applications..."
	kubectl --context k3d-$(APPS_CLUSTER) apply -f k8s/local/apps/golang-checkout-service.yaml
	kubectl --context k3d-$(APPS_CLUSTER) apply -f k8s/local/apps/python-payment-service.yaml
	@echo "Applying Ingress..."
	kubectl --context k3d-$(APPS_CLUSTER) apply -f k8s/ingress.yaml

local-undeploy-all:
	kubectl --context k3d-$(APPS_CLUSTER) delete -f k8s/ingress.yaml --ignore-not-found=true
	kubectl --context k3d-$(APPS_CLUSTER) delete -f k8s/local/apps/ --ignore-not-found=true
	kubectl --context k3d-$(APPS_CLUSTER) delete -f k8s/local/otel-collector-daemonset.yaml --ignore-not-found=true
	kubectl --context k3d-$(OTEL_CLUSTER) delete -f k8s/otel-cluster/lgtm.yaml --ignore-not-found=true
	kubectl --context k3d-$(OTEL_CLUSTER) delete -f k8s/otel-cluster/otel-collector-gateway.yaml --ignore-not-found=true
	kubectl --context k3d-$(OTEL_CLUSTER) delete -f k8s/local/otel-collector-gateway-lb.yaml --ignore-not-found=true

# ==============================================================================
# Cleanup & Dashboard Access
# ==============================================================================
k8s-dashboards:
	@echo "Forwarding Grafana UI to http://localhost:3000 (from EKS $(OTEL_CLUSTER))..."
	@kubectl --context $(OTEL_CLUSTER) port-forward -n monitoring svc/lgtm 3000:3000

local-dashboards:
	@echo "Forwarding Grafana UI to http://localhost:3000 (from local k3d-$(OTEL_CLUSTER))..."
	@kubectl --context k3d-$(OTEL_CLUSTER) port-forward -n monitoring svc/lgtm 3000:3000
