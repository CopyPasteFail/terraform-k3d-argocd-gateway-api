apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: platform-public-ingress
  namespace: gateway-system
spec:
  ingressClassName: ngrok
  rules:
    - host: ${public_hostname}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: traefik
                port:
                  number: 443
