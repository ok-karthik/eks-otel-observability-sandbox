# ==============================================================================
# EKS OpenTelemetry Observability Platform Demo Makefile
# ==============================================================================

# Variables
APPS_CLUSTER ?= apps-workload-cluster-1
OTEL_CLUSTER ?= observability-cluster
AWS_REGION ?= us-east-1
APPS_MANIFEST_DIR = apps-workload-cluster-1/k8s-manifests
OBS_MANIFEST_DIR = observability-platform/k8s-manifests

.PHONY: help k8s-create k8s-destroy k8s-context k8s-deploy-all k8s-deploy-otel k8s-deploy-apps k8s-undeploy-all k8s-dashboards

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "AWS EKS Infrastructure (Terraform):"
	@echo "  k8s-create           Create both EKS clusters and ECR repos via parent Terraform"
	@echo "  k8s-destroy          Destroy all AWS resources via parent Terraform"
	@echo "  k8s-context          Update kubeconfig context for both EKS clusters"
	@echo ""
	@echo "Deploying Observability (Multi-Cluster):"
	@echo "  k8s-deploy-all       Deploy both the Otel Gateway stack and the microservices stack"
	@echo "  k8s-deploy-otel      Apply LGTM, Gateway, and LB Service to the observability cluster"
	@echo "  k8s-deploy-apps      Apply DaemonSet, Instrumentation, and apps to the workload cluster"
	@echo "  k8s-undeploy-all     Remove manifests from both clusters"
	@echo "  k8s-dashboards       Port-forward dashboards from the observability cluster"

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
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/grafana-dashboards-configmap.yaml
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/grafana-lgtm.yaml
	@echo "Applying Ingress for Grafana in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/grafana-ingress.yaml
	@echo "Applying Gateway in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/otel-collector-gateway.yaml
	@echo "Exposing Gateway via AWS NLB in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/otel-collector-gateway-lb.yaml

k8s-deploy-apps:
	@echo "Waiting for Cert-Manager in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
	@echo "Waiting for OTel Operator in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
	@echo "Applying Namespace in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) create namespace monitoring --dry-run=client -o yaml | kubectl --context $(APPS_CLUSTER) apply -f -
	@echo "Applying OTel Agent & Instrumentation in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) apply -f $(APPS_MANIFEST_DIR)/otel-collector-daemonset.yaml
	@echo "Applying Common Applications, Ingress in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) apply -f $(APPS_MANIFEST_DIR)/

k8s-undeploy-all:
	kubectl --context $(APPS_CLUSTER) delete -f $(APPS_MANIFEST_DIR)/golang-app/app-ingress.yaml --ignore-not-found=true
	kubectl --context $(APPS_CLUSTER) delete -f $(APPS_MANIFEST_DIR)/ --ignore-not-found=true
	kubectl --context $(OTEL_CLUSTER) delete -f $(OBS_MANIFEST_DIR)/ --ignore-not-found=true

# ==============================================================================
# Cleanup & Dashboard Access
# ==============================================================================
k8s-dashboards:
	@echo "Forwarding Grafana UI to http://localhost:3000 (from EKS $(OTEL_CLUSTER))..."
	@kubectl --context $(OTEL_CLUSTER) port-forward -n monitoring svc/lgtm 3000:3000
