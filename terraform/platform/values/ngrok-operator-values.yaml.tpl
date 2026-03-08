credentials:
  apiKey: "${ngrok_api_key}"
  authtoken: "${ngrok_authtoken}"

# Keep the default platform model narrow:
# - ngrok exposes public traffic through Kubernetes Ingress
# - Traefik remains the Gateway API controller
ingress:
  enabled: true

gateway:
  enabled: false

installCRDs: true
