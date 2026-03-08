#
# Declares an HTTPRoute that attaches the /whoami path on the public hostname
# to the shared Gateway and routes matching requests to the whoami Service.
# When sending a request to https://${public_hostname}/whoami..., that request is forwarded to the whoami app.
#
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: whoami-route
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
        value: /whoami
    backendRefs:
    - name: whoami
      namespace: whoami
      port: 80
