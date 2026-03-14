# DESIGN_DECISIONS

## Decision 1: Two-stage Terraform layout

- Selected option: Separate `terraform/cluster` and `terraform/platform` states.
- Alternatives considered: Single Terraform root.
- Rationale: Isolates cluster lifecycle from platform add-ons and avoids accidental full teardown.
- Tradeoffs: Slightly more orchestration in scripts.
- Implications: `scripts/up.sh` and `scripts/destroy.sh` run stages in order.

## Decision 2: k3d provisioning via Terraform `null_resource`

- Selected option: Terraform triggers `k3d cluster create/delete` through `local-exec`.
- Alternatives considered: Unofficial third-party k3d Terraform providers, shell-only scripts without Terraform state ownership.
- Rationale: Keeps Terraform as the orchestration and state layer while relying on the mature `k3d` CLI for actual cluster lifecycle operations.
- Tradeoffs: Local-exec is less declarative than a well-supported native provider resource.
- Implications: Host tooling (`k3d`, `kubectl`) must be present on the local Debian-family Linux environment.

## Decision 3: Maintain a repo-local kubeconfig file for the managed cluster

- Selected option: Write cluster kubeconfig to a repo-scoped path under `.kube/` and pass that explicit path into the platform stage and helper scripts.
- Alternatives considered: Write directly into the user's default `~/.kube/config`, rely on ambient `KUBECONFIG`, or require manual kubeconfig export before platform apply.
- Rationale:
  - Keeps the Terraform stage handoff deterministic because `terraform/platform` and the helper scripts consume one known kubeconfig path.
  - Avoids mutating the user's default kubeconfig and current-context during bootstrap.
  - Reduces cross-project interference when multiple local clusters or repositories exist on the same machine.
  - Makes teardown straightforward because the generated kubeconfig can be removed with the managed cluster.
- Tradeoffs:
  - Interactive tooling does not automatically see the cluster unless users pass `--kubeconfig` or set `KUBECONFIG`.
  - The kubeconfig data is duplicated instead of merged into the user's global kubeconfig.
- Implications:
  - `.kube/` stays ignored in Git.
  - Terraform outputs and scripts treat kubeconfig as a managed local artifact, not as a global workstation setting.

## Decision 4: Disable bundled k3s networking components

- Selected option:
  - Disable bundled Traefik with `--disable=traefik` during cluster creation.
  - Disable bundled ServiceLB with `--disable=servicelb` during cluster creation.
- Alternatives considered:
  - Keep default k3s Traefik and layer platform Traefik on top.
  - Keep the default k3s ServiceLB and expose selected Services with `type: LoadBalancer`.
- Rationale:
  - Disabling bundled Traefik prevents controller duplication and listener conflicts.
  - The repository does not use `Service` `LoadBalancer` objects as its primary exposure model.
  - `k3d` host port mappings provide the local entrypoints, and ngrok provides public exposure in front of Traefik.
  - The platform-managed Traefik `Service` remains `ClusterIP`, so the bundled service load balancer would add an unused controller and an unnecessary extra layer.
- Tradeoffs:
  - Cluster bootstrap is slightly less turnkey because networking components are installed intentionally instead of accepted from k3s defaults.
  - The default k3s local `LoadBalancer` workflow is unavailable unless the bootstrap model is changed.
  - Future adoption of `Service` `LoadBalancer` exposure would require revisiting this choice.
- Implications:
  - The Gateway controller is always managed by `terraform/platform`.
  - Local ingress entrypoints are owned by `k3d` port mappings created at cluster bootstrap.
  - Public exposure remains an ngrok concern, not a k3s `ServiceLB` concern.

## Decision 5: Traefik as default Gateway API controller

