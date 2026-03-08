# GATEWAY_API_VS_INGRESS

## Why Gateway API here

- Role separation: infrastructure owners manage `Gateway`; app teams manage `HTTPRoute`.
- Cross-namespace references are explicit through `ReferenceGrant`.
- Controller swap is cleaner via `GatewayClass` and controller wiring.

## Why not rely on Ingress for this stack

- Ingress is less expressive for shared, multi-namespace delegation patterns.
- Backend trust boundaries are less explicit than Gateway API + `ReferenceGrant`.
- Controller portability is weaker when behavior depends on ingress-class annotations.

## Backend health policy note

This default implementation intentionally does not use `BackendPolicy`.

- `BackendPolicy` is controller-specific and not part of portable Gateway API core behavior.
- In this Traefik-first implementation, backend health is handled by Kubernetes readiness/liveness probes on workloads (whoami).
- Controller-specific backend policy can be added later for controllers that support it cleanly.
