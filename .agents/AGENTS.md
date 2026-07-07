# Agent Instructions & Project Rules

This document outlines the design principles, guidelines, and constraints for AI agents interacting with this repository.

---

## 🏗️ Repository Architecture & Overview

This repository is an observability sandbox demonstrating **OpenTelemetry (OTel)** integration for distributed transactions running both **locally** (Docker Compose + Grafana LGTM stack) and in **production** (Amazon EKS).

### Key Components:
- **`apps/golang-app`**: A Go-based checkout service that initiates distributed trace waterfalls.
- **`apps/python-app`**: A Python-based payment service that processes charges requested by the checkout service.
- **`local-env/`**: Docker Compose local development sandbox using `grafana/otel-lgtm`.
- **`k8s/`**: Kubernetes configuration files.
  - `k8s/apps/`: Resource definitions for the Go and Python microservices and the Redis cache simulation.
  - `k8s/otel/`: OpenTelemetry Operator resources (Recommended topology).
- **`terraform/`**: Infrastructure as Code (IaC) for EKS and ECR resources.
- **`scripts/`**: Bootstrapping/installation scripts.

---

## 🛠️ Guidelines & Constraints

When modifying code or configurations, ensure you strictly adhere to the following rules:

### 1. Service Instrumentation & W3C Propagation
- Both `apps/golang-app` and `apps/python-app` propagate trace contexts using the **W3C Trace Context specification**.
- If adding new endpoints, ensure that headers are properly extracted and injected (`traceparent` header).
- Ensure dependency libraries (like Redis or HTTP clients) are auto-instrumented or manually instrumented so traces do not break.

### 2. Dockerfiles and Build Steps
- Keep Dockerfiles optimized. Ensure dependencies are cached appropriately (e.g. using multi-stage builds).
- Both apps compile cleanly in the GitHub Actions CI pipeline configured in `.github/workflows/ci.yaml`. Do not introduce OS-specific dependencies that break building on standard runner environments.

### 3. Terraform Guidelines
- Run `terraform fmt` on any modified `.tf` files.
- Ensure that IAM policies follow the **principle of least privilege**.

### 4. Makefile as the Interface
- All core tasks (local sandbox setup, EKS context switching, Helm installations, deployments) are exposed via the `Makefile`.
- If you add utility scripts or execution sequences, document them as targets in the `Makefile`.

---

## 📝 Documenting Changes
- When modifying OpenTelemetry collector configurations, verify that the telemetry pipelines (receivers -> processors -> exporters) are syntactically valid.
- Keep the `README.md` file up to date with any newly exposed ports, CLI variables, or architecture layout changes.