- Selected option: Traefik chart with Gateway provider enabled, Ingress provider disabled.
- Alternatives considered: NGINX Gateway Fabric, Envoy Gateway.
- Rationale:
  - Traefik gives the repository a simple local default: one controller, direct Gateway API support, and a lightweight setup that works well in k3d.
  - Disabling Traefik's Ingress provider keeps the routing model focused on Gateway API instead of mixing two Kubernetes traffic APIs in the same stack.
  - This keeps the design easier to explain: Traefik is the implementation choice, while Gateway API is the architectural choice.
- Tradeoffs:
  - The installation still needs Traefik-specific Helm values, so the default setup is not controller-neutral at the chart layer.
  - Some operational behavior and tuning remain controller-specific until another controller is introduced.
- Implications:
  - Replacing Traefik later should mainly require swapping the controller Helm release and updating the `GatewayClass.spec.controllerName`.
  - The `Gateway` and `HTTPRoute` resources can stay mostly unchanged because they target the Gateway API, not Traefik's legacy `Ingress` model.

## Decision 6: Keep Gateway resources explicit (not chart-generated)

- Selected option: Terraform applies explicit `GatewayClass`, `Gateway`, and `HTTPRoute` manifests.
- Alternatives considered: Let Traefik chart auto-create gateway resources.
- Rationale:
  - Keeping these resources in repository-managed manifests makes the routing layer visible and reviewable in Git instead of hiding it inside chart defaults.
  - It also keeps the architecture more portable: the Gateway API objects describe the intended traffic model independently from whichever controller is installed underneath.
  - This separation keeps the design easier to justify because controller installation and routing design remain distinct concerns.
- Tradeoffs:
  - There are more manifests to own and maintain than in a chart-driven setup.
  - The team must understand both the controller chart configuration and the explicit Gateway API resources.
- Implications:
  - Swapping to another controller does not require regenerating the full routing layer from that controller's chart conventions.
  - The core `GatewayClass`, `Gateway`, and `HTTPRoute` manifests remain the source of truth, with only controller-specific wiring changed where necessary.

## Decision 7: Manage platform namespaces as Terraform resources

- Selected option: Pre-create platform namespaces with `kubernetes_namespace_v1` and keep `helm_release.create_namespace = false`.
- Alternatives considered: Let each Helm release create its own namespace implicitly with `create_namespace = true`.
- Rationale:
  - Namespace lifecycle is shared across Helm releases and standalone `kubernetes_manifest` resources, so Terraform needs explicit namespace objects it can depend on directly.
  - Consistent labels are applied from one place through `local.namespace_labels`, including namespaces that are not owned by any Helm release such as `routes-system`, `landing`, and `whoami`.
  - Central namespace ownership keeps the platform state easier to reason about than splitting responsibility between the Helm and Kubernetes providers.
- Tradeoffs:
  - Adds a small amount of extra Terraform code compared with Helm-driven namespace creation.
  - Requires namespace changes to flow through the Kubernetes provider even for chart-specific namespaces.
- Implications:
  - Helm releases target pre-existing namespaces and do not create them.
  - Non-Helm manifests can declare explicit dependencies on namespace resources.
  - Namespace labels and future namespace-level metadata remain centralized in one Terraform block.

## Decision 8: Cross-namespace routing with `ReferenceGrant` from day one

- Selected option: `HTTPRoute` in `routes-system`, backends in service namespaces, grants in backend namespaces.
- Alternatives considered: Route and workloads in same namespace.
- Rationale: Matches multi-team separation model and explicit trust boundaries.
- Tradeoffs: More resources and moving parts.
- Implications: Backend namespace owners control allowed cross-namespace references.

## Decisio n 9: ArgoCD behind `/argocd` using internal HTTP

- Selected option: `server.insecure=true`, `server.basehref=/argocd`, `server.rootpath=/argocd`.
- Alternatives considered: End-to-end TLS into ArgoCD, dedicated hostname.
- Rationale: Reliable path-prefix behavior behind Gateway with less TLS complexity.
- Tradeoffs: Internal hop is HTTP within cluster network.
- Implications: Public TLS still terminates at Gateway/Traefik.

