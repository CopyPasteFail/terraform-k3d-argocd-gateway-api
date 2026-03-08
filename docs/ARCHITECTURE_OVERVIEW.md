# ARCHITECTURE_OVERVIEW

This document is the shortest path to understanding what this repository builds, why the files are split the way they are, and how the moving parts connect during bootstrap and at runtime.

It is written for readers who want a clear working understanding of Terraform, Kubernetes, Gateway API, and Argo CD in the context of this repository.

## In a nutshell

this repository bootstraps a local Kubernetes platform where Terraform creates the cluster and shared control plane, Traefik implements Gateway API routing, cert-manager provides the Gateway TLS Secret, ngrok exposes the shared entrypoint publicly, and Argo CD continuously deploys the app workloads from Git.

## 1. What this repository actually builds

This repository builds a local Kubernetes platform with one public hostname and three public paths:

- `/`
- `/argocd`
- `/whoami`

The platform is designed in layers:

1. `terraform/cluster` creates a local `k3d` Kubernetes cluster.
2. `terraform/platform` installs the shared platform components into that cluster.
3. Terraform also creates the Kubernetes routing, TLS, and Argo CD `Application` resources that describe what should run.
4. Argo CD then reads this Git repository and deploys the app workloads.

The result is a split responsibility model:

- Terraform bootstraps and wires the platform.
- Argo CD reconciles the applications.
- Traefik implements Gateway API routing inside the cluster.
- ngrok exposes the local cluster to the internet.
- cert-manager issues the TLS Secret used by the Gateway.

## 1.1 Architecture in one diagram

```text
Internet
  |
  v
ngrok public endpoint
  |
  v
Ingress (gateway-system/platform-public-ingress)
  |
  v
Traefik Service :443
  |
  v
Traefik Gateway API controller
  |
  v
Gateway (shared HTTPS listener)
  |
  +--> HTTPRoute /        -> Service/landing       -> landing Pod
  +--> HTTPRoute /argocd  -> Service/argocd-server -> Argo CD server Pod
  +--> HTTPRoute /whoami  -> Service/whoami        -> whoami Pod

Terraform creates the cluster, controllers, Gateway resources, and Argo CD Applications.
Argo CD then deploys the landing and whoami app workloads from Git.
```

## 2. Architecture overview

The system can be understood from two perspectives.

### Bootstrap

- Terraform stage 1 creates a local cluster and writes a kubeconfig file.
- Terraform stage 2 connects to that cluster and installs controllers and shared resources.
- Terraform creates Argo CD `Application` objects.
- Argo CD reads this repository and creates the app workloads.

### Runtime

- A browser hits `https://<your-static-domain>`.
- ngrok receives the public request and forwards it to Traefik inside the cluster.
- Traefik evaluates Gateway API resources.
- The matching `HTTPRoute` sends the request to the correct Kubernetes `Service`.
- The `Service` sends traffic to the target Pod.

That separation is the core conceptual structure of the repo:

- bootstrap is mostly Terraform
- steady-state app delivery is mostly Argo CD
- request routing is mostly Gateway API + Traefik
- internet exposure is mostly ngrok

## 3. Directory map

### `terraform/cluster`

This is the infrastructure stage for the local Kubernetes cluster itself.

- [`terraform/cluster/main.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/cluster/main.tf)
  Creates or reuses a `k3d` cluster by calling the `k3d` CLI from a Terraform `null_resource`.
- [`terraform/cluster/variables.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/cluster/variables.tf)
  Defines cluster-shape inputs such as cluster name, node counts, exposed host ports, and kubeconfig destination.
- [`terraform/cluster/outputs.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/cluster/outputs.tf)
  Exposes the kubeconfig path, kube context, and local URLs so the next stage and helper scripts can consume them.
- [`terraform/cluster/versions.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/cluster/versions.tf)
  Pins Terraform and provider versions for this stage.

### `terraform/platform`

This is the platform stage that installs shared cluster services and applies shared manifests.

