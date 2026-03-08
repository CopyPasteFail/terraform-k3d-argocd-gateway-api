#!/usr/bin/env bash
#############################################
# File: destroy.sh
# Purpose: Destroy the platform and cluster Terraform stages.
# Usage:
#   ./scripts/destroy.sh
# Notes:
# - Destroys the platform before destroying the cluster.
# - Uses fallback values when state outputs or environment variables are absent.
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
PLATFORM_TERRAFORM_DIR="${REPOSITORY_ROOT}/terraform/platform"

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

# Verify Terraform is available before reading state or destroying resources.
require_command terraform

KUBECONFIG_PATH=""
KUBE_CONTEXT=""

# Read cluster connection outputs only when cluster state already exists.
if [[ -f "${CLUSTER_TERRAFORM_DIR}/terraform.tfstate" ]]; then
  KUBECONFIG_PATH="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kubeconfig_path 2>/dev/null || true)"
  KUBE_CONTEXT="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kube_context 2>/dev/null || true)"
fi

# Build platform destroy inputs with state-derived values or safe fallbacks.
PLATFORM_DESTROY_ARGS=(
  -auto-approve
  -var "kubeconfig_path=${KUBECONFIG_PATH:-../../.kube/k3d-platform-local.yaml}"
  -var "kube_context=${KUBE_CONTEXT:-k3d-platform-local}"
  -var "public_hostname=${NGROK_STATIC_DOMAIN:-replace-with-your-static-domain.ngrok.app}"
  -var "ngrok_api_key=${NGROK_API_KEY:-not-set}"
  -var "ngrok_authtoken=${NGROK_AUTHTOKEN:-not-set}"
  -var "git_repository_url=${GIT_REPOSITORY_URL:-https://example.invalid/repository-required-for-destroy.git}"
  -var "git_target_revision=${GIT_TARGET_REVISION:-main}"
)

# Initialize the platform workspace before destroy uses its providers.
terraform -chdir="${PLATFORM_TERRAFORM_DIR}" init -upgrade
# Destroy platform resources first because they depend on the cluster.
terraform -chdir="${PLATFORM_TERRAFORM_DIR}" destroy "${PLATFORM_DESTROY_ARGS[@]}"

# Reinitialize the cluster workspace before cluster teardown.
terraform -chdir="${CLUSTER_TERRAFORM_DIR}" init -upgrade
# Destroy the cluster only after platform resources are removed.
terraform -chdir="${CLUSTER_TERRAFORM_DIR}" destroy -auto-approve

echo "Platform and cluster teardown complete."
