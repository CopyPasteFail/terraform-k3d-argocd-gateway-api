#############################################
# File: main.tf
# Purpose:
#   Provisions the shared platform layer that runs on top of the Kubernetes
#   cluster created by the separate cluster stage. This module connects to the
#   target cluster by using the kubeconfig path and context passed in as
#   variables, then installs the core services that make the local platform
#   usable: cert-manager for certificate resources, Traefik as the Gateway API
#   controller, Argo CD for GitOps application delivery, and the ngrok operator
#   for public exposure into the local cluster.
#
# What this file manages:
# - Bootstraps the namespaces used by the platform and applies consistent labels.
# - Installs Helm charts for the shared control-plane components.
# - Renders templated Kubernetes manifests inside Terraform so the selected
#   controller, hostnames, and Git repository inputs are all resolved from one
#   place and tracked in one Terraform state.
# - Creates Gateway API resources, TLS resources, cross-namespace
#   ReferenceGrants, Argo CD Application objects, and the ngrok-facing Ingress
#   that exposes the shared gateway publicly.
#
# Why the ordering is explicit:
#   Several resources in this stack depend on CRDs or controllers that are
#   introduced by earlier Helm releases. The file therefore uses explicit
#   `depends_on` edges and short `time_sleep` buffers so Terraform waits for CRD
#   discovery and controller readiness before applying dependent manifests. That
#   keeps fresh-cluster applies more reliable and makes the platform bootstrap
#   sequence easier to reason about.
#
# Why namespaces are created separately from Helm:
#   Namespace lifecycle is shared by Helm releases and standalone manifests in
#   this module. Namespaces are therefore modeled as first-class Terraform
#   resources so labels, dependencies, and future namespace metadata stay
#   centralized in one place instead of being split across individual Helm
#   releases.
#############################################

# ------------------------------------------
# Provider configuration
# ------------------------------------------
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

# ------------------------------------------
# Manifest preparation
# ------------------------------------------

# Render manifests in Terraform so controller selection stays centralized in one state.
locals {
  namespace_labels = {
    argocd = {
      "app.kubernetes.io/part-of" = "local-platform"
    }

    "cert-manager" = {
      "app.kubernetes.io/part-of" = "local-platform"
    }

    "gateway-system" = {
      "app.kubernetes.io/part-of" = "local-platform"
    }

    landing = {
      "app.kubernetes.io/part-of" = "local-platform"
    }

    "routes-system" = {
      "app.kubernetes.io/part-of" = "local-platform"
      "gateway-access"            = "shared-gateway"
    }

    whoami = {
      "app.kubernetes.io/part-of" = "local-platform"
    }

    "ngrok-system" = {
      "app.kubernetes.io/part-of" = "local-platform"
    }
  }

  gateway_controller_catalog = {
    traefik = {
      gateway_class_name            = "traefik"
      gateway_class_controller_name = "traefik.io/gateway-controller"
      gateway_class_manifest_path   = "${path.module}/../../manifests/gateway/controllers/traefik/gatewayclass.yaml.tpl"
      helm_values_path              = "${path.module}/values/traefik-values.yaml.tpl"
    }
  }

  selected_gateway_controller = local.gateway_controller_catalog[var.gateway_api_controller]

  gateway_class_manifest = yamldecode(templatefile(local.selected_gateway_controller.gateway_class_manifest_path, {
    gateway_class_name            = local.selected_gateway_controller.gateway_class_name
    gateway_class_controller_name = local.selected_gateway_controller.gateway_class_controller_name
  }))

  gateway_manifest = yamldecode(templatefile("${path.module}/../../manifests/gateway/core/gateway.yaml.tpl", {
    gateway_class_name = local.selected_gateway_controller.gateway_class_name
    public_hostname    = var.public_hostname
  }))

  argocd_http_route_manifest = yamldecode(templatefile("${path.module}/../../manifests/gateway/routes/argocd-httproute.yaml.tpl", {
    public_hostname = var.public_hostname
  }))

  whoami_http_route_manifest = yamldecode(templatefile("${path.module}/../../manifests/gateway/routes/whoami-httproute.yaml.tpl", {
    public_hostname = var.public_hostname
  }))

  landing_root_http_route_manifest = yamldecode(templatefile("${path.module}/../../manifests/gateway/routes/landing-root-httproute.yaml.tpl", {
    public_hostname = var.public_hostname
  }))

  gateway_issuer_manifest = yamldecode(templatefile("${path.module}/../../manifests/cert-manager/gateway-selfsigned-issuer.yaml.tpl", {
    issuer_name = "platform-selfsigned"
  }))

  gateway_certificate_manifest = yamldecode(templatefile("${path.module}/../../manifests/cert-manager/gateway-certificate.yaml.tpl", {
    certificate_name = "platform-gateway-tls"
    issuer_name      = "platform-selfsigned"
    public_hostname  = var.public_hostname
  }))

  ngrok_public_ingress_manifest = yamldecode(templatefile("${path.module}/../../manifests/ngrok/traefik-public-ingress.yaml.tpl", {
    public_hostname = var.public_hostname
  }))

  whoami_application_manifest = yamldecode(templatefile("${path.module}/../../manifests/argocd/whoami-application.yaml.tpl", {
    git_repository_url  = var.git_repository_url
    git_target_revision = var.git_target_revision
  }))

  landing_application_manifest = yamldecode(templatefile("${path.module}/../../manifests/argocd/landing-application.yaml.tpl", {
    git_repository_url  = var.git_repository_url
    git_target_revision = var.git_target_revision
  }))

  argocd_reference_grant_manifest  = yamldecode(file("${path.module}/../../manifests/referencegrants/argocd-service-referencegrant.yaml"))
  landing_reference_grant_manifest = yamldecode(file("${path.module}/../../manifests/referencegrants/landing-service-referencegrant.yaml"))
  whoami_reference_grant_manifest  = yamldecode(file("${path.module}/../../manifests/referencegrants/whoami-service-referencegrant.yaml"))
}