## Decision 10: Landing stays Git-managed while whoami uses a Helm chart with repo-stored values

- Selected option: Keep `landing` as repository-managed manifests, and switch `whoami` to an ArgoCD multi-source `Application` that renders the third-party `cowboysysop/whoami` Helm chart while reading values from `manifests/apps/whoami/values.yaml` in this repository.
- Alternatives considered: Keep `whoami` as repository-managed manifests, or use an official upstream `whoami` chart source.
- Rationale:
  - The assignment requires deploying `whoami` through a Helm chart via an ArgoCD `Application`.
  - As of 2026-03-08, the official Traefik chart repository at `https://traefik.github.io/charts/index.yaml` still does not publish a `whoami` chart entry, so an official upstream chart source is not available.
  - ArgoCD multi-source keeps values in Git while delegating workload templating to Helm.
  - Pinned values preserve the current service shape, resource names, and health-check timing used by the existing Gateway route and verification scripts.
- Tradeoffs:
  - `whoami` now depends on a third-party chart repository instead of only this Git repository.
  - The design is less self-contained than repository-managed manifests.
  - ArgoCD must fetch both the Git repository and the external Helm repository for a healthy sync.
- Implications:
  - Terraform still applies ArgoCD `Application` resources.
  - ArgoCD reconciles `landing` from `manifests/apps/landing`.
  - ArgoCD reconciles `whoami` from the `cowboysysop/whoami` chart plus repo-stored values in `manifests/apps/whoami/values.yaml`.

## Decision 11: Default ArgoCD repo URL is inferred from local Git origin

- Selected option: `scripts/up.sh` infers `GIT_REPOSITORY_URL` from `git remote get-url origin` when the variable is unset.
- Alternatives considered: Mandatory manual export of `GIT_REPOSITORY_URL`.
- Rationale: Reduces bootstrap friction on the local Debian-family Linux environment while keeping the ArgoCD Git source explicit.
- Additional rationale: ArgoCD needs a cloneable repository URL from inside the cluster, so GitHub SSH origin (`git@github.com:OWNER/REPO.git`) is normalized to HTTPS (`https://github.com/OWNER/REPO.git`).
- Tradeoffs: Default flow intentionally supports only clear GitHub clone URL formats and fails fast for unsupported origins.
- Implications: Users can still override with explicit `GIT_REPOSITORY_URL`; private repo sync still requires ArgoCD repository credentials.

## Decision 12: Optional repo-root `.env` for ngrok bootstrap inputs

- Selected option: `scripts/up.sh` optionally loads a repo-root `.env` file before input validation.
- Alternatives considered: Terraform variables, pre-created Kubernetes Secrets, external secret managers.
- Rationale: This repository is optimized for fast local bootstrap on Debian-family Linux; `.env` avoids repetitive manual exports while keeping the script interface simple.
- Tradeoffs: `.env` is convenience-first local handling, not a hardened long-term secret-management pattern.
- Override model: Explicitly exported environment variables still take precedence over `.env` values.
- Why alternatives were not default:
  - Terraform variables: workable, but adds extra variable-file/operator ceremony for an intentionally simple local bootstrap path.
  - Pre-created Kubernetes Secrets: pushes users into cluster-preparation steps before bootstrap succeeds.
  - External secret managers: better for production, but adds integration complexity and credentials plumbing beyond the local-first scope here.

## Decision 13: Two-phase platform apply for CRD-backed manifests

- Selected option: `scripts/up.sh` runs the platform stage in two applies on bootstrap. The first apply targets the CRD-producing Helm release wait resources, and the second apply runs the full platform state.
- Alternatives considered: Single `terraform apply`, manual pre-install commands outside Terraform, splitting CRD-backed manifests into a separate Terraform state.
- Rationale:
  - `helm_release` can pass chart flags such as `crds.enabled=true`, and this repository already does that for cert-manager.
  - That flag only affects Helm install behavior during apply. It does not change Terraform's planning behavior for `kubernetes_manifest`.
  - `kubernetes_manifest` validates GroupVersionKind against the live API during planning, so a fresh cluster fails before Helm has a chance to install missing CRDs in the same apply.
  - Keeping the bootstrap inside `scripts/up.sh` preserves one supported entrypoint and avoids asking users to run out-of-band `helm` or `kubectl` commands.
