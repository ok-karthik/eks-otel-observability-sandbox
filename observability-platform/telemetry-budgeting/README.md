# Telemetry Budgeting

Demonstrates cost control and data volume optimization techniques (telemetry budgeting) at the OTel Collector layer.

## Config

* **Collector Configuration**: [otel-gateway-tail-sampling.yaml](otel-gateway-tail-sampling.yaml)

## Platform Policy

Telemetry budgeting is how the platform keeps observability useful without letting cost grow linearly with traffic.

- Keep 100% of failed traces.
- Keep 100% of latency outliers.
- Sample healthy high-volume traffic.
- Drop health checks and other noisy low-value spans.
- Normalize or reject high-cardinality attributes before storage.

## Interview Talking Point

At 1000+ services, sampling should be a platform default, not an app-by-app decision. Teams can request exceptions for critical flows, but the gateway enforces shared cost and reliability policy.
