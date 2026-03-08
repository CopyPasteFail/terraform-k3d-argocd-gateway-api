# KNOWN_LIMITATIONS_AND_NEXT_STEPS

## Current limitations

- TLS certificate for Traefik upstream is self-signed and intended for local/testing only.
- ngrok forwards HTTPS upstream to Traefik over that self-signed TLS connection (via ngrok-managed Ingress to Traefik `Service:443`). This is intentional for local development but not a public-production trust model.
- No sealed-secrets or external-secrets integration; credentials are provided at apply time.
- No production HA tuning; local footprint is prioritized.
- No controller-specific BackendPolicy resources in the base stack by design.
- The default public path is ngrok operator ingress mode with a Kubernetes `Ingress`; it does not assume custom `AgentEndpoint` reconciliation or require `BoundEndpoint`/`CloudEndpoint` resources.
- The earlier custom `AgentEndpoint` default path was removed because it did not reconcile reliably in the tested operator/runtime combination, while ingress mode is already supported by the enabled operator feature set.
- `terraform/cluster` uses `local-exec` with `k3d` CLI rather than a dedicated provider.
- The official Traefik upstream does not publish a `whoami` Helm chart. As of 2026-03-08, `https://traefik.github.io/charts/index.yaml` still has no `whoami` chart entry.
- The active `whoami` deployment path uses the third-party `cowboysysop/whoami` Helm chart rendered by ArgoCD, with values pinned in `manifests/apps/whoami/values.yaml`.
- That choice satisfies the Helm-via-ArgoCD requirement, but it adds a third-party chart dependency instead of using an official upstream chart.
- `landing` remains repository-managed: ArgoCD syncs `manifests/apps/landing` directly from this repository via `manifests/argocd/landing-application.yaml.tpl`.
- Automatic `origin` detection in `scripts/up.sh` does not solve private repository authentication for ArgoCD.
- If the repository is private and ArgoCD repository credentials are not configured, Application sync will fail.
- Repo-root `.env` input handling in bootstrap is intended for local convenience and is not a hardened long-term credential-management pattern.

## Why these limitations exist

- The stack is optimized for reproducible local platform setup in WSL.
- The default architecture prioritizes portability in Gateway API resources.
- Traefik is the Gateway API controller, while ngrok is intentionally limited to hostname exposure.
- Advanced controller-specific features are intentionally deferred.

## Next steps

- Add a second Gateway API controller option and validate controller swap flow.
- Add smoke tests for `/` landing content, `/argocd` asset loading, and `/whoami` response checks.
- Add CI checks for Terraform formatting, validation, and manifest linting.
- Add observability as an optional later stage.
- Re-evaluate the third-party chart dependency if an official upstream whoami chart source is published and maintained.
- Add policy checks around pinned chart version drift.
- Add optional private-repo bootstrap path by creating ArgoCD repository credentials (or repo secret) during provisioning.