- [`terraform/platform/main.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/platform/main.tf)
  The main platform orchestration file. It creates namespaces, installs Helm releases, renders manifest templates, and applies Kubernetes resources in a safe order.
- [`terraform/platform/variables.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/platform/variables.tf)
  Defines inputs such as the public hostname, ngrok credentials, Git repository URL, chart versions, and selected Gateway controller.
- [`terraform/platform/outputs.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/platform/outputs.tf)
  Exposes public URLs and stable identifiers used by verification scripts.
- [`terraform/platform/values/traefik-values.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/platform/values/traefik-values.yaml.tpl)
  Configures Traefik to act as a Gateway API controller and disables classic Ingress handling.
- [`terraform/platform/values/argocd-values.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/platform/values/argocd-values.yaml.tpl)
  Configures Argo CD to work correctly behind the `/argocd` path prefix.
- [`terraform/platform/values/ngrok-operator-values.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/platform/values/ngrok-operator-values.yaml.tpl)
  Configures the ngrok operator with credentials and enables the Ingress-based exposure model.

### `manifests/`

This directory contains the Kubernetes objects that define routing, TLS, GitOps applications, and app workloads.

- `manifests/gateway/`
  Gateway API resources: `GatewayClass`, `Gateway`, and `HTTPRoute`.
- `manifests/cert-manager/`
  TLS issuance resources used by the Gateway.
- `manifests/ngrok/`
  The public `Ingress` that tells ngrok what to expose.
- `manifests/argocd/`
  Argo CD `Application` resources that tell Argo CD what apps to deploy.
- `manifests/referencegrants/`
  Gateway API trust declarations for cross-namespace routing.
- `manifests/apps/landing/`
  The landing app's Kubernetes manifests.
- `manifests/apps/whoami/`
  The values file used when Argo CD renders the third-party `whoami` Helm chart.

## 4. Why there are two Terraform stages

The repo intentionally splits the infrastructure into:

- `terraform/cluster`
- `terraform/platform`

This is not just cosmetic.

The cluster stage creates the Kubernetes API endpoint and kubeconfig artifact. The platform stage depends on that artifact to connect to the cluster and install everything else.

This split gives three practical benefits:

- It reduces accidental teardown risk because cluster lifecycle is isolated from platform add-ons.
- It creates a clear handoff artifact: the repo-local kubeconfig file.
- It keeps local-cluster concerns separate from Kubernetes resource concerns.

The tradeoff is orchestration complexity. The repo needs wrapper scripts such as `./scripts/up.sh` to run both stages in order.

## 5. Bootstrap flow, step by step

This section explains what happens when you run `./scripts/up.sh`.

### Step 1: create the local cluster

[`terraform/cluster/main.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/cluster/main.tf) uses a `null_resource` and `local-exec` to run `k3d cluster create`.

Why use `local-exec`?

- `k3d` is a CLI tool.
- The viable Terraform-provider alternatives are unofficial third-party providers rather than a clearly established default provider for `k3d`.
- The repo still wants Terraform state and inputs/outputs around cluster creation.
- Terraform becomes the orchestration layer even though the actual cluster creation is delegated to the CLI.

Important implementation details:

- bundled k3s Traefik is disabled
- bundled k3s service load balancer is disabled
- a repo-local kubeconfig file is written under `.kube/`

Why disable bundled Traefik?

Because the platform stage installs its own Traefik with explicit Gateway API configuration. Keeping the default one would create controller duplication and unclear ownership.

Why disable the bundled k3s service load balancer?

Because this architecture does not expose workloads through Kubernetes `Service` objects of type `LoadBalancer`. Local entrypoints are created by `k3d` host port mappings, the platform-managed Traefik `Service` stays `ClusterIP`, and ngrok is responsible for public exposure. Keeping the bundled k3s service load balancer would add a component that this repository does not use.

### Step 2: connect Terraform providers to the cluster

[`terraform/platform/main.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/platform/main.tf) configures the `kubernetes` and `helm` providers to use the kubeconfig path and context from stage 1.

This is the handoff between stages.

### Step 3: create platform namespaces

The platform stage pre-creates namespaces such as:

