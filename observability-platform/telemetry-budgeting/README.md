# Telemetry Budgeting

Demonstrates cost control and data volume optimization techniques (telemetry budgeting) at the OTel Collector layer.

### Config
* **Collector Configuration**: [otel-gateway-tail-sampling.yaml](otel-gateway-tail-sampling.yaml)

### Implementation
1. **Tail-based Sampling**: Evaluates full trace flows at the Gateway before exporting. Retains 100% of errors or long-latency traces while sampling down high-volume successful transactions (e.g. keeping only 10% of HTTP 200s).
2. **Filter Processor**: Drops high-cardinality or noisy health check logs and metrics before storage ingestion.
