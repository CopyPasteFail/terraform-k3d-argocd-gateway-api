# AI Usage

This repository includes AI-assisted work.

## AI Model Used

- OpenAI Codex 5.3
- GPT 5.4

## Prompts Used

Initial prompt:

```text
You are working in a fresh infrastructure repository named `terraform-k3d-argocd-gateway-api`.

Build a production-style local platform stack that satisfies the requirements below..

Environment assumptions:
- Development environment is WSL on Windows 11
- Docker is installed inside WSL, not on Windows
- Commands are run from WSL
- VS Code is used from WSL
- Do not assume Docker Desktop on Windows
- Document any networking, port exposure, localhost, or routing considerations accordingly

Primary goals:
1. Provision a local k3d Kubernetes cluster using Terraform
2. Deploy ArgoCD using the Terraform Helm provider
3. Deploy whoami through ArgoCD as an Application resource stored in Git
4. Deploy a Gateway API controller with Terraform Helm provider, defaulting to Traefik
5. Install and configure Gateway API resources: GatewayClass, Gateway, HTTPRoute, and ReferenceGrant
6. Expose the stack publicly over HTTPS using the ngrok Kubernetes Operator
7. Serve ArgoCD UI through the Gateway on `/argocd`
8. Serve whoami through the Gateway on `/whoami`
9. Configure TLS using cert-manager with self-signed certificates
10. Keep the Gateway API architecture controller-swappable
11. Include clear repo documentation and AI usage disclosure

Key implementation requirements:
- Use a deliberate two-stage Terraform layout:
  - `terraform/cluster`
  - `terraform/platform`
- This is the intended design, not a fallback
- Keep Terraform code clean and reproducible
- Use latest stable versions where reasonable, then pin them
- Do not include GitHub repository creation steps anywhere
- Do not use manual `helm install` or ad hoc `kubectl apply` as the primary setup path

Default controller and exposure model:
- Default Gateway API controller: Traefik
- ngrok must NOT be the Gateway API controller
- ngrok is only the public exposure layer
- Deploy ngrok Kubernetes Operator in namespace `ngrok-system`
- Expose one public HTTPS endpoint through ngrok on a single domain
- Assume free-tier ngrok constraints: use one static domain and path-based routing
- ngrok should forward HTTPS upstream to the Traefik service on port 443
- Traefik and the Gateway terminate the upstream TLS connection using a self-signed certificate issued by cert-manager

Routing and namespace model:
- Use these namespaces from day one:
  - `argocd`
  - `cert-manager`
  - `gateway-system`
  - `routes-system`
  - `whoami`
  - `ngrok-system`
- Place the shared `Gateway` in `gateway-system`
- Place `HTTPRoute` resources in `routes-system`
- Keep backend services in their own namespaces
- Use `ReferenceGrant` from day one to allow cross-namespace backend references
- Use path-based routing on one hostname:
  - `/argocd`
  - `/whoami`

ArgoCD requirements:
- Install ArgoCD using Terraform Helm provider
- Configure ArgoCD to work behind `/argocd`
- Prefer internal HTTP for ArgoCD behind Traefik if that is the cleanest working option
- The ArgoCD UI must be reachable through the Gateway path `/argocd`
- whoami must be deployed as an ArgoCD Application manifest stored in Git
- The whoami Application should use automated sync, prune, selfHeal, and CreateNamespace=true

Health handling requirements:
- Do NOT implement BackendPolicy in the default setup
- Implement readiness and liveness probes on whoami
- Document that backend health policy is controller-specific and not part of portable Gateway API core behavior
- Explain that in the default Traefik implementation, backend health is handled through Kubernetes readiness/liveness rather than a controller-specific BackendPolicy resource
- Note that controller-specific backend policy can be added later for controllers that support it cleanly

Controller portability requirements:
- Keep the base Gateway API architecture controller-swappable
- Minimal change target: controller-specific Helm values and GatewayClass/controller wiring
- Implement the repository structure so a second controller can be introduced cleanly later
- Add a document explaining what changes and what stays the same when swapping controllers

ngrok documentation requirement:
- Document that on ngrok free tier, browser access to HTML pages shows an interstitial warning page once
- After the visitor clicks through, ngrok sets a cookie so the warning does not appear again for that domain for 7 days
- Document that this does not affect API or programmatic access

Documentation requirements:
- Use uppercase filenames for non-code docs
- Include at minimum:
  - `README.md`
  - `AI_USAGE.md`
  - `DESIGN_DECISIONS.md`
  - `CONTROLLER_SWAP.md`
  - `GATEWAY_API_VS_INGRESS.md`
  - `WSL_NOTES.md`
  - `KNOWN_GAPS.md`
  - `FUTURE_ENHANCEMENTS.md`
- In `DESIGN_DECISIONS.md`, for every meaningful implementation choice not explicitly dictated by the requirements, document:
  - selected option
  - alternatives considered
  - rationale
  - tradeoffs
  - implications

Working deliverable expectations:
- Public HTTPS ngrok URL
- ArgoCD UI accessible via the Gateway
- whoami responding through HTTPRoute
- TLS termination configured, with self-signed certs acceptable for local use

Suggested repo structure:
- `terraform/cluster`
- `terraform/platform`
- `manifests`
- `scripts`
- `docs` only if you truly need sub-organization, but prefer root-level uppercase docs for the required design documents
- root files for primary documentation

Expected Terraform/platform contents:
- k3d cluster provisioning
- namespaces
- Gateway API CRDs
- Traefik Helm release
- cert-manager Helm release
- ArgoCD Helm release
- ngrok operator Helm release
- Gateway, HTTPRoute, ReferenceGrant, Certificate, and Issuer resources
- outputs for useful endpoints, hostnames, and kube context

Expected manifests:
- GatewayClass
- Gateway
- HTTPRoute for ArgoCD
- HTTPRoute for whoami
- ReferenceGrant resources for cross-namespace routing
- cert-manager issuer/certificate
- ArgoCD Application for whoami
- ngrok-related manifests or annotations needed for operator-managed exposure to Traefik over HTTPS

Scripts to include:
- `scripts/up.sh`
- `scripts/destroy.sh`
- `scripts/verify.sh`
- `scripts/get-argocd-password.sh`

Behavior expectations:
- Do not ask broad planning questions
- Make reasonable choices and move forward
- Prefer reliability and clarity over cleverness
- If some ngrok operator detail needs a controller-specific or CRD-specific choice, choose the cleanest supported default and document it honestly
- Be explicit about known gaps instead of hand-waving

Execution order:
1. Inspect repo state
2. Create full scaffold
3. Implement first-pass working contents
4. Summarize what was created
5. List exact WSL commands to run for validation
6. Clearly mark any TODOs that require external credentials or environment-specific values
```

## What the AI Helped With

- Terraform scaffolding for the `cluster` and `platform` stages
- Kubernetes manifest generation
- Bash operational scripts
- Architecture and tradeoff documentation
- Repository documentation updates
