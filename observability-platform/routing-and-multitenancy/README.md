# Routing and Multitenancy

Demonstrates how to route telemetry streams from multiple tenants or teams using a single shared OpenTelemetry Collector gateway.

## Config

* **Collector Configuration**: [otel-gateway-multitenant.yaml](otel-gateway-multitenant.yaml)

## Routing Inputs

The gateway can route by attributes that app teams already provide:

- `service.namespace`
- `deployment.environment`
- `cloud.region`
- `k8s.namespace.name`
- `team` or `tenant`

## Use Cases

- Send production and non-production telemetry to different backends or retention tiers.
- Route regulated workloads to region-local storage.
- Give high-criticality services stricter sampling and retention.
- Keep platform-owned collector config centralized while app teams only manage labels.
