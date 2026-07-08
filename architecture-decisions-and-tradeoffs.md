# Global Scale OpenTelemetry Architecture Patterns

For a global enterprise platform, deploying across multiple regions requires an observability architecture that balances resource efficiency, latency, cross-AZ/Region network costs, and telemetry ingestion reliability.

**Important Note on Regions:** All architectural patterns below assume a **Per-Region Deployment**. Cross-region telemetry transfer (e.g., sending EU spans to a US Gateway) is generally avoided due to significant egress costs and high network latency. Each region should have its own isolated pipeline.

Below are four incremental architectural patterns, followed by an "Enterprise Scale" buffer pattern designed specifically to handle high burst traffic.

---

## Pattern 1: Sidecar Only -> Datadog

In this pattern, an OTel Collector runs as a sidecar container inside every single microservice pod. The sidecar collects telemetry and exports it directly to the Datadog backend over the internet.

```mermaid
graph TD
    subgraph Region["AWS Region (us-east-1)"]
        subgraph EKSCluster["EKS Cluster"]
            subgraph PodA["App Pod A"]
                AppA["Microservice A"] -->|Localhost / OTLP| SidecarA["OTel Sidecar"]
            end
            subgraph PodB["App Pod B"]
                AppB["Microservice B"] -->|Localhost / OTLP| SidecarB["OTel Sidecar"]
            end
        end
    end
    
    SidecarA -->|Export| Datadog["Datadog Cloud"]
    SidecarB -->|Export| Datadog
```

### 🟩 Pros
* Resource isolation; no intermediate network hops.

### 🟥 Cons
* High baseline cost (1 sidecar per pod); Tail-sampling impossible; Risk of API rate-limiting.

---

## Pattern 2: DaemonSet Only -> Datadog

Instead of a sidecar per pod, one OTel Collector runs on every EKS Worker Node as a DaemonSet. All pods on that node send their telemetry to the node's local agent.

```mermaid
graph TD
    subgraph Region["AWS Region"]
        subgraph EKSCluster["EKS Cluster"]
            subgraph Node1["EKS Worker Node 1"]
                AppA["App Pod A"] -->|Host IP / OTLP| DSAgent1["OTel DaemonSet"]
                AppB["App Pod B"] -->|Host IP / OTLP| DSAgent1
            end
            subgraph Node2["EKS Worker Node 2"]
                AppC["App Pod C"] -->|Host IP / OTLP| DSAgent2["OTel DaemonSet"]
            end
        end
    end
    
    DSAgent1 -->|Export| Datadog["Datadog Cloud"]
    DSAgent2 -->|Export| Datadog
```

### 🟩 Pros
* Lower overhead (1 agent per node); Enables host-level metrics.

### 🟥 Cons
* Tail-sampling impossible; Traffic spikes crash the node agent, dropping data.

---

## Pattern 3: DaemonSet -> Cluster Gateway -> Datadog

DaemonSets act only as lightweight forwarders, sending data to a centralized OTel Gateway (a Kubernetes Deployment) running within the *same* EKS cluster.

```mermaid
graph TD
    subgraph Region["AWS Region"]
        subgraph EKSCluster["EKS Cluster"]
            subgraph Nodes["Worker Nodes"]
                AppA["App Pod"] -->|OTLP| DSAgent["OTel DaemonSet"]
            end
            
            subgraph GatewayNodeGroup["Dedicated Node Group (Optional)"]
                DSAgent -->|Forward| Gateway["OTel Gateway<br/>(Deployment / HPA)"]
            end
        end
    end
    
    Gateway -->|Batch & Compress| Datadog["Datadog Cloud"]
```

### 🟩 Pros
* Enables cluster-wide tail-sampling; Centralizes API keys; Reduces egress via batching.

### 🟥 Cons
* High memory usage for tail-sampling can starve app pods if running on same nodes.

---

## Pattern 4: DaemonSet -> Dedicated Regional Gateway Cluster -> Datadog

Application clusters run lightweight DaemonSets, which forward data over AWS PrivateLink or VPC Peering to a **Dedicated Observability EKS Cluster** in the same region.

```mermaid
graph TD
    subgraph Region["AWS Region (us-east-1)"]
        
        subgraph AppCluster1["App EKS Cluster 1"]
            App1["Apps"] --> DS1["DaemonSet"]
        end
        
        subgraph AppCluster2["App EKS Cluster 2"]
            App2["Apps"] --> DS2["DaemonSet"]
        end
        
        subgraph ObsCluster["Dedicated Observability EKS Cluster"]
            NLB["Internal NLB"]
            Gateway["OTel Gateway Fleet<br/>(HPA, High Memory Nodes)"]
            NLB --> Gateway
        end
        
        DS1 -->|AWS PrivateLink / VPC Peering| NLB
        DS2 -->|AWS PrivateLink / VPC Peering| NLB
    end
    
    Gateway -->|Tail Sample & Export| Datadog["Datadog Cloud"]
```

### 🟩 Pros
* Perfect cross-cluster tail-sampling; Isolates heavy telemetry processing from apps.

### 🟥 Cons
* Cross-AZ data transfer costs; Higher operational complexity.

---

## 🌟 Pattern 5: The Enterprise Scale Buffer Architecture

At a global enterprise scale, high traffic events generate massive telemetry spikes. Standard gateways will begin dropping data if the backend experiences an outage or if Gateways hit their memory limits (e.g., a hard limit of processing 20,000 spans at a time to avoid OOM crashes).

To solve this, introduce **Apache Kafka (Amazon MSK)** as a persistent disk buffer between an Ingestion Gateway and a Processing Gateway.

```mermaid
graph TD
    subgraph Region["AWS Region (us-east-1)"]
        
        subgraph AppClusters["Application EKS Clusters"]
            App["Apps"] --> DS["OTel DaemonSet"]
        end
        
        subgraph ObsVPC["Observability VPC"]
            IngestGateway["Ingestion Gateway<br/>(Stateless, Lightweight)"]
            Kafka[("Amazon MSK<br/>(Kafka Buffer on Disk)")]
            ProcessGateway["Processing Gateway Fleet<br/>(HPA, Stateful, Tail Sampling)"]
            
            DS --> IngestGateway
            IngestGateway -->|Produce| Kafka
            Kafka -->|Consume / Consumer Group| ProcessGateway
        end
    end
    
    ProcessGateway --> Datadog["Datadog Cloud"]
```

### 🟩 Pros
* Zero data loss during backend outages or massive traffic spikes; Kafka disk acts as a massive buffer preventing Gateway OOM crashes.

### 🟥 Cons
* Highest operational complexity and infrastructure cost.
