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

.PHONY: help k8s-create k8s-create-infra k8s-create-helm k8s-destroy k8s-context k8s-deploy-all k8s-deploy-otel k8s-deploy-apps k8s-undeploy-all k8s-dashboards

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "AWS EKS Infrastructure (Terraform):"
	@echo "  k8s-create           Create EKS clusters + deploy Helm charts (two-stage, recommended)"
	@echo "  k8s-create-infra     Stage 1 only — EKS, VPC, IAM, S3 (no Helm). Safe to re-run."
	@echo "  k8s-create-helm      Stage 2 only — Helm charts only. Assumes EKS is already up."
	@echo "  k8s-destroy          Destroy all AWS resources via Terraform"
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
#
# Stage 1 targets only concrete infra resources (VPC, EKS, IAM, S3).
# No helm_release resources are touched until Stage 2, avoiding the
# "Helm provider talks to a not-yet-healthy API server" race condition.
#
# Infra resource targets for BOTH clusters:
INFRA_TARGETS := \
  -target='module.apps_workload_cluster_1' \
  -target='module.observability_cluster.module.eks' \
  -target='module.observability_cluster.module.karpenter' \
  -target='module.observability_cluster.aws_vpc.main' \
  -target='module.observability_cluster.aws_subnet.public' \
  -target='module.observability_cluster.aws_subnet.private' \
  -target='module.observability_cluster.aws_internet_gateway.gw' \
  -target='module.observability_cluster.aws_eip.nat' \
  -target='module.observability_cluster.aws_nat_gateway.nat' \
  -target='module.observability_cluster.aws_route_table.public_rt_otel' \
  -target='module.observability_cluster.aws_route_table.private_rt_otel' \
  -target='module.observability_cluster.aws_route_table_association.public' \
  -target='module.observability_cluster.aws_route_table_association.private' \
  -target='module.observability_cluster.aws_route.private_nat_otel' \
  -target='module.observability_cluster.aws_s3_bucket.loki_data' \
  -target='module.observability_cluster.aws_s3_bucket.tempo_data' \
  -target='module.observability_cluster.aws_s3_bucket.mimir_blocks' \
  -target='module.observability_cluster.aws_s3_bucket.mimir_ruler' \
  -target='module.observability_cluster.aws_s3_bucket.mimir_alertmanager' \
  -target='module.observability_cluster.aws_iam_policy.grafana_stack_s3' \
  -target='module.observability_cluster.aws_iam_role.grafana_stack' \
  -target='module.observability_cluster.aws_iam_role_policy_attachment.grafana_stack_s3_attach' \
  -target='module.observability_cluster.aws_eks_pod_identity_association.lgtm' \
  -target='module.observability_cluster.aws_iam_policy.aws_lb_controller' \
  -target='module.observability_cluster.aws_iam_role.aws_lb_controller' \
  -target='module.observability_cluster.aws_iam_role_policy_attachment.aws_lb_controller' \
  -target='module.observability_cluster.aws_eks_pod_identity_association.aws_lb_controller' \
  -target='aws_vpc_peering_connection.peering' \
  -target='aws_route.apps_to_otel' \
  -target='aws_route.otel_to_apps'

k8s-create: ## Create both EKS clusters and deploy all Helm charts (two-stage)
	@echo "=== Stage 1: Provisioning EKS clusters, VPC, IAM, S3 (no Helm) ==="
	cd terraform && terraform init -upgrade && \
	  terraform apply $(INFRA_TARGETS) \
	    -parallelism=20 \
	    -auto-approve
	@echo ""
	@echo "=== Stage 2: Installing Helm charts (cert-manager, OTel, LGTM, Karpenter) ==="
	cd terraform && \
	  terraform apply \
	    -var="deploy_observability_stack=true" \
	    -parallelism=20 \
	    -auto-approve

k8s-create-infra: ## Stage 1 only — provision EKS infra without Helm charts (for re-runs)
	@echo "=== Stage 1 only: EKS infra ==="
	cd terraform && terraform init -upgrade && \
	  terraform apply $(INFRA_TARGETS) \
	    -parallelism=20 \
	    -auto-approve

k8s-create-helm: ## Stage 2 only — install/upgrade Helm charts (assumes EKS is already up)
	@echo "=== Stage 2 only: Helm charts ==="
	cd terraform && \
	  terraform apply \
	    -var="deploy_observability_stack=true" \
	    -parallelism=20 \
	    -auto-approve

k8s-destroy: ## Destroy all AWS resources
	cd terraform && terraform destroy \
	  -var="deploy_observability_stack=true" \
	  -parallelism=20 \
	  -auto-approve

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
		host=$$(kubectl --context $(OTEL_CLUSTER) get svc svc-nlb-otel-gateway -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
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
	find .tmp-manifests -type f \( -name "*.yaml" -o -name "*.yml" \) | while read -r file; do \
		sed "s|<AWS_ACCOUNT_ID>|$(ACCOUNT_ID)|g" "$$file" > "$$file.tmp"; \
		sed "s|<OTEL_GATEWAY_LB_HOST>|$$OTEL_GATEWAY_LB_HOST|g" "$$file.tmp" > "$$file"; \
		rm -f "$$file.tmp"; \
	done; \
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
