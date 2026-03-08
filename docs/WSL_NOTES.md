# WSL_NOTES

## Environment assumptions

- Commands run inside WSL.
- Docker Engine runs inside WSL.
- VS Code is attached to WSL filesystem.
- No Docker Desktop on Windows is assumed.

## Port exposure and localhost behavior

- k3d publishes host ports from Linux userspace in WSL, but this repository does not treat direct `localhost:8080` or `localhost:8443` access as a supported verification contract.
- The supported local verification path is `./scripts/verify-local.sh`, which uses `kubectl port-forward` directly to the Traefik Service listener.
- The primary access path remains ngrok public HTTPS.

## Routing model

- Public requests hit ngrok domain first.
- Public exposure is implemented with ngrok operator ingress mode and a Kubernetes `Ingress` in `gateway-system` (default path).
- Earlier custom `AgentEndpoint` wiring was dropped from the default path because it did not reconcile reliably in the tested operator/runtime combination.
- The Ingress routes to Traefik service on cluster port 443.
- Traefik/Gateway handles TLS with cert-manager-issued self-signed cert.
- ngrok is exposure-only; Traefik remains the Gateway API controller and still performs Gateway listener + `HTTPRoute` path routing.
- Path routing is handled by Gateway API:
  - `/`
  - `/argocd`
  - `/whoami`
- `AgentEndpoint`, `BoundEndpoint`, and `CloudEndpoint` resources are not part of the default public path in this repository.

## Browser behavior with ngrok free tier

When using ngrok free tier in a browser for HTML pages:

- You may see an interstitial warning page once.
- After click-through, ngrok sets a cookie and suppresses the warning for 7 days for that domain.
- API/programmatic traffic is not affected.
