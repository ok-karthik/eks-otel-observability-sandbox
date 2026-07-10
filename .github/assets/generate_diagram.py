import os
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EKS
from diagrams.aws.network import ALB, VPCPeering, NLB
from diagrams.aws.general import Users
from diagrams.aws.storage import S3
from diagrams.aws.security import IAMRole
from diagrams.k8s.compute import Pod, DaemonSet, Deployment, StatefulSet
from diagrams.onprem.monitoring import Grafana
from diagrams.onprem.logging import Loki
from diagrams.custom import Custom

script_dir = os.path.dirname(os.path.abspath(__file__))
diagram_filename = os.path.join(script_dir, "aws_architecture")
tempo_icon_path = os.path.join(script_dir, "tempo.png")
mimir_icon_path = os.path.join(script_dir, "mimir.png")

# Use a standard diagram graph attribute for more spacing
graph_attr = {
    "pad": "1.0",
    "nodesep": "1.0",
    "ranksep": "2.0",
    "splines": "spline",
    "fontsize": "24",
    "dpi": "300"
}

node_attr = {
    "fontsize": "16"
}

cluster_attr = {
    "fontsize": "18",
    "margin": "25"
}

with Diagram("EKS OTel Observability Platform", show=False, filename=diagram_filename, outformat="png", graph_attr=graph_attr, node_attr=node_attr):
    users = Users("Users")

    with Cluster("VPC 1: Apps Workload", graph_attr=cluster_attr):
        alb = ALB("Ingress ALB")
        
        with Cluster("EKS Cluster: apps-workload-cluster-1", graph_attr=cluster_attr):
            go_app = Pod("Go Product Service")
            python_app = Pod("Python Payment Service")
            
            otel_agent = DaemonSet("OTel Agent\n(kubeletstats, filelog, otlp)")

            alb >> go_app >> python_app
            go_app >> Edge(color="darkorange", style="dashed", label="OTLP Traces/Metrics/Logs") >> otel_agent
            python_app >> Edge(color="darkorange", style="dashed") >> otel_agent

    vpc_peering = VPCPeering("VPC Peering")

    with Cluster("VPC 2: Observability", graph_attr=cluster_attr):
        nlb = NLB("OTel Ingress NLB")
        
        with Cluster("EKS Cluster: observability-cluster", graph_attr=cluster_attr):
            
            with Cluster("OTel Gateway (Scaled Deployment)", graph_attr=cluster_attr):
                otel_routing = Deployment("Pipeline 1:\nTrace Hashing\n(Port 4317)")
                otel_processing = Deployment("Pipeline 2:\nTail Sampling\n(Port 4319)")
                otel_routing >> Edge(label="TraceID Affinity") >> otel_processing
            
            with Cluster("Scalable Grafana Backend", graph_attr=cluster_attr):
                grafana = Grafana("Grafana")
                mimir = Custom("Mimir (Metrics)", mimir_icon_path)
                loki = Loki("Loki (Logs)")
                tempo = Custom("Tempo (Traces)", tempo_icon_path)
            
            pod_identity = IAMRole("EKS Pod Identity")
            
            otel_processing >> mimir
            otel_processing >> loki
            otel_processing >> tempo

        # AWS S3 Storage
        with Cluster("AWS S3 Storage (Long-term)", graph_attr=cluster_attr):
            s3_mimir = S3("Mimir Blocks")
            s3_loki = S3("Loki Data")
            s3_tempo = S3("Tempo Traces")
            
            mimir >> pod_identity >> s3_mimir
            loki >> pod_identity >> s3_loki
            tempo >> pod_identity >> s3_tempo

    otel_agent >> vpc_peering >> nlb >> otel_routing
    users >> alb
