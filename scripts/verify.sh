#!/usr/bin/env bash
#############################################
# File: verify.sh
# Purpose: Verify public platform exposure through the shared Gateway.
# Usage:
#   ./scripts/verify.sh
# Notes:
# - Reads Terraform outputs from the cluster and platform workspaces.
# - Requires live Kubernetes resources and reachable public endpoints.
#############################################

# Exit on error, undefined variables, and failed pipes
set -euo pipefail


# Resolve repository paths relative to this script location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_TERRAFORM_DIR="${REPOSITORY_ROOT}/terraform/cluster"
PLATFORM_TERRAFORM_DIR="${REPOSITORY_ROOT}/terraform/platform"
NGROK_NAMESPACE="ngrok-system"
NGROK_OPERATOR_DEPLOYMENT_NAME="ngrok-operator-manager"
NGROK_PUBLIC_INGRESS_NAMESPACE="gateway-system"
NGROK_PUBLIC_INGRESS_NAME="platform-public-ingress"

# Stop early when a required command is not available.
require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
}

#############################################
# get_http_status_code
#
# This function performs an HTTP request and returns the response code only.
#
# Inputs:
# - target_url: full URL to query
#
# Outputs:
# - prints a three-digit HTTP status code
#
# Important edge cases:
# - returns 000 if curl fails before receiving an HTTP response
#############################################
get_http_status_code() {
  local target_url="$1"
  local status_code=""

  if ! status_code="$(curl -sS -o /dev/null -w '%{http_code}' "${target_url}")"; then
    status_code="000"
  fi

  echo "${status_code}"
}

#############################################
# get_http_response_body
#
# This function performs an HTTP request and returns the response body.
#
# Inputs:
# - target_url: full URL to query
#
# Outputs:
# - prints the response body
#
# Important edge cases:
# - returns a non-zero status when curl fails before a response is received
#############################################
get_http_response_body() {
  local target_url="$1"
  local response_body=""

  if ! response_body="$(curl -sS "${target_url}")"; then
    return 1
  fi

  echo "${response_body}"
}

#############################################
# print_ngrok_public_ingress_diagnostics
#
# This function prints ngrok operator health, public Ingress state, namespace
# events, and operator logs to explain failed public verification checks.
#
# Inputs:
# - public_hostname: hostname expected to be reachable via ngrok
# - public_base_url: base URL built from the expected hostname
#
# Outputs:
# - writes human-readable diagnostics to stderr
#
# Important edge cases:
# - all kubectl calls are best-effort so this function can still print a
#   partial snapshot when individual resources are missing
#############################################
print_ngrok_public_ingress_diagnostics() {
  local public_hostname="$1"
  local public_base_url="$2"
  local operator_enabled_features_status=""
  local operator_enabled_features_spec=""
  local ingress_class_name=""
  local ingress_rule_hosts=""
  local ingress_load_balancer_addresses=""

  operator_enabled_features_status="$(
    k -n "${NGROK_NAMESPACE}" get kubernetesoperator ngrok-operator \
      -o jsonpath='{.status.enabledFeatures}' 2>/dev/null || true
  )"
  operator_enabled_features_spec="$(
    k -n "${NGROK_NAMESPACE}" get kubernetesoperator ngrok-operator \
      -o jsonpath='{range .spec.enabledFeatures[*]}{.}{" "}{end}' 2>/dev/null || true
  )"

  ingress_class_name="$(
    k -n "${NGROK_PUBLIC_INGRESS_NAMESPACE}" get ingress "${NGROK_PUBLIC_INGRESS_NAME}" \
      -o jsonpath='{.spec.ingressClassName}' 2>/dev/null || true
  )"
  ingress_rule_hosts="$(
    k -n "${NGROK_PUBLIC_INGRESS_NAMESPACE}" get ingress "${NGROK_PUBLIC_INGRESS_NAME}" \
      -o jsonpath='{range .spec.rules[*]}{.host}{" "}{end}' 2>/dev/null || true
  )"
  ingress_load_balancer_addresses="$(
    k -n "${NGROK_PUBLIC_INGRESS_NAMESPACE}" get ingress "${NGROK_PUBLIC_INGRESS_NAME}" \
      -o jsonpath='{range .status.loadBalancer.ingress[*]}{.hostname}{" "}{.ip}{" "}{end}' 2>/dev/null || true
  )"

  echo "ngrok diagnostics start" >&2
  echo "public hostname under test: ${public_hostname}" >&2
  echo "public base URL under test: ${public_base_url}" >&2
  echo "operator enabled features (status): ${operator_enabled_features_status:-<unknown>}" >&2
  echo "operator enabled features (spec): ${operator_enabled_features_spec:-<unknown>}" >&2
  echo "Ingress class: ${ingress_class_name:-<missing>}" >&2
  echo "Ingress hosts: ${ingress_rule_hosts:-<missing>}" >&2
  echo "Ingress load balancer addresses: ${ingress_load_balancer_addresses:-<empty>}" >&2
  echo "--- ngrok deployment/pod health ---" >&2
  k -n "${NGROK_NAMESPACE}" get deploy,pod 2>&1 || true
  echo "--- public Ingress summary ---" >&2
  k -n "${NGROK_PUBLIC_INGRESS_NAMESPACE}" get ingress "${NGROK_PUBLIC_INGRESS_NAME}" -o wide 2>&1 || true
  echo "--- public Ingress YAML ---" >&2
  k -n "${NGROK_PUBLIC_INGRESS_NAMESPACE}" get ingress "${NGROK_PUBLIC_INGRESS_NAME}" -o yaml 2>&1 || true
  echo "--- ngrok-system events (last 30) ---" >&2
  k -n "${NGROK_NAMESPACE}" get events --sort-by=.lastTimestamp 2>&1 | tail -n 30 || true
  echo "--- gateway-system events (last 30) ---" >&2
  k -n "${NGROK_PUBLIC_INGRESS_NAMESPACE}" get events --sort-by=.lastTimestamp 2>&1 | tail -n 30 || true
  echo "--- ngrok operator logs (tail 120) ---" >&2
  k -n "${NGROK_NAMESPACE}" logs deployment/"${NGROK_OPERATOR_DEPLOYMENT_NAME}" --tail=120 2>&1 || true
  echo "ngrok diagnostics end" >&2
}