# ------------------------------------------
# Namespace bootstrap
# ------------------------------------------

# Pre-create namespaces so charts and manifests share consistent labels and ownership.
resource "kubernetes_namespace_v1" "platform" {
  for_each = local.namespace_labels

  metadata {
    name   = each.key
    labels = each.value
  }
}

# ------------------------------------------
# Helm releases
# ------------------------------------------

# Install cert-manager first because later gateway TLS resources depend on its CRDs.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = kubernetes_namespace_v1.platform["cert-manager"].metadata[0].name
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    }
  ]
}

# Wait explicitly because CRD registration can lag Helm completion in a fresh cluster.
resource "time_sleep" "wait_for_cert_manager_crds" {
  depends_on      = [helm_release.cert_manager]
  create_duration = "20s"
}

# Install the selected Gateway API controller before applying Gateway resources.
resource "helm_release" "traefik" {
  name             = "traefik"
  namespace        = kubernetes_namespace_v1.platform["gateway-system"].metadata[0].name
  repository       = "https://helm.traefik.io/traefik"
  chart            = "traefik"
  version          = var.traefik_chart_version
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  values = [
    templatefile(local.selected_gateway_controller.helm_values_path, {})
  ]
}

# Delay manifest application until Gateway API CRDs are discoverable by the provider.
resource "time_sleep" "wait_for_gateway_api_crds" {
  depends_on      = [helm_release.traefik]
  create_duration = "20s"
}

# Install Argo CD before creating its Application and routed entrypoint.
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = kubernetes_namespace_v1.platform["argocd"].metadata[0].name
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  values = [
    templatefile("${path.module}/values/argocd-values.yaml.tpl", {})
  ]
}

# Wait for Argo CD CRDs so the Application manifest can be created reliably.
resource "time_sleep" "wait_for_argocd_crds" {
  depends_on      = [helm_release.argocd]
  create_duration = "20s"
}

# Install the ngrok operator before creating the public Ingress resource.
# The default exposure path uses Kubernetes Ingress with the ngrok class.
resource "helm_release" "ngrok_operator" {
  name             = "ngrok-operator"
  namespace        = kubernetes_namespace_v1.platform["ngrok-system"].metadata[0].name
  repository       = "https://charts.ngrok.com"
  chart            = "ngrok-operator"
  version          = var.ngrok_operator_chart_version
  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  values = [
    templatefile("${path.module}/values/ngrok-operator-values.yaml.tpl", {
      ngrok_api_key   = var.ngrok_api_key
      ngrok_authtoken = var.ngrok_authtoken
    })
  ]
}

# Keep a short wait so the ngrok operator and CRDs settle before public ingress apply.
resource "time_sleep" "wait_for_ngrok_crds" {
  depends_on      = [helm_release.ngrok_operator]
  create_duration = "20s"
}

# ------------------------------------------
# Gateway and certificate manifests
# ------------------------------------------

# Create the issuer after cert-manager CRDs exist and the target namespace is ready.
resource "kubernetes_manifest" "gateway_issuer" {
  manifest = local.gateway_issuer_manifest

  depends_on = [
    time_sleep.wait_for_cert_manager_crds,
    kubernetes_namespace_v1.platform["gateway-system"],
  ]
}

