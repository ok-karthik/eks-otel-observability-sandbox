# Observability Platform Templates

This folder is the "how this scales to 1000+ services" part of the demo. Treat it as the platform team's reusable template library, separate from the sample workload application.

## What Lives Here

- [k8s-manifests](./k8s-manifests): deployable observability-cluster manifests for LGTM, Pyroscope, Grafana ingress, and the OTel Gateway.
- [golden-signals](./golden-signals): reusable dashboards for latency, traffic, errors, and saturation.
- [telemetry-budgeting](./telemetry-budgeting): tail-sampling and filtering examples for cost and cardinality control.
- [routing-and-multitenancy](./routing-and-multitenancy): collector routing patterns for teams, tenants, environments, and backend separation.
- [dashboard-and-alert-generators](./dashboard-and-alert-generators): Helm-driven dashboard and alert generation patterns.

## Interview Talk Track

For a large company running services across US, EU, and Australia, I would not send all telemetry to one global collector. I would deploy this platform per region:

1. Workload clusters run lightweight OTel Collector DaemonSets.
2. DaemonSets enrich telemetry with Kubernetes metadata and forward to a private regional observability cluster.
3. Regional OTel Gateway fleets apply shared policy: memory limits, filtering, batching, tail sampling, routing, and backend export.
4. Teams onboard by adding standard labels/resource attributes and using dashboard/alert templates through GitOps.
5. Critical traces are preserved while healthy high-volume traffic is sampled down to manage cost.

## Scale Evolution

```text
Small demo:
apps cluster -> daemonset collector -> observability gateway -> LGTM

Enterprise regional platform:
many app clusters -> regional ingestion gateways -> processing gateways -> Datadog/Dynatrace/LGTM/AMP

High burst or backend outage protection:
many app clusters -> ingestion gateways -> Kafka/MSK buffer -> processing gateways -> backends
```

## Ownership Model

- App teams own instrumentation quality, service names, SLO intent, and dashboard values.
- Platform teams own collector baselines, routing policy, backend integrations, sampling defaults, and paved-road templates.
- Security/FinOps teams get centralized controls for secrets, retention, noisy telemetry, and tenant boundaries.

## Demo Positioning

In the live demo, `k8s-manifests/` is the deployable slice. The other folders are the production templates I would standardize before onboarding hundreds of teams.
