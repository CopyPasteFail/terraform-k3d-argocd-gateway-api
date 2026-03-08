apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: gateway-system
spec:
  gatewayClassName: ${gateway_class_name}
  listeners:
  - name: https
    protocol: HTTPS
    port: 8443
    hostname: ${public_hostname}
    tls:
      mode: Terminate
      certificateRefs:
      - group: ""
        kind: Secret
        name: platform-gateway-tls
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-access: shared-gateway