# Request gateway TLS only after the issuer is available to sign it.
resource "kubernetes_manifest" "gateway_certificate" {
  manifest = local.gateway_certificate_manifest

  depends_on = [
    kubernetes_manifest.gateway_issuer,
  ]
}

# Register the GatewayClass only after the controller has installed its CRDs.
resource "kubernetes_manifest" "gateway_class" {
  manifest = local.gateway_class_manifest

  depends_on = [
    time_sleep.wait_for_gateway_api_crds,
  ]
}

# Create the shared Gateway after class, certificate, and namespaces are in place.
resource "kubernetes_manifest" "gateway" {
  manifest = local.gateway_manifest

  depends_on = [
    kubernetes_manifest.gateway_class,
    kubernetes_manifest.gateway_certificate,
    kubernetes_namespace_v1.platform["gateway-system"],
    kubernetes_namespace_v1.platform["routes-system"],
  ]
}

# ------------------------------------------
# Cross-namespace access grants
# ------------------------------------------

# Allow routed traffic from the shared gateway namespace to reach the Argo CD service.
resource "kubernetes_manifest" "argocd_reference_grant" {
  manifest = local.argocd_reference_grant_manifest

  depends_on = [
    time_sleep.wait_for_gateway_api_crds,
    helm_release.argocd,
    kubernetes_namespace_v1.platform["argocd"],
    kubernetes_namespace_v1.platform["routes-system"],
  ]
}

# Allow routed traffic from the shared gateway namespace to reach the whoami service.
resource "kubernetes_manifest" "whoami_reference_grant" {
  manifest = local.whoami_reference_grant_manifest

  depends_on = [
    time_sleep.wait_for_gateway_api_crds,
    kubernetes_namespace_v1.platform["whoami"],
    kubernetes_namespace_v1.platform["routes-system"],
  ]
}

# Allow routed traffic from the shared gateway namespace to reach the landing service.
resource "kubernetes_manifest" "landing_reference_grant" {
  manifest = local.landing_reference_grant_manifest

  depends_on = [
    time_sleep.wait_for_gateway_api_crds,
    kubernetes_namespace_v1.platform["landing"],
    kubernetes_namespace_v1.platform["routes-system"],
  ]
}

# ------------------------------------------
# Route and application manifests
# ------------------------------------------

# Gateway is required before a route can attach to it.
# ReferenceGrant is required before a route can send traffic to a Service in
# another namespace.
# Without these dependencies, Terraform might still eventually converge, but
# first-time applies can be more flaky and routes may stay unresolved until a
# later reconciliation pass.

# Expose Argo CD only after the gateway and backend access grant both exist.
resource "kubernetes_manifest" "argocd_http_route" {
  manifest = local.argocd_http_route_manifest

  depends_on = [
    kubernetes_manifest.gateway,
    kubernetes_manifest.argocd_reference_grant,
    helm_release.argocd,
  ]
}

# Expose whoami only after the gateway and service reference grant are ready.
resource "kubernetes_manifest" "whoami_http_route" {
  manifest = local.whoami_http_route_manifest

  depends_on = [
    kubernetes_manifest.gateway,
    kubernetes_manifest.whoami_reference_grant,
  ]
}

# Expose the root path after gateway and service reference grant are ready.
resource "kubernetes_manifest" "landing_root_http_route" {
  manifest = local.landing_root_http_route_manifest

  depends_on = [
    kubernetes_manifest.gateway,
    kubernetes_manifest.landing_reference_grant,
  ]
}

# Create the Argo CD Application after its CRD is available in the cluster.
resource "kubernetes_manifest" "whoami_application" {
  manifest = local.whoami_application_manifest

  depends_on = [
    time_sleep.wait_for_argocd_crds,
    kubernetes_namespace_v1.platform["whoami"],
  ]
}

# Create the landing Argo CD Application after its CRD is available in the cluster.
resource "kubernetes_manifest" "landing_application" {
  manifest = local.landing_application_manifest

  depends_on = [
    time_sleep.wait_for_argocd_crds,
    kubernetes_namespace_v1.platform["landing"],
  ]
}

# Publish the Gateway through ngrok Ingress after both the operator and Gateway are ready.
resource "kubernetes_manifest" "ngrok_public_ingress" {
  manifest = local.ngrok_public_ingress_manifest

  depends_on = [
    time_sleep.wait_for_ngrok_crds,
    kubernetes_manifest.gateway,
    helm_release.traefik,
  ]
}