- `gateway-system`
- `routes-system`
- `argocd`
- `cert-manager`
- `ngrok-system`
- `landing`
- `whoami`

Why create namespaces explicitly in Terraform instead of letting Helm do it?

- Shared ownership is clearer.
- Non-Helm resources can depend on namespaces directly.
- Labels stay centralized.

### Step 4: install platform controllers with Helm

The platform stage installs four major components:

- `cert-manager`
- `traefik`
- `argocd`
- `ngrok-operator`

These are installed in a deliberate order.

#### `cert-manager`

Installed first because later resources use cert-manager CRDs and need certificate issuance.

#### `traefik`

Installed as the Gateway API controller. It watches `GatewayClass`, `Gateway`, and `HTTPRoute` resources.

Important design choice:

- Traefik Ingress provider is disabled
- Traefik Gateway provider is enabled

That means Traefik is responsible for Gateway API, not for generic Ingress resources in this design.

#### `argocd`

Installed before Terraform creates Argo CD `Application` resources.

The values file configures Argo CD to work behind `/argocd`, which matters because this repo uses path-based routing on a shared hostname instead of a dedicated Argo CD hostname.

#### `ngrok-operator`

Installed so a Kubernetes `Ingress` can create public ngrok exposure.

Important design choice:

- ngrok is used as the public exposure layer
- ngrok is not the Gateway API controller

This is one of the most important architectural distinctions in the repo.

### Step 5: wait for CRDs before creating CRD-backed objects

The platform stage includes explicit waits after Helm installs.

Why?

Because Helm can finish before the Kubernetes API server fully recognizes the new CRDs. If Terraform immediately tries to create CRD-backed objects, planning or apply can fail on fresh clusters.

This is also why the repo uses a two-phase platform apply on first bootstrap.

### Step 6: create TLS resources for the Gateway

The platform stage applies:

- [`manifests/cert-manager/gateway-selfsigned-issuer.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/cert-manager/gateway-selfsigned-issuer.yaml.tpl)
- [`manifests/cert-manager/gateway-certificate.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/cert-manager/gateway-certificate.yaml.tpl)

The `Issuer` says how certificates should be signed.
In this repository, the issuer is:

- namespace-scoped
- named `selfsigned-issuer`
- configured as `selfSigned: {}`

That means cert-manager is the component that issues the certificate object into a Kubernetes Secret, and the certificate is signed by this local self-signed issuer rather than by a public CA such as Let's Encrypt.

The `Certificate` asks cert-manager to produce a TLS Secret for the public hostname.
In practice, the flow is:

1. Terraform applies the `Issuer`.
2. Terraform applies the `Certificate`.
3. cert-manager notices the `Certificate` and uses the `Issuer` named in `issuerRef`.
4. cert-manager generates a private key and certificate for `${public_hostname}`.
5. cert-manager stores the result in the `gateway-system/platform-gateway-tls` Secret.

That Secret is later mounted logically into the Gateway by reference.

So, to answer the concrete ownership questions:

- who issues the certificate: cert-manager
- who signs the certificate: the namespace-local self-signed `Issuer`
- where the certificate is stored: `Secret/gateway-system/platform-gateway-tls`
- who presents that certificate to clients: the Gateway listener implemented by Traefik

Tradeoff:

- self-signed is simple and deterministic for local use
- it is not publicly trusted like a real production certificate chain

### Step 7: create Gateway API resources

The platform stage renders and applies:

- [`manifests/gateway/controllers/traefik/gatewayclass.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/controllers/traefik/gatewayclass.yaml.tpl)
- [`manifests/gateway/core/gateway.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/core/gateway.yaml.tpl)
- route templates under [`manifests/gateway/routes/`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/routes)

These three object types have different roles:

#### `GatewayClass`

Defines which controller should implement Gateway resources.

In this repo, that controller is Traefik.

#### `Gateway`

Defines the shared entrypoint:

- hostname
- listener
- port
- TLS termination
- which namespaces are allowed to attach routes

Shared for all routed apps.

