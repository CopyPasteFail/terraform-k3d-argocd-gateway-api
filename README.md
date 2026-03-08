# terraform-k3d-argocd-gateway-api

Production-style local platform stack for WSL using Terraform, k3d, Gateway API, ArgoCD, cert-manager, and ngrok.

## Project Overview

This repository builds a local Kubernetes platform in two Terraform stages:

- `terraform/cluster` creates a k3d cluster.
- `terraform/platform` installs Traefik, cert-manager, ArgoCD, ngrok operator, Gateway API resources, and demo app workloads.

The default result is a single public hostname with path-based routing:

- `https://<your-static-domain>/`
- `https://<your-static-domain>/argocd`
- `https://<your-static-domain>/whoami`

Public exposure uses an ngrok-managed Kubernetes `Ingress` targeting Traefik on cluster port `443`.
The default path does not depend on ngrok Kubernetes bindings resources.

For most users, the intended path is:

1. Configure ngrok and Git inputs once.
2. Run `./scripts/up.sh`.
3. Run `./scripts/verify.sh`.
4. Use the generated public URLs.

If you want the design rationale behind this stack, start with [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md). If you want the Gateway API motivation specifically, see [docs/GATEWAY_API_VS_INGRESS.md](docs/GATEWAY_API_VS_INGRESS.md).
For a consolidated explanation of how `terraform/` and `manifests/` fit together, see [docs/ARCHITECTURE_OVERVIEW.md](docs/ARCHITECTURE_OVERVIEW.md).

## Important Defaults and Caveats

Read this section before setup. These are the defaults most likely to affect whether bootstrap succeeds.

- This repository is optimized for WSL. Commands are expected to run inside WSL, with Docker Engine also running inside WSL.
- A reserved ngrok static domain is required for the default public access path.
- `./scripts/up.sh` can derive `GIT_REPOSITORY_URL` from the local Git `origin` if that origin is a supported GitHub URL. Manual configuration is still available when needed.
- ArgoCD must be able to reach the repository URL you provide anonymously over HTTPS. If the repository is private, app `Application` syncs will fail unless credentials are configured.
- The `whoami` ArgoCD `Application` also depends on the external Helm repository `https://cowboysysop.github.io/charts/` being reachable from the cluster.
- Gateway TLS is self-signed inside the cluster. This stack is intended for local/testing use, not a public production trust chain.
- ngrok is only the public exposure layer. Traefik remains the Gateway API controller for route attachment and path routing.
- The default implementation uses ngrok Ingress exposure; `AgentEndpoint`, `BoundEndpoint`, and `CloudEndpoint` are not part of the expected happy path.
- This default was selected because the previously tested custom `AgentEndpoint` path did not reconcile reliably in the tested operator/runtime combination, while the operator already supports an ingress-based path.
- ngrok ingress forwards upstream to the Traefik `websecure` listener (`Service:443`) with `k8s.ngrok.com/app-protocols` set so upstream protocol remains HTTPS.
- Earlier revisions coupled verification to bindings-oriented expectations; that coupling has been removed from the default public model.
- Public browser access goes through ngrok. On the ngrok free tier, browser visits to HTML endpoints can show an interstitial warning once. Localhost ports are for debugging only.
- The bootstrap flow writes a dedicated kubeconfig under repo-local `.kube/` instead of modifying `~/.kube/config`, so the cluster and platform stages share a deterministic handoff artifact without mutating the user's global kubeconfig.
- The platform stage uses a two-phase Terraform apply on fresh clusters: first it installs Helm releases and waits for CRDs, then it runs a full apply for CRD-backed `kubernetes_manifest` resources.

For WSL networking behavior, localhost mapping, and ngrok browser behavior, see [docs/WSL_NOTES.md](docs/WSL_NOTES.md).
For current non-goals and limitations, see [docs/KNOWN_LIMITATIONS_AND_NEXT_STEPS.md](docs/KNOWN_LIMITATIONS_AND_NEXT_STEPS.md).

## Prerequisites

Complete these shared prerequisites before running any bootstrap commands.

