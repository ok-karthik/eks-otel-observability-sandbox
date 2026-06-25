#!/bin/bash
# ==============================================================================
# Install OpenTelemetry K8s Operator
# ==============================================================================
# Why it's needed: The OTel Operator manages the lifecycle of collector deployments,
# auto-instruments application pods, and dynamically configures sidecars.
#
# What happens without it: You would have to manually build OTel configurations,
# mount certificates, inject env variables into your application Dockerfiles, 
# and write large, static deployment templates for your collectors.

set -euo pipefail

echo "Adding OpenTelemetry Helm Repository..."
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

echo "Installing OpenTelemetry Operator..."
# We set manager.collectorImage.repository to otel/opentelemetry-collector-contrib
# because the default core image doesn't include the db scrapers (mysql, redis)
# or advanced processors like k8sattributes and tail_sampling.
helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
  --namespace opentelemetry-operator-system --create-namespace

echo "Waiting for OTel Operator deployment to be ready..."
kubectl wait --namespace opentelemetry-operator-system \
  --for=condition=available deployment/opentelemetry-operator \
  --timeout=120s

echo "OpenTelemetry Operator is ready!"
