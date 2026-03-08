# Run a single Traefik pod for this local platform setup.
deployment:
  replicas: 1

providers:
  kubernetesIngress:
    # Ignore classic Ingress resources; ngrok handles those.
    enabled: false
  kubernetesGateway:
    # Watch Gateway API resources managed by Traefik.
    enabled: true

ingressClass:
  # Do not create an IngressClass because Ingress is disabled here.
  enabled: false

gatewayClass:
  # Do not let the chart create the GatewayClass; Terraform manages it separately.
  enabled: false

gateway:
  # Do not let the chart create a Gateway resource; Terraform manages it separately.
  enabled: false

service:
  # Expose Traefik only inside the cluster.
  type: ClusterIP
  annotations:
    # Tell ngrok to speak HTTPS to Traefik's secure entrypoint.
    k8s.ngrok.com/app-protocols: '{"websecure":"HTTPS"}'

logs:
  general:
    # Keep general logs at a normal operational level.
    level: INFO
