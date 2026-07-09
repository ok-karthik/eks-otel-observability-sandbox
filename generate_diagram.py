from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EKS
from diagrams.aws.network import ALB, VPCPeering, NLB
from diagrams.aws.general import Users
from diagrams.k8s.compute import Pod, DaemonSet, Deployment
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.logging import Loki
from diagrams.custom import Custom

with Diagram("EKS OTel Observability Platform", show=False, filename=".github/assets/aws_architecture", outformat="png"):
    users = Users("Users")

    with Cluster("VPC 1: Apps Workload"):
        alb = ALB("Ingress ALB")
        
        with Cluster("EKS Cluster: apps-workload-cluster-1"):
            go_app = Pod("Go Product Service")
            python_app = Pod("Python Payment Service")
            
            otel_agent = DaemonSet("OTel Agent\n(kubeletstats, filelog, otlp)")

            alb >> go_app >> python_app
            go_app >> Edge(color="darkorange", style="dashed", label="OTLP Traces/Metrics/Logs") >> otel_agent
            python_app >> Edge(color="darkorange", style="dashed") >> otel_agent

    vpc_peering = VPCPeering("VPC Peering")

    with Cluster("VPC 2: Observability"):
        nlb = NLB("OTel Ingress NLB")
        with Cluster("EKS Cluster: observability-cluster"):
            otel_gateway = Deployment("OTel Gateway\n(Deployment)")
            
            with Cluster("LGTM Stack"):
                grafana = Grafana("Grafana")
                prometheus = Prometheus("Prometheus")
                loki = Loki("Loki")
                tempo = Custom("Tempo", ".github/assets/tempo.png")
                
                grafana >> prometheus
                grafana >> loki
                grafana >> tempo
            
            otel_gateway >> prometheus
            otel_gateway >> loki
            otel_gateway >> tempo

    otel_agent >> vpc_peering >> nlb >> otel_gateway
    users >> alb
