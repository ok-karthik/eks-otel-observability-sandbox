# Golden Signals Templates

Contains standardized dashboard templates based on SRE's Four Golden Signals (Latency, Traffic, Errors, Saturation).

* **Go Service**: [go-service-dashboard.json](go-service-dashboard.json)
* **Python Service**: [python-service-dashboard.json](python-service-dashboard.json)

### Implementation
1. **Local Sandbox**: Automatically mounted via Grafana provisioning configurations (`local-env/grafana/provisioning/`).
2. **Production Kubernetes**: Injected into `GrafanaDashboard` Custom Resources (CRDs) via Helm charts.
