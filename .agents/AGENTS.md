# Agent Instructions and Project Context

This file gives AI agents the project mental model, repo structure, and working rules for this OpenTelemetry observability platform demo.

## Project Mental Model

Treat this repository as a reference implementation for an internal observability product on Amazon EKS.

Although the directories currently live in one repository, reason about them as if they could be separate Git repositories:

- `observability-platform/`: platform-owned observability product templates, gateway policy, routing, dashboards, alerts, and cost controls.
- `apps-workload-cluster-1/`: application-team-owned workload repository that consumes the observability platform.
- `terraform/`: infrastructure provisioning for the workload EKS cluster and the dedicated observability EKS cluster.

The core telemetry flow is:

```text
Application container
  -> OpenTelemetry SDK or auto-instrumentation
  -> workload-cluster OTel Collector DaemonSet
  -> central observability-cluster OTel Gateway
  -> observability backend such as LGTM, Tempo, Loki, Mimir, Datadog, or another vendor
```

For platform-engineering discussions, use this ownership model:

- App teams own service code, service identity, instrumentation quality, SLO intent, alert thresholds, and dashboard values.
- Platform teams own collector baselines, gateway policy, backend integrations, sampling defaults, routing, tenant isolation, templates, and GitOps onboarding patterns.
- Security and FinOps teams rely on centralized controls for secrets, retention, tenant separation, routing, noisy telemetry, and telemetry cost.

## Current Repository Structure

```text
apps-workload-cluster-1/
  apps-src/
    golang-app/                 # Go demo service with programmatic OTel SDK setup
    python-app/                 # Python demo service using OTel auto-instrumentation
  k8s-manifests/
    app-ingress.yaml
    golang-product-service.yaml
    python-product-info-service.yaml
    otel-collector-daemonset.yaml
    otel-instrumentation*.yaml  # OTel Operator Instrumentation CRs

observability-platform/
  README.md
  k8s-manifests/
    grafana-lgtm.yaml
    grafana-ingress.yaml
    grafana-dashboards-configmap.yaml
    otel-collector-gateway.yaml
    otel-collector-gateway-lb.yaml
  routing-and-multitenancy/
    README.md
    otel-gateway-multitenant.yaml
  telemetry-budgeting/
    README.md
    otel-gateway-tail-sampling.yaml
  golden-signals/
    README.md
    go-service-dashboard.json
    python-service-dashboard.json
  dashboard-and-alert-generators/
    README.md
    helm-chart/

terraform/
  apps-workload-cluster-1/       # Workload EKS cluster, ECR, networking, Helm installs
  observability-cluster/         # Dedicated observability EKS cluster and networking
  main.tf

architecture-decisions-and-tradeoffs.md
Makefile
README.md
```

Ignore `.terraform/` generated module/provider content unless explicitly asked to inspect local Terraform state or generated modules.

## Important Configuration Concepts

### Workload Cluster Collector

`apps-workload-cluster-1/k8s-manifests/otel-collector-daemonset.yaml` runs an OpenTelemetry Collector as a DaemonSet.

It is responsible for:

- Receiving OTLP traces, metrics, and logs from workloads.
- Reading pod logs through `filelog`.
- Collecting node/pod metrics through `kubeletstats`.
- Enriching telemetry with Kubernetes metadata using `k8sattributes`.
- Forwarding enriched telemetry to the central observability gateway.

Keep this collector lightweight. It should enrich, batch, and forward. Heavy tail sampling, expensive transforms, backend-specific routing, and policy decisions belong in the gateway layer.

### Application Instrumentation

Python uses OTel Operator auto-instrumentation through pod annotations such as:

```yaml
instrumentation.opentelemetry.io/inject-python: "default-instrumentation"
```

Go uses programmatic SDK setup in `apps-workload-cluster-1/apps-src/golang-app/telemetry.go`.

When adding language templates, prefer:

- Python, Java, Node.js, and .NET: OTel Operator `Instrumentation` CRs and pod annotations.
- Go: SDK helper package, shared bootstrap pattern, or documented code template.

Every service should set stable OpenTelemetry resource attributes:

```text
service.name
service.namespace
service.version
deployment.environment
team
tenant.id
```

These attributes power routing, dashboards, alert labels, ownership, cost allocation, and tenant-aware policy.

### Observability Gateway

`observability-platform/k8s-manifests/otel-collector-gateway.yaml` is the central gateway.

