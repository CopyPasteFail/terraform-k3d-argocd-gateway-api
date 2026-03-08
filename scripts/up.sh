#!/usr/bin/env bash
#############################################
# File: up.sh
# Purpose: Provision the local cluster stage, the platform stage, or both.
# Usage:
#   ./scripts/up.sh
# Notes:
# - Supports cluster-only, platform-only, or full provisioning runs.
# - Loads optional defaults from `.env` before validation.
#############################################

# Exit on error, undefined variables, and failed pipes
set -euo pipefail


# Resolve repository paths relative to this script location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_TERRAFORM_DIR="${REPOSITORY_ROOT}/terraform/cluster"
PLATFORM_TERRAFORM_DIR="${REPOSITORY_ROOT}/terraform/platform"
VALIDATE_GIT_SOURCE_ONLY="false"
SELECTED_TERRAFORM_STAGE="both"
HAS_EXPLICIT_STAGE_SELECTION="false"


# Stop early when a required command is not available.
require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
}

# Stop early when a required environment variable is missing.
require_env() {
  local variable_name="$1"

  if [[ -z "${!variable_name:-}" ]]; then
    echo "Missing required environment variable: ${variable_name}" >&2
    exit 1
  fi
}

# Load optional bootstrap variables without overriding exported values.
load_optional_dotenv() {
  local dotenv_path="${REPOSITORY_ROOT}/.env"

  if [[ ! -f "${dotenv_path}" ]]; then
    return
  fi

  while IFS= read -r dotenv_line || [[ -n "${dotenv_line}" ]]; do
    if [[ -z "${dotenv_line}" || "${dotenv_line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ ! "${dotenv_line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "Skipping invalid .env line: ${dotenv_line}" >&2
      continue
    fi

    local dotenv_key="${BASH_REMATCH[1]}"
    local dotenv_value="${BASH_REMATCH[2]}"

    if [[ -n "${!dotenv_key+x}" ]]; then
      continue
    fi

    dotenv_value="${dotenv_value#"${dotenv_value%%[![:space:]]*}"}"
    dotenv_value="${dotenv_value%"${dotenv_value##*[![:space:]]}"}"
    dotenv_value="${dotenv_value%$'\r'}"

    if [[ "${dotenv_value}" =~ ^\"(.*)\"$ ]]; then
      dotenv_value="${BASH_REMATCH[1]}"
    elif [[ "${dotenv_value}" =~ ^\'(.*)\'$ ]]; then
      dotenv_value="${BASH_REMATCH[1]}"
    fi

    export "${dotenv_key}=${dotenv_value}"
  done <"${dotenv_path}"
}

print_usage() {
  # Print supported invocation options.
  cat <<'EOF'
Usage: ./scripts/up.sh [OPTIONS]

Options:
  --print-derived-git-source  Resolve and print ArgoCD Git source values, then exit.
  --stage <cluster|platform|both>
                              Run only the selected Terraform stage (default: both).
  -h, --help                  Show this help message.
EOF
}

set_selected_terraform_stage() {
  # Accept only one explicit stage selection for this run.
  local requested_stage="$1"

  case "${requested_stage}" in
    cluster | platform | both)
      ;;
    *)
      echo "Unsupported stage '${requested_stage}'." >&2
      echo "Expected one of: cluster, platform, both." >&2
      exit 1
      ;;
  esac

  if [[ "${HAS_EXPLICIT_STAGE_SELECTION}" == "true" && "${SELECTED_TERRAFORM_STAGE}" != "${requested_stage}" ]]; then
    echo "Conflicting stage options provided." >&2
    echo "Choose one stage selection: --stage <cluster|platform|both>." >&2
    exit 1
  fi

  SELECTED_TERRAFORM_STAGE="${requested_stage}"
  HAS_EXPLICIT_STAGE_SELECTION="true"
}

# Parse execution mode before any provisioning work starts.
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --print-derived-git-source)
      VALIDATE_GIT_SOURCE_ONLY="true"
      shift
      ;;
    --stage)
      if [[ "$#" -lt 2 ]]; then
        echo "Missing value for --stage." >&2
        print_usage >&2
        exit 1
      fi

      set_selected_terraform_stage "$2"
      shift 2
      ;;
    -h | --help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

# Load optional defaults before dependency and input validation.
load_optional_dotenv

# Normalize supported GitHub origins to HTTPS clone URLs.
normalize_to_github_https_clone_url() {
  local repository_url="$1"

  if [[ "${repository_url}" =~ ^git@github\.com:([^/]+)/([^/]+)\.git$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
    return 0
  fi

  if [[ "${repository_url}" =~ ^https://github\.com/([^/]+)/([^/]+)\.git$ ]]; then
    echo "${repository_url}"
    return 0
  fi

  return 1
}

# Reject repository URLs that ArgoCD cannot consume from this workflow.
validate_github_https_clone_url() {
  local repository_url="$1"

  if [[ ! "${repository_url}" =~ \.git$ ]]; then
    echo "Invalid repository URL '${repository_url}': expected a GitHub HTTPS clone URL ending with .git." >&2
    echo "Set GIT_REPOSITORY_URL explicitly, for example: https://github.com/OWNER/REPO.git" >&2
    exit 1
  fi

  if [[ ! "${repository_url}" =~ ^https://github\.com/[^/]+/[^/]+\.git$ ]]; then
    echo "Unsupported repository URL '${repository_url}'." >&2
    echo "Supported formats: git@github.com:OWNER/REPO.git or https://github.com/OWNER/REPO.git" >&2
    echo "Set GIT_REPOSITORY_URL explicitly to a GitHub HTTPS clone URL ending with .git." >&2
    exit 1
  fi
}

# Resolve Git source inputs before the platform stage uses them.
resolve_git_source_variables() {
  # Prefer an explicit repository override so automation can control the source.
  RESOLVED_GIT_REPOSITORY_URL="${GIT_REPOSITORY_URL:-}"

  # Fall back to the local Git origin when no repository override is provided.
  if [[ -z "${RESOLVED_GIT_REPOSITORY_URL}" ]]; then
    # Read the origin URL from the repository because platform Terraform requires a Git source.
    if ! ORIGIN_REPOSITORY_URL="$(git -C "${REPOSITORY_ROOT}" remote get-url origin 2>/dev/null)"; then
      echo "Unable to detect Git origin URL." >&2
      echo "Set GIT_REPOSITORY_URL explicitly, for example: https://github.com/OWNER/REPO.git" >&2
      exit 1
    fi

    # Reject an empty origin value because it cannot be normalized or validated.
    if [[ -z "${ORIGIN_REPOSITORY_URL}" ]]; then
      echo "Git origin URL is empty." >&2
      echo "Set GIT_REPOSITORY_URL explicitly, for example: https://github.com/OWNER/REPO.git" >&2
      exit 1
    fi

    # Normalize supported origin formats so downstream consumers receive a consistent HTTPS URL.
    if ! RESOLVED_GIT_REPOSITORY_URL="$(normalize_to_github_https_clone_url "${ORIGIN_REPOSITORY_URL}")"; then
      echo "Unsupported Git origin URL '${ORIGIN_REPOSITORY_URL}'." >&2
      echo "Supported origin formats: git@github.com:OWNER/REPO.git or https://github.com/OWNER/REPO.git" >&2
      echo "Set GIT_REPOSITORY_URL explicitly to a GitHub HTTPS clone URL ending with .git." >&2
      exit 1
    fi
  fi

  # Validate the final repository URL and default the target revision when none is supplied.
  validate_github_https_clone_url "${RESOLVED_GIT_REPOSITORY_URL}"
  RESOLVED_GIT_TARGET_REVISION="${GIT_TARGET_REVISION:-main}"
}

# Resolve Git settings before validation-only and platform runs.
if [[ "${VALIDATE_GIT_SOURCE_ONLY}" == "true" || "${SELECTED_TERRAFORM_STAGE}" != "cluster" ]]; then
  require_command git
  resolve_git_source_variables

  # Print the resolved source when validation or platform apply is requested.
  echo "Using ArgoCD source repository: ${RESOLVED_GIT_REPOSITORY_URL}"
  echo "Using ArgoCD target revision: ${RESOLVED_GIT_TARGET_REVISION}"
fi

# Exit after validation when no Terraform work should run.
if [[ "${VALIDATE_GIT_SOURCE_ONLY}" == "true" ]]; then
  exit 0
fi


# Validate commands required by the remaining provisioning steps.
require_command terraform
require_command bash
require_command kubectl


# Create or update the local cluster before platform resources depend on it.
if [[ "${SELECTED_TERRAFORM_STAGE}" == "cluster" || "${SELECTED_TERRAFORM_STAGE}" == "both" ]]; then
  # Validate the cluster runtime dependency before the cluster stage runs.
  require_command k3d

  tf_cluster_apply_args=(
    -auto-approve
    -var "is_tool_validation_enabled=false"
  )

  # Initialize the cluster workspace before apply uses its providers.
  terraform -chdir="${CLUSTER_TERRAFORM_DIR}" init -upgrade
  # Apply the cluster stage before platform outputs are requested.
  terraform -chdir="${CLUSTER_TERRAFORM_DIR}" apply "${tf_cluster_apply_args[@]}"
fi

# Apply the platform only after cluster outputs are available.
if [[ "${SELECTED_TERRAFORM_STAGE}" == "platform" || "${SELECTED_TERRAFORM_STAGE}" == "both" ]]; then
  # Validate platform credentials before passing them into Terraform.
  require_env NGROK_API_KEY
  require_env NGROK_AUTHTOKEN
  require_env NGROK_STATIC_DOMAIN

  # Read cluster connection details required by the platform stage.
  KUBECONFIG_PATH="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kubeconfig_path)"
  KUBE_CONTEXT="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kube_context)"

  tf_platform_apply_args=(
    -auto-approve
    -var "kubeconfig_path=${KUBECONFIG_PATH}"
    -var "kube_context=${KUBE_CONTEXT}"
    -var "public_hostname=${NGROK_STATIC_DOMAIN}"
    -var "ngrok_api_key=${NGROK_API_KEY}"
    -var "ngrok_authtoken=${NGROK_AUTHTOKEN}"
    -var "git_repository_url=${RESOLVED_GIT_REPOSITORY_URL}"
    -var "git_target_revision=${RESOLVED_GIT_TARGET_REVISION}"
  )

  # Bootstrap CRD-producing dependencies before manifest resources are applied.
  # This targeted apply must run first because later resources depend on CRD discovery.
  # Run a partial apply that targets only the CRD bootstrap waits and their
  # dependencies.
  # Terraform does not follow this list top-to-bottom; it still
  # uses the dependency graph and may run independent targets in parallel.
  tf_platform_crd_bootstrap_target_args=(
    -target=time_sleep.wait_for_cert_manager_crds
    -target=time_sleep.wait_for_gateway_api_crds
    -target=time_sleep.wait_for_argocd_crds
    -target=time_sleep.wait_for_ngrok_crds
  )

  # Initialize the platform workspace before targeted and full applies.
  terraform -chdir="${PLATFORM_TERRAFORM_DIR}" init -upgrade
  # Apply CRD bootstrap targets before the full platform apply.
  terraform -chdir="${PLATFORM_TERRAFORM_DIR}" apply "${tf_platform_apply_args[@]}" "${tf_platform_crd_bootstrap_target_args[@]}"
  # Apply the full platform after prerequisite CRDs are ready.
  terraform -chdir="${PLATFORM_TERRAFORM_DIR}" apply "${tf_platform_apply_args[@]}"

  echo
  # Print final platform outputs for follow-up scripts and manual checks.
  terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output

  echo
fi

# Report which stage completed for the selected execution mode.
if [[ "${SELECTED_TERRAFORM_STAGE}" == "both" ]]; then
  echo "Cluster and platform provisioning complete."
elif [[ "${SELECTED_TERRAFORM_STAGE}" == "cluster" ]]; then
  echo "Cluster provisioning complete."
else
  echo "Platform provisioning complete."
fi
