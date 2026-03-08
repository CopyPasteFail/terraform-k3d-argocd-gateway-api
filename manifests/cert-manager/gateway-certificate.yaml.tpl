#
# Declares a cert-manager Certificate for the public hostname and stores
# the issued TLS certificate in a Secret.
# The Secret is the TLS identity the Gateway presents for HTTPS traffic.
#
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${certificate_name}
  namespace: gateway-system
spec:
  secretName: ${certificate_name}
  commonName: ${public_hostname}
  dnsNames:
  - ${public_hostname}
  issuerRef:
    kind: Issuer
    name: ${issuer_name}