The key TLS detail is in [`manifests/gateway/core/gateway.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/core/gateway.yaml.tpl):

- the listener protocol is `HTTPS`
- `tls.mode` is `Terminate`
- `certificateRefs` points at `Secret/platform-gateway-tls`

That means the Gateway itself terminates TLS. Backend Services such as `landing`, `argocd-server`, and `whoami` receive plain HTTP traffic from Traefik inside the cluster unless they are separately configured for backend TLS.

#### `HTTPRoute`

Defines path matching and backend forwarding.

In this repo:

- `/` goes to the landing app
- `/argocd` goes to the Argo CD server Service
- `/whoami` goes to the whoami Service

### Step 8: create `ReferenceGrant` resources

The repo places routes in `routes-system`, but backends live in other namespaces such as `argocd`, `landing`, and `whoami`.

Gateway API treats cross-namespace references as something that must be explicitly allowed.

That is the purpose of:

- [`manifests/referencegrants/argocd-service-referencegrant.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/referencegrants/argocd-service-referencegrant.yaml)
- [`manifests/referencegrants/landing-service-referencegrant.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/referencegrants/landing-service-referencegrant.yaml)
- [`manifests/referencegrants/whoami-service-referencegrant.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/referencegrants/whoami-service-referencegrant.yaml)

Why this matters:

- without them, a route in one namespace should not be allowed to target a Service in another namespace
- they make trust boundaries explicit
- backend namespace owners stay in control

This is one of the reasons Gateway API is more explicit than classic Ingress in multi-namespace setups.

### Step 9: create Argo CD `Application` resources

Terraform creates:

- [`manifests/argocd/landing-application.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/argocd/landing-application.yaml.tpl)
- [`manifests/argocd/whoami-application.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/argocd/whoami-application.yaml.tpl)

These resources do not deploy app Pods directly.

Instead, they tell Argo CD:

- where the desired state lives
- what revision to watch
- which namespace to deploy into
- whether to prune and self-heal

This is where control transfers from Terraform to Argo CD for app workloads.

### Step 10: expose the platform publicly through ngrok

Terraform applies:

