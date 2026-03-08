# Argo CD configmap values passed to the server component.
configs:
  params:
    # Serve HTTP without Argo CD's internal TLS because ingress handles exposure.
    server.insecure: "true"
    # Mount the UI under the /argocd subpath.
    server.basehref: "/argocd"
    # Make Argo CD route API and UI links from the /argocd subpath.
    server.rootpath: "/argocd"

server:
  ingress:
    # Keep the chart's built-in ingress off; Traefik manages external routing.
    enabled: false
  service:
    # Expose the server only inside the cluster.
    type: ClusterIP
