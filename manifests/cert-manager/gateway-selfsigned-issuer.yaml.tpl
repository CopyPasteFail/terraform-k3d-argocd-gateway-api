#
# Declares a cert-manager Issuer that can sign certificates inside the
# gateway namespace.
# This local certificate source is in turn used to issue the Gateway TLS certificate.
#
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ${issuer_name}
  namespace: gateway-system
spec:
  selfSigned: {}
