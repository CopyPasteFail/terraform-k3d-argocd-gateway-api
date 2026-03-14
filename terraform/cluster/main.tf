#############################################
# File: main.tf
# Purpose: Provisions the local k3d cluster for the cluster stage.
# Notes:
# - This stage is executed before platform stage and produces kubeconfig for it.
#############################################

# ------------------------------------------
# Local settings
# ------------------------------------------
locals {
  kube_context = "k3d-${var.cluster_name}"
}

# ------------------------------------------
# Cluster orchestration
# ------------------------------------------

# Create the local k3d cluster through CLI because no native Terraform resource exists.
# Triggers force reprovisioning when cluster shape or kubeconfig destination changes.
resource "null_resource" "k3d_cluster" {
  triggers = {
    cluster_name            = var.cluster_name
    server_count            = tostring(var.server_count)
    agent_count             = tostring(var.agent_count)
    ingress_http_host_port  = tostring(var.ingress_http_host_port)
    ingress_https_host_port = tostring(var.ingress_https_host_port)
    kubeconfig_path         = var.kubeconfig_path
  }

  # Run the cluster bootstrap locally so Terraform can hand off a ready kubeconfig to the next stage.
  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]

    command = <<-EOT
      set -euo pipefail

      # Optional guardrails for direct Terraform usage.
      if [[ "${var.is_tool_validation_enabled}" == "true" ]]; then
        if ! command -v k3d >/dev/null 2>&1; then
          echo "k3d is required but not installed. Install k3d and retry."
          exit 1
        fi

        if ! command -v kubectl >/dev/null 2>&1; then
          echo "kubectl is required but not installed. Install kubectl and retry."
          exit 1
        fi
      fi

      # Reuse existing cluster when present to keep apply idempotent.
      if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx '${var.cluster_name}'; then
        echo "k3d cluster '${var.cluster_name}' already exists; reusing it."
      else
        # Disable bundled ingress/service LB because platform stage installs Traefik explicitly.
        k3d cluster create '${var.cluster_name}' \
          --servers '${var.server_count}' \
          --agents '${var.agent_count}' \
          --k3s-arg '--disable=traefik@server:*' \
          --k3s-arg '--disable=servicelb@server:*' \
          --port '${var.ingress_http_host_port}:80@loadbalancer' \
          --port '${var.ingress_https_host_port}:443@loadbalancer' \
          --wait
      fi

      # Export kubeconfig for the next Terraform stage and lock down file permissions.
      mkdir -p "$(dirname '${var.kubeconfig_path}')"
      k3d kubeconfig write '${var.cluster_name}' --output '${var.kubeconfig_path}' --overwrite
      chmod 600 '${var.kubeconfig_path}'

      # Make sure kubectl uses the context that matches this cluster name.
      kubectl --kubeconfig='${var.kubeconfig_path}' config use-context '${local.kube_context}' >/dev/null
    EOT
  }

  # Remove the local cluster and generated kubeconfig during destroy to avoid stale state handoff.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/usr/bin/env", "bash", "-c"]

    command = <<-EOT
      set -euo pipefail

      # Best-effort cluster delete so destroy can proceed even if cluster is already gone.
      if command -v k3d >/dev/null 2>&1; then
        k3d cluster delete '${self.triggers.cluster_name}' || true
      fi

      # Remove generated kubeconfig to avoid stale context usage.
      rm -f '${self.triggers.kubeconfig_path}'
    EOT
  }
}