This is where platform policy should live:

- `memory_limiter` for collector self-protection.
- `filter/*` processors for noisy telemetry and health-check drops.
- `transform/*` processors for semantic normalization.
- `tail_sampling` for retaining errors and latency outliers while sampling healthy traffic.
- `batch` for efficient backend export.
- Backend exporters such as LGTM, Tempo, Loki, Mimir, Datadog, or other OTLP endpoints.

Important: if a processor is defined, verify it is also wired into the relevant service pipeline. For example, a `tail_sampling` processor only takes effect when listed in the `traces` pipeline processors.

### Routing and Multitenancy

`observability-platform/routing-and-multitenancy/otel-gateway-multitenant.yaml` demonstrates tenant-aware routing.

The pattern is:

```text
Normalize tenant identity
  -> route by tenant/team/environment/resource attributes
  -> export to a tenant-specific backend, retention tier, or namespace
```

The `transform/tenant` processor ensures `tenant.id` exists, falling back to `service.namespace` and then `unallocated`.

The routing connectors route traces, metrics, and logs based on `resource.attributes["tenant.id"]`.

When extending this, keep app-team inputs simple. App repos should declare service metadata; platform-owned configs should decide where telemetry goes.

### Telemetry Budgeting

`observability-platform/telemetry-budgeting/otel-gateway-tail-sampling.yaml` shows gateway-level cost control.

Use tail sampling to:

- Keep 100% of error traces.
- Keep 100% of high-latency traces.
- Keep important tenant or service traffic.
- Sample down healthy high-volume traffic.

At enterprise scale, consider an ingestion gateway plus Kafka/MSK plus processing gateway pattern for burst tolerance and backend outage protection.

### Dashboards and Alerts

`observability-platform/golden-signals/` contains baseline Grafana dashboards for service golden signals.

`observability-platform/dashboard-and-alert-generators/helm-chart/` demonstrates a GitOps model where:

- Platform owns reusable Helm templates.
- App teams own a small values file containing service name, team, Slack channel, SLOs, and thresholds.
- Argo CD or Flux renders and applies `GrafanaDashboard` and `PrometheusRule` resources.

Prefer self-service app-team onboarding through values and CRDs over hand-crafted dashboards or platform tickets.

## Scale Architecture

Use `architecture-decisions-and-tradeoffs.md` as the main architecture reference.

The preferred production evolution is:

```text
Small demo:
app cluster -> DaemonSet collector -> observability gateway -> LGTM

Enterprise regional platform:
many app clusters -> regional ingestion gateways -> processing gateways -> backends

High burst or backend outage protection:
many app clusters -> ingestion gateways -> Kafka/MSK -> processing gateways -> backends
```

Default to per-region observability deployments. Avoid unnecessary cross-region telemetry transfer because it increases egress cost, latency, and data residency risk.

## Development Guidelines

- Use `rg` and `rg --files` for repository searches.
- Preserve user changes. Do not revert unrelated working-tree changes.
- Keep OpenTelemetry collector pipeline changes explicit: receivers -> processors/connectors -> exporters.
- When changing collector configs, verify that all referenced receivers, processors, connectors, and exporters are actually used in `service.pipelines`.
- When changing Terraform, run `terraform fmt` on modified `.tf` files.
- When changing Kubernetes manifests, preserve the distinction between workload-cluster configs and observability-platform configs.
- When adding utility workflows, expose them through the `Makefile` when appropriate.
- Keep docs updated when changing architecture, ports, service names, cluster names, or onboarding flows.

## Productization Direction

When asked how to make this a reusable platform product, favor these additions:

- `observability-platform/onboarding/`: app-team values examples for Go, Python, Java, Node.js, and .NET.
- `observability-platform/instrumentation-templates/`: language-specific `Instrumentation` CRs and deployment patch examples.
- `observability-platform/gitops/`: Argo CD or Flux examples showing how workload repos consume platform-owned charts.
- A clear service onboarding contract documenting required labels, resource attributes, supported languages, dashboard templates, alert defaults, and escalation routing.
- A values-driven replacement for hardcoded gateway endpoints in workload collector manifests.
- A validated gateway pipeline that includes tail sampling where intended.

The key platform story is:

```text
Developers declare observability intent in Git.
The platform renders standard instrumentation, dashboards, alerts, routing, and cost controls.
```
