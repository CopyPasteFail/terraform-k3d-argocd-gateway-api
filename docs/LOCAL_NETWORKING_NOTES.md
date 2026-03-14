# LOCAL_NETWORKING_NOTES

These notes cover local networking behavior for this repository.
They include observations from the original WSL-based development environment, but the same k3d, Traefik, and ngrok topology should also work on Debian-family Linux hosts running directly on the machine.

## Local environment notes

- WSL was the original tested environment for this repository.
- On WSL, commands run inside the Linux environment and Docker Engine also runs inside WSL.
- On a Debian-family Linux host running directly on the machine, the same topology should work without the WSL boundary.

## Port exposure and localhost behavior

- k3d publishes host ports from Linux userspace.
- On WSL, localhost behavior can be affected by the Windows/Linux boundary.
- On Debian-family Linux hosts directly, the same host port mappings should be simpler, but this repository still treats direct `localhost:8080` or `localhost:8443` access as a debug-only path rather than as the supported verification contract.
- The supported local verification path is `make verify-local`, which uses `kubectl port-forward` directly to the Traefik Service listener.
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
