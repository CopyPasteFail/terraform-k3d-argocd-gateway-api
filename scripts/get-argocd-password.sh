#!/usr/bin/env bash
#############################################
# File: get-argocd-password.sh
# Purpose: Print the initial ArgoCD admin password from the cluster secret.
# Usage:
#   ./scripts/get-argocd-password.sh
# Notes:
# - Reads Terraform outputs to locate the cluster kubeconfig and context.
# - Requires the ArgoCD initial admin secret to exist in the cluster.
#############################################

# Exit on error, undefined variables, and failed pipes
set -euo pipefail

# ------------------------------------------
# Resolve paths
# ------------------------------------------

# Resolve repository paths relative to this script location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_TERRAFORM_DIR="${REPOSITORY_ROOT}/terraform/cluster"

# ------------------------------------------
# Validation helpers
# ------------------------------------------

# Stop early when a required command is not available.
require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
}

# ------------------------------------------
# Validate dependencies
# ------------------------------------------

# Verify required CLIs before reading Terraform outputs or secrets.
require_command terraform
require_command kubectl
require_command base64

# Read the cluster connection outputs used for the secret lookup.
KUBECONFIG_PATH="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kubeconfig_path)"
KUBE_CONTEXT="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kube_context)"

# Read and decode the initial ArgoCD admin password from the cluster secret.
kubectl \
  --kubeconfig "${KUBECONFIG_PATH}" \
  --context "${KUBE_CONTEXT}" \
  -n argocd \
  get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode

echo
