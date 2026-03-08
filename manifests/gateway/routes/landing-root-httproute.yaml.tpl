#
# Declares an HTTPRoute that attaches the / path on the public hostname
# to the shared Gateway and routes matching requests to the landing Service.
# When sending a request to https://${public_hostname}/..., that request is forwarded to the landing app.
#
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: landing-root-route
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
        value: /
    backendRefs:
    - name: landing
      namespace: landing
      port: 80
