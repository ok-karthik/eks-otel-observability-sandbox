# Dashboard & Alert Generators

Provides blueprints for managing dashboards and alert rules at scale using two patterns:

1. **Decentralized GitOps (K8s CRDs - Recommended)**: App developers define Service Level Objectives (SLOs) and thresholds in their application repository's `values.yaml`. Rules (`PrometheusRule`) and dashboards (`GrafanaDashboard`) are automatically provisioned via Operators (e.g. ArgoCD).
2. **Centralized Infrastructure as Code (Terraform)**: Telemetry configs are managed centrally in a single IaC repository. Useful for SaaS setups (e.g., Datadog) but can introduce pull-request bottlenecks at scale.
3. **Datadog Operator**: A middleground where developers define `DatadogMonitor` CRDs locally in the application repo, which the operator syncs to the Datadog API.

## Recommended Model

For 1000+ services, use decentralized GitOps with platform-owned Helm templates:

- App teams set service name, ownership, SLO targets, and alert thresholds in values.
- The platform chart renders dashboards and alert rules consistently.
- Argo CD or Flux applies the generated resources.
- Platform teams review the template once instead of reviewing every dashboard by hand.

This keeps onboarding self-service while preserving standard naming, labels, severity, and routing.
