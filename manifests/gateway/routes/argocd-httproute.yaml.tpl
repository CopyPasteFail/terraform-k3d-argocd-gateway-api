#
# Declares an HTTPRoute that attaches the /argocd path on the public hostname
# to the shared Gateway and routes matching requests to the argocd-server Service.
# When sending a request to https://${public_hostname}/argocd..., that request is forwarded to the argocd app.
#
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-route
  namespace: routes-system
spec:
  hostnames:
  - ${public_hostname}
  parentRefs:
  - name: shared-gateway
    namespace: gateway-system
    sectionName: https
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /argocd
    backendRefs:
    - name: argocd-server
      namespace: argocd
      port: 80
