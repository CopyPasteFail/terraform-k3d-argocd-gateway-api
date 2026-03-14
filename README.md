# terraform-k3d-argocd-gateway-api

Production-style local platform stack for Debian-family Linux using Terraform, k3d, Gateway API, ArgoCD, cert-manager, and ngrok.

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


## Prerequisites

Use `make check-tools` to validate your environment prerequisites.
If tools are missing, you can either install them manually or run `sudo make install-tools` to install only the missing tools with the repository's preferred install strategy.

- Debian-family Linux distribution
- Docker Engine installed and running
- `terraform`
- `bash`
- `k3d`
- `kubectl`
- `curl`
- `base64`
- `git`
- `tail`
- `ripgrep` (`rg`)
- A reserved [ngrok](https://dashboard.ngrok.com/signup) **static domain**, **API key** and **authtoken**
  > If you do not already have your ngrok credentials and reserved domain, see [Appendix: Register for ngrok and obtain required values](#appendix-register-for-ngrok-and-obtain-required-values).

## Quick Start

Run these steps in order:

```bash
cp .env.example .env
```

Then edit `.env` and set:

- `NGROK_API_KEY`
- `NGROK_AUTHTOKEN`
- `NGROK_STATIC_DOMAIN`

Continue with:

```bash
make check-tools
# Run this only if make check-tools reports missing tools.
sudo make install-tools
make print-derived-git-source
make up STAGE=both
make verify
make password
```

Notes:

- `make check-tools` prints every missing tool, reports Docker daemon access problems, and suggests `sudo make install-tools` when tools are missing.
- `sudo make install-tools` installs only the missing tools.
  - Simpler packages are installed with `apt`.
  - Custom install paths:
    - `k3d`: upstream installer
    - `kubectl`: latest stable upstream binary for the current Debian architecture
    - `terraform`: HashiCorp apt repository
    - `git`: Git Core PPA on Ubuntu-family hosts
- When `sudo make install-tools` needs the HashiCorp apt repository or the Git Core PPA, it now checks whether that repository is already active or already configured in the local apt sources before trying to add it again.
- For the repo-backed `git` and `terraform` installs, `sudo make install-tools` refreshes apt metadata for that tool and verifies that the preferred repository is active before installing the package.
- `make up STAGE=both` is the default full bootstrap path.
- `make up STAGE=cluster` and `make up STAGE=platform` are available when you want to run the Terraform stages separately.
- `make verify-local` verifies routing through a local `kubectl port-forward` path when public ngrok verification is not the right first check.
- `make password` prints the initial ArgoCD admin password.

### Expected Endpoints

After provisioning succeeds, the public base URL is:

- `https://<your-static-domain>`

The expected application paths are:

- Landing page: `https://<your-static-domain>/`
- ArgoCD: `https://<your-static-domain>/argocd`
- whoami: `https://<your-static-domain>/whoami`

## Important Defaults and Caveats

Read this section before setup. These are the defaults most likely to affect whether bootstrap succeeds.

- This repository is supported only on Debian-family Linux distributions.
- **Docker Engine** must be installed and running.
- A reserved **ngrok** static domain is required for the default public access path.
- `make print-derived-git-source` can derive `GIT_REPOSITORY_URL` from the local Git `origin` if that origin is a supported GitHub URL. Manual configuration is still available when needed.
- **ArgoCD** must be able to reach the repository URL you provide anonymously over HTTPS. If the repository is private, app `Application` syncs will fail unless credentials are configured.
- The `whoami` **ArgoCD** `Application` also depends on the external Helm repository `https://cowboysysop.github.io/charts/` being reachable from the cluster.
- Gateway TLS is self-signed inside the cluster. This stack is intended for local/testing use, not a public production trust chain.
- **ngrok** is only the public exposure layer. `Traefik` remains the Gateway API controller for route attachment and path routing.
- The default implementation uses **ngrok** `Ingress` exposure; `AgentEndpoint`, `BoundEndpoint`, and `CloudEndpoint` are not part of the expected happy path.
- This default was selected because the previously tested custom `AgentEndpoint` path did not reconcile reliably in the tested operator/runtime combination, while the operator already supports an ingress-based path.
- **ngrok** ingress forwards upstream to the Traefik `websecure` listener (`Service:443`) with `k8s.ngrok.com/app-protocols` set so upstream protocol remains HTTPS.
- Earlier revisions coupled verification to bindings-oriented expectations; that coupling has been removed from the default public model.
- Public browser access goes through **ngrok**. On the **ngrok** free tier, browser visits to HTML endpoints can show an interstitial warning once. Localhost ports are for debugging only.
- The bootstrap flow writes a dedicated `kubeconfig` under repo-local `.kube/` instead of modifying `~/.kube/config`, so the cluster and platform stages share a deterministic handoff artifact without mutating the user's global `kubeconfig`.
- The platform stage uses a two-phase `Terraform apply` on fresh clusters: first it installs Helm releases and waits for `CRD`s, then it runs a full apply for CRD-backed `kubernetes_manifest` resources.

For local-networking observations running on WSL environment, see [docs/LOCAL_NETWORKING_NOTES.md](docs/LOCAL_NETWORKING_NOTES.md).
For current non-goals and limitations, see [docs/KNOWN_LIMITATIONS_AND_NEXT_STEPS.md](docs/KNOWN_LIMITATIONS_AND_NEXT_STEPS.md).

## Configuration

The recommended local workflow is to create a repo-root `.env` file.

> Exported environment variables still take precedence over values loaded from `.env`.

Configure the following inputs:

- `NGROK_API_KEY`
- `NGROK_AUTHTOKEN`
- `NGROK_STATIC_DOMAIN`

Optional inputs:

- `GIT_REPOSITORY_URL`
- `GIT_TARGET_REVISION` (defaults to `main`)

Leave `GIT_REPOSITORY_URL` unset if you want it to be derived from the current Git `origin`.

### ArgoCD Git source validation

If you want to validate only the derived ArgoCD Git source before any Terraform work starts, run:

```bash
make print-derived-git-source
```

That validation is useful when:

- you want to confirm Git origin auto-detection
- you want to check the normalized GitHub HTTPS clone URL
- you want to fail early before cluster or platform provisioning begins

## Day-2 Operations

### Re-run and Teardown

Use this when you want to remove the platform and the cluster from the current machine.

```bash
make destroy
```

### Local Debugging

Direct `localhost:8080` and `localhost:8443` access is not a supported verification path for this repository. The reliable local debug path is the explicit `kubectl port-forward` flow used by:

```bash
make verify-local
```

For more detail on local port exposure and environment-specific observations, see [docs/LOCAL_NETWORKING_NOTES.md](docs/LOCAL_NETWORKING_NOTES.md).

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
- `scripts`: internal implementation used by the `Makefile` entrypoints

The `landing` is reconciled from repository-managed manifests, while `whoami` is reconciled from the third-party `cowboysysop/whoami` Helm chart with values pinned in `manifests/apps/whoami/values.yaml`.

## Architecture and Design Docs

Use these documents when you need more than onboarding and first-run instructions:

- [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md): architectural choices, tradeoffs, and selected patterns
- [docs/GATEWAY_API_VS_INGRESS.md](docs/GATEWAY_API_VS_INGRESS.md): why this repository uses Gateway API

## Limitations and Further Reading

This README is intentionally focused on first-run success and the common local workflow. For deeper operational or conceptual material, use the repository docs directly:

- [docs/KNOWN_LIMITATIONS_AND_NEXT_STEPS.md](docs/KNOWN_LIMITATIONS_AND_NEXT_STEPS.md): current limitations, non-goals, and next steps
- [docs/LOCAL_NETWORKING_NOTES.md](docs/LOCAL_NETWORKING_NOTES.md): local networking behavior, localhost notes, and routing observations
- [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md): design rationale and implications
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
