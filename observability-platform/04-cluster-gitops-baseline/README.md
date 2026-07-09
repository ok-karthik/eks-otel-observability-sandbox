# Cluster GitOps & Baseline

This directory demonstrates how a platform team exposes observability as a reusable GitOps product and how workload clusters consume it securely.

## Contents

- **`gitops-app-of-apps/`**: Argo CD examples showing how application repositories consume platform-owned observability charts.
- **`workload-cluster-baseline/`**: Templates that provide baseline connectivity and aliases for workload clusters.

## GitOps App Of Apps Flow

The platform repository owns the OTel collector baselines, gateway policies, instrumentation templates, and dashboard/alert Helm charts. Application repositories only own small values files containing service metadata, SLO thresholds, and alert routing intent.

```text
app repo values
  -> Argo CD Application
  -> platform-owned observability chart
  -> Instrumentation, dashboards, alerts, and workload patches
```

Use `root-application.yaml` as the parent app and `apps/*.yaml` as examples of child apps.

## Workload Cluster Baseline

The workload cluster should not hardcode vendor backends or central gateway DNS names in every collector manifest. Instead, expose one stable in-cluster name and point the node collector to that name.

Recommended pattern:
```text
workload collector -> otel-gateway-regional.monitoring.svc.cluster.local -> regional gateway NLB
```

In a real platform, the `ExternalName` target is rendered from Helm values, ExternalDNS, or a cluster bootstrap ConfigMap.
