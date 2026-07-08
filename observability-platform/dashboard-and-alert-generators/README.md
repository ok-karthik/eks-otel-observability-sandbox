# Dashboard & Alert Generators

In a large-scale engineering organization with hundreds or thousands of microservices, managing dashboards and alerts efficiently is critical. Treating **Observability as a Product (OaaP)** means empowering developers to own their telemetry through self-service tools, rather than relying on a centralized platform team to manually provision dashboards for them.

This directory explores two architectural patterns for managing dashboards and alerts:

1. **Decentralized GitOps (Kubernetes-Native CRDs)** - *Recommended for scale*
2. **Centralized Unified Terraform** - *Common for legacy setups or SaaS migrations*

---

## Pattern 1: Decentralized GitOps (Kubernetes-Native CRDs)

In a Cloud-Native environment (e.g., using Grafana LGTM), the best practice is to leverage Kubernetes Custom Resource Definitions (CRDs) like `PrometheusRule` (from prometheus-operator) and `GrafanaDashboard` (from grafana-operator).

### How it works
1. **The Platform Team** creates a generic, reusable Helm chart (e.g., `observability-base-chart` provided in this directory).
2. **The App Developers** add this Helm chart as a dependency in their microservice's repository.
3. The developers define their Service Level Objectives (SLOs) and alert thresholds in a simple `values.yaml` file right next to their application code.
4. ArgoCD or Flux automatically applies these CRDs to the cluster when the app is deployed.

### Why this scales to 1,000+ microservices
* **Zero friction:** Developers don't need to learn PromQL, JSONNET, or Terraform. They just fill out a simple YAML file.
* **Co-location:** Alerts and dashboards live in the same repository as the application code. A PR that changes application logic can simultaneously update the relevant alerts.
* **No bottlenecks:** There is no single centralized repository that all 1,000 teams must contribute to, avoiding merge conflicts and CI/CD pipeline congestion.

*(See the `helm-chart/` directory for a functional example of this pattern).*

---

## Pattern 2: Centralized Unified Terraform 

When migrating to or using SaaS observability vendors like Datadog or other, organizations often start by creating a **Unified Terraform Repository** to manage all monitors and dashboards via Infrastructure as Code (IaC) (e.g., using the Datadog Terraform Provider).

### How it works
1. **The Platform Team** maintains a single massive Terraform repository.
2. The repository is organized by department or team (e.g., `/dashboards/checkout-team/`, `/alerts/payment-team/`).
3. **App Developers** clone this repository, write Terraform modules for their dashboards, and submit a Pull Request.

### The challenges at scale
* **The Monorepo Bottleneck:** With hundreds of teams submitting PRs to a single repo, CI/CD pipelines slow down, and Terraform state locking becomes a major friction point.
* **Context Switching:** Developers have to switch from their application code repo to the infra repo just to tweak an alert threshold.

## Pattern 3: Datadog Operator
If you are locked into a SaaS tool like Datadog but want the benefits of **Pattern 1**, you can use Kubernetes Operators designed for SaaS tools. For example, the **Datadog Operator** allows developers to define a `DatadogMonitor` CRD inside their application repository. The Operator then seamlessly syncs this CRD to the Datadog API, providing the scalability of Decentralized GitOps while using a SaaS backend.