# Verify required CLIs before Terraform outputs or API checks run.
require_command terraform
require_command kubectl
require_command curl
require_command tail

# Read Terraform outputs that identify the cluster context and public hostname.
KUBECONFIG_PATH="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kubeconfig_path)"
KUBE_CONTEXT="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kube_context)"
PUBLIC_HOSTNAME="$(terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output -raw gateway_hostname)"
PUBLIC_BASE_URL="https://${PUBLIC_HOSTNAME}"

# Route kubectl through the Terraform-managed kubeconfig and context.
k() {
  kubectl --kubeconfig "${KUBECONFIG_PATH}" --context "${KUBE_CONTEXT}" "$@"
}


# Wait for controller deployments before checking exposed endpoints.
k -n cert-manager rollout status deployment/cert-manager --timeout=300s
k -n gateway-system rollout status deployment/traefik --timeout=300s
k -n argocd rollout status deployment/argocd-server --timeout=300s
k -n "${NGROK_NAMESPACE}" rollout status deployment/"${NGROK_OPERATOR_DEPLOYMENT_NAME}" --timeout=300s
k -n landing rollout status deployment/landing --timeout=300s
k -n whoami rollout status deployment/whoami --timeout=300s

# Wait for certificate and gateway readiness.
k -n gateway-system wait certificate/platform-gateway-tls --for=condition=Ready=True --timeout=300s
k -n gateway-system wait gateway/shared-gateway --for=condition=Programmed=True --timeout=300s

if ! k -n "${NGROK_PUBLIC_INGRESS_NAMESPACE}" get ingress "${NGROK_PUBLIC_INGRESS_NAME}" >/dev/null 2>&1; then
  echo "Public Ingress ${NGROK_PUBLIC_INGRESS_NAMESPACE}/${NGROK_PUBLIC_INGRESS_NAME} was not found." >&2
  print_ngrok_public_ingress_diagnostics "${PUBLIC_HOSTNAME}" "${PUBLIC_BASE_URL}"
  exit 1
fi

# Query the externally exposed routes through the configured public hostname.
LANDING_STATUS_CODE="$(get_http_status_code "${PUBLIC_BASE_URL}/")"
WHOAMI_STATUS_CODE="$(get_http_status_code "${PUBLIC_BASE_URL}/whoami")"
ARGOCD_STATUS_CODE="$(get_http_status_code "${PUBLIC_BASE_URL}/argocd")"
if ! LANDING_RESPONSE_BODY="$(get_http_response_body "${PUBLIC_BASE_URL}/")"; then
  echo "Failed to read landing page response body from ${PUBLIC_BASE_URL}/." >&2
  print_ngrok_public_ingress_diagnostics "${PUBLIC_HOSTNAME}" "${PUBLIC_BASE_URL}"
  exit 1
fi

# Print the configured endpoint and observed HTTP status codes.
echo "Public hostname: ${PUBLIC_HOSTNAME}"
echo "Public URL: ${PUBLIC_BASE_URL}"
echo "landing status: ${LANDING_STATUS_CODE}"
echo "whoami status: ${WHOAMI_STATUS_CODE}"
echo "argocd status: ${ARGOCD_STATUS_CODE}"

# Require a successful application response from the landing route.
if [[ ! "${LANDING_STATUS_CODE}" =~ ^2 ]]; then
  echo "Expected landing endpoint to return HTTP 2xx." >&2
  print_ngrok_public_ingress_diagnostics "${PUBLIC_HOSTNAME}" "${PUBLIC_BASE_URL}"
  exit 1
fi

# Require landing page links to the main routed entrypoints.
if ! grep -Fq "/argocd" <<<"${LANDING_RESPONSE_BODY}"; then
  echo "Expected landing page response body to contain /argocd link." >&2
  print_ngrok_public_ingress_diagnostics "${PUBLIC_HOSTNAME}" "${PUBLIC_BASE_URL}"
  exit 1
fi

if ! grep -Fq "/whoami" <<<"${LANDING_RESPONSE_BODY}"; then
  echo "Expected landing page response body to contain /whoami link." >&2
  print_ngrok_public_ingress_diagnostics "${PUBLIC_HOSTNAME}" "${PUBLIC_BASE_URL}"
  exit 1
fi

# Require a successful application response from the whoami route.
if [[ ! "${WHOAMI_STATUS_CODE}" =~ ^2 ]]; then
  echo "Expected whoami endpoint to return HTTP 2xx." >&2
  print_ngrok_public_ingress_diagnostics "${PUBLIC_HOSTNAME}" "${PUBLIC_BASE_URL}"
  exit 1
fi

# Allow redirects for ArgoCD because its route may canonicalize the path.
if [[ ! "${ARGOCD_STATUS_CODE}" =~ ^(2|3) ]]; then
  echo "Expected ArgoCD endpoint to return HTTP 2xx or 3xx." >&2
  print_ngrok_public_ingress_diagnostics "${PUBLIC_HOSTNAME}" "${PUBLIC_BASE_URL}"
  exit 1
fi

echo "Gateway API and ngrok Ingress exposure verification finished."