- [`manifests/ngrok/traefik-public-ingress.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/ngrok/traefik-public-ingress.yaml.tpl)

This object is a Kubernetes `Ingress`, but it is not used for app routing in the usual "Ingress controller owns all routing" sense.

Its job here is narrower:

- tell the ngrok Kubernetes operator what public hostname to expose through the ngrok service
- send all incoming traffic to Traefik's HTTPS Service

More specifically, this `Ingress` tells the ngrok Kubernetes operator:

- use `ingressClassName: ngrok`
- watch the host `${public_hostname}`
- match the path prefix `/`
- forward the request to `Service/traefik`
- use backend port `443`

That is how the operator knows how to configure the public ngrok endpoint and where that endpoint should send traffic inside the cluster.

The key idea is that the ngrok Kubernetes operator runs inside Kubernetes and watches normal Kubernetes `Ingress` resources that target the `ngrok` ingress class. When Terraform applies `platform-public-ingress`, the operator reads that object and configures the external ngrok service to expose the configured hostname. The external ngrok service then forwards matching traffic to the declared backend inside the cluster.

In this repository, that backend is not an application `Service` such as `whoami` or Argo CD directly. It is always Traefik on port `443`. Traefik then evaluates the Gateway API resources and decides which application should receive the request.

That means the runtime chain is:

- the external ngrok service handles internet exposure
- the ngrok Kubernetes operator connects the Kubernetes `Ingress` definition to that external ngrok exposure
- Traefik handles Gateway API routing

## 6. Runtime request flow

When a user opens `https://<your-static-domain>/whoami`, the flow is:

1. The browser connects to the public ngrok domain.
2. ngrok forwards the request into the cluster using the `platform-public-ingress` object.
3. The backend for that Ingress is the Traefik Service on port `443`.
4. Traefik receives the HTTPS request and presents the certificate stored in `Secret/gateway-system/platform-gateway-tls`.
5. TLS terminates at the Gateway listener because the listener uses `tls.mode: Terminate`.
6. After decryption, Traefik evaluates the Gateway API resources against the HTTP host and path.
7. The `Gateway` listener for the hostname accepts the request.
8. The `whoami` `HTTPRoute` matches the `/whoami` path.
9. Because a `ReferenceGrant` exists, the route is allowed to reference `Service/whoami` in the `whoami` namespace.
10. The Service forwards plain HTTP traffic to the whoami Pod.

The same pattern applies to `/` and `/argocd`.

## 7. Notable Kubernetes Components

This section is intentionally practical, not textbook-style.

### `GatewayClass`

File:

- [`manifests/gateway/controllers/traefik/gatewayclass.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/controllers/traefik/gatewayclass.yaml.tpl)

Role in this repo:

- declares that Traefik is the implementation behind Gateway API

Without it:

- the `Gateway` would not have a controller to reconcile it

### `Gateway`

File:

- [`manifests/gateway/core/gateway.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/core/gateway.yaml.tpl)

Role in this repo:

- defines the shared HTTPS listener for the public hostname
- terminates TLS using the cert-manager-created Secret
- restricts which namespaces may attach routes

Without it:

- there is no shared front door for application traffic

### `HTTPRoute`

Files:

- [`manifests/gateway/routes/landing-root-httproute.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/routes/landing-root-httproute.yaml.tpl)
- [`manifests/gateway/routes/argocd-httproute.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/routes/argocd-httproute.yaml.tpl)
- [`manifests/gateway/routes/whoami-httproute.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/routes/whoami-httproute.yaml.tpl)

Role in this repo:

- maps URL paths to backend Services

Without them:

- Traefik would have a listener but no app-specific routing rules

### `ReferenceGrant`

Files:

- [`manifests/referencegrants/argocd-service-referencegrant.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/referencegrants/argocd-service-referencegrant.yaml)
- [`manifests/referencegrants/landing-service-referencegrant.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/referencegrants/landing-service-referencegrant.yaml)
- [`manifests/referencegrants/whoami-service-referencegrant.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/referencegrants/whoami-service-referencegrant.yaml)

Role in this repo:

- allows routes from `routes-system` to target Services in other namespaces

Without them:

- cross-namespace backend references would be blocked

### `Issuer` and `Certificate`

Files:

- [`manifests/cert-manager/gateway-selfsigned-issuer.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/cert-manager/gateway-selfsigned-issuer.yaml.tpl)
- [`manifests/cert-manager/gateway-certificate.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/cert-manager/gateway-certificate.yaml.tpl)

Role in this repo:

- define how the Gateway certificate is signed and create the TLS Secret used by the Gateway

More concretely:

- the `Issuer` is a self-signed certificate authority for this namespace
- the `Certificate` requests a certificate for the configured public hostname
- cert-manager writes the signed certificate and private key into `Secret/platform-gateway-tls`
- the `Gateway` references that Secret and uses it to terminate HTTPS

Without them:

- the HTTPS listener would not have a certificate to terminate TLS with

### `Ingress`

File:

- [`manifests/ngrok/traefik-public-ingress.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/ngrok/traefik-public-ingress.yaml.tpl)

Role in this repo:

- tells ngrok what public traffic to expose and where to forward it

Without it:

- the platform could still work locally, but it would not have the default public ngrok exposure path

### `Application`

Files:

- [`manifests/argocd/landing-application.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/argocd/landing-application.yaml.tpl)
- [`manifests/argocd/whoami-application.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/argocd/whoami-application.yaml.tpl)

Role in this repo:

- tells Argo CD what desired state to fetch and keep synced

Without them:

- Argo CD would be installed, but it would not know to deploy `landing` or `whoami`

### `Deployment`, `Service`, and `ConfigMap`

Files:

- [`manifests/apps/landing/deployment.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/apps/landing/deployment.yaml)
- [`manifests/apps/landing/service.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/apps/landing/service.yaml)
- [`manifests/apps/landing/configmap.yaml`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/apps/landing/configmap.yaml)

Role in this repo:

- `Deployment` runs the landing Pod
- `Service` gives it a stable network identity
- `ConfigMap` stores the HTML file mounted into nginx

Without them:

- the root route would have no backend application

## 8. Argo CD role

Argo CD is not responsible for everything in this repository.

It is responsible for application reconciliation after Terraform bootstraps the platform.

In this repo:

- Terraform installs Argo CD itself.
- Terraform creates Argo CD `Application` resources.
- Argo CD reads Git and applies app resources.

That means there are two layers of desired state:

- Terraform desired state for platform bootstrap
- Argo CD desired state for app deployment

This is a common and useful split because platform components and app components often have different lifecycles.

### `landing` app model

`landing` is fully Git-manifest-driven.

Argo CD reads `manifests/apps/landing` from this repository and applies those manifests into the `landing` namespace.

### `whoami` app model

`whoami` is intentionally different.

Argo CD uses a multi-source `Application`:

- one source is the third-party Helm chart repository
- one source is this Git repository for the values file

Why this design exists:

- the repo wants `whoami` deployed via Helm
- the repo still wants the configuration stored in Git in this repository

Tradeoff:

- this is less self-contained than storing all rendered manifests locally
- it adds a dependency on an external chart repository

## 9. Why `routes-system` exists

The `routes-system` namespace is easy to overlook, but it is important to the repo's architecture.

The repo does not store routes in the same namespaces as the app backends.

Instead:

- `HTTPRoute` objects live in `routes-system`
- backend Services live in their own app namespaces
- backend namespaces explicitly allow access via `ReferenceGrant`

Why this is useful:

- it models a shared platform boundary
- route ownership is separated from workload ownership
- cross-namespace trust must be explicit

This is closer to how a multi-team platform might be organized than putting every route next to its backend.

## 10. Why the platform uses both Gateway API and Ingress

At first glance this can look contradictory.

The repo uses:

- Gateway API for internal routing design
- Ingress only for ngrok exposure

Those are different concerns.

Gateway API here answers:

- which controller owns routing?
- what listener exists?
- what paths route to what Services?
- which namespaces may attach routes or reference backends?

Ingress here answers:

- how does ngrok know what public hostname/path set to expose into the cluster?

So the architecture is not "either Ingress or Gateway API."
It is:

- Ingress for the public tunnel attachment
- Gateway API for cluster routing logic

## 11. Main tradeoffs in the current design

### Two Terraform states

Benefit:

- clearer lifecycle boundaries

Cost:

- more wrapper-script orchestration

### `null_resource` for cluster creation

Benefit:

- keeps Terraform in control while using the mature `k3d` CLI

Cost:

- less declarative than a native provider resource

### Explicit Gateway manifests instead of chart-generated ones

Benefit:

- clearer ownership and more portable design

Cost:

- more files to maintain

### Self-signed TLS

Benefit:

- simple and deterministic for local use

Cost:

- not publicly trusted

### ngrok in front of Traefik

Benefit:

- clear separation between public exposure and internal routing

Cost:

- one more integration layer and dependency on ngrok credentials/domain

### Argo CD multi-source `whoami`

Benefit:

- satisfies the Helm-based deployment goal while keeping values in Git

Cost:

- external Helm repository dependency

## 12. Reading order if you want to understand the repo quickly

If you want to connect the files into one story, read them in this order:

1. [`README.md`](/home/omer/repos/terraform-k3d-argocd-gateway-api/README.md)
2. [`terraform/cluster/main.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/cluster/main.tf)
3. [`terraform/platform/main.tf`](/home/omer/repos/terraform-k3d-argocd-gateway-api/terraform/platform/main.tf)
4. [`manifests/gateway/core/gateway.yaml.tpl`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/core/gateway.yaml.tpl)
5. the three route templates under [`manifests/gateway/routes/`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/gateway/routes)
6. the `ReferenceGrant` files under [`manifests/referencegrants/`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/referencegrants)
7. the Argo CD `Application` files under [`manifests/argocd/`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/argocd)
8. the app definitions under [`manifests/apps/`](/home/omer/repos/terraform-k3d-argocd-gateway-api/manifests/apps)

That order mirrors the actual architecture:

- cluster first
- platform second
- shared entrypoint and routes next
- apps last
