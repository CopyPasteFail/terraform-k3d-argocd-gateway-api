# CONTROLLER_SWAP

This repository is structured so Gateway API controller changes are narrow and explicit.

## What stays the same

- Namespace model (`gateway-system`, `routes-system`, workload namespaces).
- Core Gateway API resources (`Gateway`, `HTTPRoute`, `ReferenceGrant`) and path strategy.
- cert-manager self-signed issuer/certificate flow.
- ngrok operator as public exposure layer.
- ArgoCD GitOps model for whoami.

## What changes when swapping controller

- Controller Helm release settings and chart source.
- Controller-specific values file under `terraform/platform/values`.
- Controller-specific GatewayClass manifest under `manifests/gateway/controllers/<controller>/`.
- `gateway_api_controller` mapping in `terraform/platform/main.tf`.

## Minimal change sequence

1. Add new controller values template in `terraform/platform/values`.
2. Add new `GatewayClass` template in `manifests/gateway/controllers/<controller>/`.
3. Extend `gateway_controller_catalog` in `terraform/platform/main.tf`.
4. Keep `Gateway` and `HTTPRoute` manifests unchanged unless controller-specific feature differences require optional tuning.

## Notes

- Keep portable resources in `manifests/gateway/core` and `manifests/gateway/routes`.
- Avoid embedding controller-specific extensions in core manifests.
