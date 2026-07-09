# ==============================================================================
# EKS OpenTelemetry Observability Platform Demo Makefile
# ==============================================================================

# Variables
APPS_CLUSTER ?= apps-workload-cluster-1
OTEL_CLUSTER ?= observability-cluster
AWS_REGION ?= us-east-1
APPS_MANIFEST_DIR = apps-workload-cluster-1/k8s-manifests
OBS_MANIFEST_DIR = observability-platform/k8s-manifests
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)

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
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/svc-nlb-otel-gateway.yaml

k8s-deploy-apps:
	@echo "Waiting for Cert-Manager in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
	@echo "Waiting for OTel Operator in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
	@echo "Applying Namespace in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) create namespace monitoring --dry-run=client -o yaml | kubectl --context $(APPS_CLUSTER) apply -f -
	@echo "Checking AWS Account ID..."
	$(eval ACCOUNT_ID := $(if $(AWS_ACCOUNT_ID),$(AWS_ACCOUNT_ID),$(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)))
	@if [ -z "$(ACCOUNT_ID)" ]; then \
		echo "ERROR: Could not retrieve AWS Account ID. Please authenticate with AWS first."; \
		exit 1; \
	fi; \
	echo "Using AWS Account ID: $(ACCOUNT_ID)"; \
	echo "Waiting for OTel Gateway LoadBalancer hostname to be assigned..."; \
	for i in {1..30}; do \
		host=$$(kubectl --context $(OTEL_CLUSTER) get svc otel-collector-gateway-lb -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
		if [ -n "$$host" ]; then \
			echo "Found OTel Gateway LoadBalancer Host: $$host"; \
			OTEL_GATEWAY_LB_HOST=$$host; \
			break; \
		fi; \
		echo "Waiting for LoadBalancer host allocation (attempt $$i/30)..."; \
		sleep 10; \
	done; \
	if [ -z "$$OTEL_GATEWAY_LB_HOST" ]; then \
		echo "ERROR: Timed out waiting for OTel Gateway LoadBalancer hostname."; \
		exit 1; \
	fi; \
	mkdir -p .tmp-manifests; \
	cp -R $(APPS_MANIFEST_DIR)/* .tmp-manifests/; \
	python3 -c "import os; \
for root, dirs, files in os.walk('.tmp-manifests'): \
    for file in files: \
        if file.endswith('.yaml') or file.endswith('.yml'): \
            path = os.path.join(root, file); \
            with open(path, 'r') as f: content = f.read(); \
            content = content.replace('<AWS_ACCOUNT_ID>', '$(ACCOUNT_ID)'); \
            content = content.replace('<OTEL_GATEWAY_LB_HOST>', '$$OTEL_GATEWAY_LB_HOST'); \
            with open(path, 'w') as f: f.write(content)"; \
	echo "Applying rendered OTel Agent, Apps & Ingress in $(APPS_CLUSTER)..."; \
	kubectl --context $(APPS_CLUSTER) apply -R -f .tmp-manifests/; \
	rm -rf .tmp-manifests

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