- Tradeoffs:
  - Bootstrap orchestration is less elegant than a single apply.
  - Targeted apply introduces some extra script logic and relies on the current resource graph shape.
  - A later refactor to split CRD producers and CRD consumers into separate Terraform roots could remove this workaround at the cost of more state management.
- Implications:
  - Helm chart CRD flags should still be enabled when the chart supports them, but they are not treated as sufficient for first-run planning safety.
  - Fresh-cluster bootstrap behavior is encoded in `scripts/up.sh`, not delegated to operator memory.

## ArgoCD reconciliation model and sync triggers

- Terraform installs ArgoCD and applies the `Application` resource. ArgoCD then reconciles the workload defined by that `Application`.
- ArgoCD continuously reconciles the `Application` resource in the cluster.
- Desired state is derived from:
  - Git repository URL
  - tracked revision
  - application source type and location
  - pinned chart version, where applicable
- In this repository:
  - `repoURL` is derived from the local Git origin during bootstrap.
  - `targetRevision` defaults to `main`.
  - `landing` uses:
    - `path: manifests/apps/landing`
  - `whoami` uses:
    - chart repo: `https://cowboysysop.github.io/charts/`
    - chart: `whoami`
    - chart version: `6.0.0`
    - values file: `manifests/apps/whoami/values.yaml`

- What triggers sync:
  - initial `Application` creation
  - `Application.spec` changes
  - new commits affecting `manifests/apps/landing` or `manifests/apps/whoami/values.yaml` at the tracked revision
  - change of `targetRevision`
  - chart version changes in the `whoami` `Application`
  - manual sync or refresh
  - live cluster drift when self-heal is enabled
  - periodic reconciliation

- What does not trigger sync:
  - editing files locally without pushing
  - changing `.env` after bootstrap
  - re-running Terraform without changing the `Application`
  - changes outside `manifests/apps/landing` and `manifests/apps/whoami/values.yaml`
  - unrelated repository commits

## Decision 14: cert-manager self-signed issuer for Gateway TLS

- Selected option: Namespace-local self-signed `Issuer` + `Certificate` in `gateway-system`.
- Alternatives considered: ACME/Let’s Encrypt, manual TLS secret.
- Rationale: Local-dev friendly and deterministic.
- Tradeoffs: Upstream TLS certificate is not publicly trusted.
- Implications: Appropriate for local/testing, not public production trust chains.

## Decision 15: No `BackendPolicy` in default stack

- Selected option: Rely on readiness/liveness probes for whoami backend health.
- Alternatives considered: Controller-specific backend policy resources.
- Rationale: Keeps base Gateway API layer portable.
- Tradeoffs: Advanced backend policy controls are deferred.
- Implications: Controller-specific backend policy can be added later when needed.

## Decision 16: Root path `/` serves a tiny landing page

- Selected option: Add a dedicated `landing` backend routed by an explicit `HTTPRoute` with `PathPrefix: /`.
- Alternatives considered: Keep `/` unmatched (404), or reuse an existing app as root.
- Rationale:
  - Gives a minimal default backend and clear navigation to `/argocd` and `/whoami`.
  - Keeps path routing explicit in Gateway API manifests while preserving longest-prefix behavior for `/argocd` and `/whoami`.
- Tradeoffs: Adds one small workload and one additional `Application`/`HTTPRoute`/`ReferenceGrant`.
- Implications:
  - Public entrypoints are `/`, `/argocd`, and `/whoami`.
  - ngrok Ingress exposure and Traefik Gateway API control-plane roles stay unchanged.