- WSL2
- Docker Engine installed and running inside WSL
- `terraform`
- `bash`
- `k3d`
- `kubectl`
- `curl`
- `base64`
- `ripgrep` (`rg`)
- A reserved [ngrok](https://dashboard.ngrok.com/signup) static domain

If you do not already have your ngrok credentials and reserved domain, see [Appendix: Register for ngrok and obtain required values](#appendix-register-for-ngrok-and-obtain-required-values).

## Configuration

Configure these inputs once before provisioning. This is the canonical place for environment variables and `.env` usage.

Required inputs:

- `NGROK_API_KEY`
- `NGROK_AUTHTOKEN`
- `NGROK_STATIC_DOMAIN`

If you need to create or retrieve those values first, see [Appendix: Register for ngrok and obtain required values](#appendix-register-for-ngrok-and-obtain-required-values).

Optional inputs:

- `GIT_REPOSITORY_URL`
- `GIT_TARGET_REVISION` (defaults to `main`)

The recommended local workflow is to create a repo-root `.env` file. Exported environment variables still take precedence over values loaded from `.env`.

```bash
cp .env.example .env
```

Then edit `.env` and set the required ngrok values. `GIT_TARGET_REVISION` is already included in the example file. Leave `GIT_REPOSITORY_URL` unset if you want `./scripts/up.sh` to derive it from the current Git `origin`.

If you want to validate only the derived ArgoCD Git source before any Terraform work starts, run:

```bash
./scripts/up.sh --print-derived-git-source
```

That validation is useful when:

- you want to confirm Git origin auto-detection
- you want to check the normalized GitHub HTTPS clone URL
- you want to fail early before cluster or platform provisioning begins

For the rationale behind `.env` loading, Git origin derivation, and the repo-local kubeconfig path, see [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md).

## Quick Start

### Provision

This step applies both Terraform stages in the correct order. It creates the k3d cluster first, then installs the platform components and manifests.

On a fresh cluster, the platform stage intentionally runs in two passes inside `./scripts/up.sh`. The first pass targets the Helm-backed CRD bootstrap path, and the second pass applies the full platform state after those CRDs are discoverable.

```bash
./scripts/up.sh
```

To run stages separately instead of both:

```bash
# Stage 1 only
./scripts/up.sh --stage cluster

# Confirm Stage 1 completed successfully
kubectl --kubeconfig .kube/k3d-platform-local.yaml --context k3d-platform-local cluster-info
kubectl --kubeconfig .kube/k3d-platform-local.yaml --context k3d-platform-local get nodes

# Stage 2 only
./scripts/up.sh --stage platform
```

### Verify

This step checks the main platform components, validates ngrok ingress-based public exposure, and verifies that `/`, `/argocd`, and `/whoami` respond as expected.

```bash
./scripts/verify.sh
```

If you want to verify routing from inside WSL without depending on ngrok readiness, use the local Traefik port-forward verifier:

```bash
./scripts/verify-local.sh
```

That verifier reads `gateway_namespace`, `gateway_name`, `gateway_service_name`, and `gateway_service_port` from the `terraform/platform` outputs instead of hardcoding those values in the script. Those outputs were added to keep the shared Gateway identity and Traefik listener details in one Terraform-managed source of truth, so local verification stays aligned with the deployed platform.

ArgoCD generates an initial random admin password when it starts for the first time. If you want to retrieve that generated password after verification succeeds, run:

```bash
./scripts/get-argocd-password.sh
```

### Expected Endpoints

After provisioning succeeds, the public base URL is:

- `https://<your-static-domain>`

The expected application paths are:

- Landing page: `https://<your-static-domain>/`
- ArgoCD: `https://<your-static-domain>/argocd`
- whoami: `https://<your-static-domain>/whoami`

## Day-2 Operations

### Re-run and Teardown

Use this when you want to remove the platform and the cluster from the current machine.

```bash
./scripts/destroy.sh
```

### Local Debugging

Direct `localhost:8080` and `localhost:8443` access is not a supported verification path for this repository. The reliable local debug path is the explicit `kubectl port-forward` flow used by:

```bash
./scripts/verify-local.sh
```

For more detail on port exposure and routing behavior in WSL, see [docs/WSL_NOTES.md](docs/WSL_NOTES.md).

### ArgoCD Force Resync

If ArgoCD is stuck on stale comparison data or cached manifest-generation failures, force a hard refresh and sync for all Applications:

```bash
KUBECONFIG_PATH="$(terraform -chdir=terraform/cluster output -raw kubeconfig_path)"
KUBE_CONTEXT="$(terraform -chdir=terraform/cluster output -raw kube_context)"

for app in $(kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" -n argocd get applications.argoproj.io -o name | sed 's#.*/##'); do
  kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite
  kubectl --kubeconfig "$KUBECONFIG_PATH" --context "$KUBE_CONTEXT" -n argocd patch application "$app" --type merge -p '{"operation":{"sync":{"prune":true}}}'
done
```

Where the reconciliation/cache timing values are defined:

- Poll interval (`timeout.reconciliation` and `timeout.reconciliation.jitter`) in `ConfigMap/argocd-cm`.
- Repo/manifests cache and revision cache settings in `ConfigMap/argocd-cmd-params-cm` (repo-server parameters, for example `reposerver.repo.cache.expiration`).

## Repository Layout

This section is for contributors who want to understand where the main pieces live after the initial setup flow is clear.

- `terraform/cluster`: local k3d cluster lifecycle
- `terraform/platform`: platform add-ons, namespaces, Helm releases, and manifest application
- `manifests/gateway`: GatewayClass, Gateway, and HTTPRoute templates
- `manifests/apps/landing`: landing page workload manifests reconciled by ArgoCD
- `manifests/apps/whoami`: repo-stored Helm values consumed by the `whoami` ArgoCD `Application`
- `manifests/argocd`: ArgoCD `Application` templates for app workloads
- `scripts`: bootstrap, verification, password retrieval, and teardown

The `landing` is reconciled from repository-managed manifests, while `whoami` is reconciled from the third-party `cowboysysop/whoami` Helm chart with values pinned in `manifests/apps/whoami/values.yaml`.

## Architecture and Design Docs

Use these documents when you need more than onboarding and first-run instructions:

- [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md): architectural choices, tradeoffs, and selected patterns
- [docs/GATEWAY_API_VS_INGRESS.md](docs/GATEWAY_API_VS_INGRESS.md): why this repository uses Gateway API
- [docs/CONTROLLER_SWAP.md](docs/CONTROLLER_SWAP.md): maintainer-oriented controller extension path

## Limitations and Further Reading

This README is intentionally focused on first-run success and the common local workflow. For deeper operational or conceptual material, use the repository docs directly:

- [docs/KNOWN_LIMITATIONS_AND_NEXT_STEPS.md](docs/KNOWN_LIMITATIONS_AND_NEXT_STEPS.md): current limitations, non-goals, and next steps
- [docs/WSL_NOTES.md](docs/WSL_NOTES.md): WSL assumptions, localhost behavior, and routing notes
- [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md): design rationale and implications
- [docs/GATEWAY_API_VS_INGRESS.md](docs/GATEWAY_API_VS_INGRESS.md): Gateway API context
- [docs/CONTROLLER_SWAP.md](docs/CONTROLLER_SWAP.md): maintainer workflow for adding another controller
- [AI_USAGE.md](AI_USAGE.md): AI provenance for repository content

## Appendix: Register for ngrok and obtain required values

Use this appendix if you have not set up ngrok yet and need the three values used by this repository:

- `NGROK_API_KEY`
- `NGROK_AUTHTOKEN`
- `NGROK_STATIC_DOMAIN`

### 1. Create an ngrok account

Sign up at [dashboard.ngrok.com/signup](https://dashboard.ngrok.com/signup) and complete the account verification steps shown in the dashboard.

### 2. Create an API key

This repository uses an ngrok API key so Terraform and the operator can manage ngrok resources.

1. Open [dashboard.ngrok.com/api-keys](https://dashboard.ngrok.com/api-keys).
2. Create a new API key.
3. Copy the generated value into `.env` as `NGROK_API_KEY`.

ngrok documents API keys as dashboard-managed credentials for access to the ngrok API.

### 3. Obtain an authtoken

This repository also needs an ngrok authtoken so the ngrok agent/operator can authenticate to ngrok.

1. Open [dashboard.ngrok.com/get-started/your-authtoken](https://dashboard.ngrok.com/get-started/your-authtoken).
2. Copy your default authtoken, or create a separate authtoken in the dashboard if you want tighter isolation for this environment.
3. Save that value in `.env` as `NGROK_AUTHTOKEN`.

ngrok notes that newly provisioned authtokens are fully shown only once, so store them securely when created.

### 4. Reserve a static domain

The default public URLs in this repository assume a reserved ngrok domain such as `your-name.ngrok.app`.

1. Open [dashboard.ngrok.com/domains](https://dashboard.ngrok.com/domains).
2. Use `New +` to reserve a domain.
3. Choose a free ngrok subdomain under `ngrok.app`, or use a custom domain you already control if that fits your account and DNS setup.
4. Copy the reserved hostname into `.env` as `NGROK_STATIC_DOMAIN`.

For this repository, the value should be just the hostname, for example:

```bash
NGROK_STATIC_DOMAIN="example-name.ngrok.app"
```

### 5. Update `.env`

After you have all three values, your `.env` should look like:

```bash
NGROK_API_KEY="<your-ngrok-api-key>"
NGROK_AUTHTOKEN="<your-ngrok-authtoken>"
NGROK_STATIC_DOMAIN="<your-static-domain.ngrok.app>"
```
