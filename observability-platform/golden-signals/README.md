# Golden Signals Templates

A core philosophy of **Observability as a Product** is providing developers with out-of-the-box visibility into their applications. Instead of every team building their own dashboards from scratch, the Platform team provides standard "Golden Signal" templates.

These templates are based on the [Four Golden Signals](https://sre.google/sre-book/monitoring-distributed-systems/):
1. **Latency:** The time it takes to service a request (e.g., P99 response time).
2. **Traffic:** A measure of how much demand is being placed on the system (e.g., requests per second).
3. **Errors:** The rate of requests that fail (e.g., HTTP 5xx errors).
4. **Saturation:** How "full" the service is (e.g., CPU, Memory, or Active Connections).

## Available Templates

* **Go Service Unified Dashboard:** [`go-service-dashboard.json`](go-service-dashboard.json)
* **Python Service Unified Dashboard:** [`python-service-dashboard.json`](python-service-dashboard.json)

These templates have been designed as **Unified Panes of Glass**. They do not just show metrics; they also include an embedded Loki logs panel filtered to the specific application, making correlation seamless.

## How it works (Local LGTM vs Kubernetes)

**1. Local LGTM Environment:**
In this sandbox repository, these JSON files are automatically mounted into the local Grafana instance via the Grafana Provisioning config (`local-env/grafana/provisioning/dashboards/dashboards.yaml`).

**2. Production Kubernetes (Grafana Operator):**
In a production environment, you would not mount JSON files manually. Instead, you would use the `GrafanaDashboard` Custom Resource Definition (CRD), as demonstrated in the `dashboard-and-alert-generators/` directory. The JSON payload of these templates is embedded directly into the CRD by the Helm chart.
