# Routing and Multitenancy

Demonstrates how to route telemetry streams from multiple tenants or teams using a single shared OpenTelemetry Collector gateway.

### Config
* **Collector Configuration**: [otel-gateway-multitenant.yaml](otel-gateway-multitenant.yaml)

### Implementation
1. **Routing Processor**: Uses the `routing` processor inside the OTel Gateway to inspect incoming attributes (e.g., headers or resource attributes).
2. **Dynamic Exporter Selection**: Dynamically routes traffic to tenant-specific backend endpoints (e.g., different Prometheus, Loki, or Tempo hosts) based on header/attribute values.
