#!/bin/bash
# ==============================================================================
# Install Cert-Manager on EKS
# ==============================================================================
# Why it's needed: The OpenTelemetry Operator uses Admission Webhooks to validate
# and inject OTel Collector and Instrumentation CRDs. Admission webhooks in Kubernetes
# require HTTPS/TLS certificates. Cert-manager automates the generation, signing,
# and renewal of these local self-signed TLS certificates.
#
# What happens without it: The OpenTelemetry Operator pods will fail to start
# because they cannot register their validation webhooks.

set -euo pipefail

echo "Installing Cert-Manager v1.14.0..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml

echo "Waiting for Cert-Manager pods to become ready..."
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=180s

echo "Cert-Manager is successfully installed and running!"
