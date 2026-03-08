#!/usr/bin/env bash
#############################################
# File: verify-local.sh
# Purpose: Verify Gateway routes through a local controller port-forward.
# Usage:
#   ./scripts/verify-local.sh
# Notes:
# - Uses Terraform outputs and live Gateway API objects.
# - Works when public exposure is unavailable but the cluster is reachable.
#############################################

# Exit on error, undefined variables, and failed pipes
set -euo pipefail


# Resolve repository paths relative to this script location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_TERRAFORM_DIR="${REPOSITORY_ROOT}/terraform/cluster"
PLATFORM_TERRAFORM_DIR="${REPOSITORY_ROOT}/terraform/platform"
LOCAL_FORWARD_PORT="9443"
PORT_FORWARD_LOG_PATH="/tmp/verify-local-port-forward.log"


# Stop early when a required command is not available.
require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
}

# Stop the background port-forward when the script exits.
cleanup_port_forward() {
  if [[ -n "${PORT_FORWARD_PROCESS_ID:-}" ]]; then
    kill "${PORT_FORWARD_PROCESS_ID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PROCESS_ID}" >/dev/null 2>&1 || true
  fi
}

# Route kubectl through the Terraform-managed kubeconfig and context.
k() {
  kubectl --kubeconfig "${KUBECONFIG_PATH}" --context "${KUBE_CONTEXT}" "$@"
}

# Read the live Gateway hostname and fall back to Terraform output.
get_gateway_hostname() {
  local live_gateway_hostname=""

  live_gateway_hostname="$(
    k -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
      -o jsonpath='{.spec.listeners[0].hostname}'
  )"

  if [[ -n "${live_gateway_hostname}" ]]; then
    echo "${live_gateway_hostname}"
    return 0
  fi

  terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output -raw gateway_hostname
}

#############################################
# discover_gateway_routes
#
# This function asks Kubernetes for every HTTPRoute in every
# namespace, extracts the small set of fields that matter for routing, and then
# filters that raw list down to only the routes that belong to the Gateway and
# hostname currently under test.
#
# The function reads:
# - the route identity: namespace and name
# - the first parentRef: which Gateway the route is attached to
# - the first hostname: which Host header the route expects, if any
# - the first path match: which URL path should be requested
# - the first backendRef: which Service the Gateway should forward to
#
# The function keeps only routes that satisfy this routing model:
# - the route is attached to GATEWAY_NAMESPACE/GATEWAY_NAME
# - the route hostname is either empty (meaning it is not hostname-restricted)
#   or matches PUBLIC_HOSTNAME exactly
#
# For backend resolution, Gateway API allows backendRef.namespace to be omitted.
# When that happens, this function applies the API defaulting rule by treating
# the backend namespace as the route's own namespace. That gives later
# verification logic a fully qualified backend target to print and reason about.
#
# Outputs:
# - DISCOVERED_ROUTE_NAMES
# - DISCOVERED_ROUTE_NAMESPACES
# - DISCOVERED_ROUTE_PATHS
# - DISCOVERED_ROUTE_BACKEND_NAMESPACES
# - DISCOVERED_ROUTE_BACKEND_NAMES
#
# These parallel arrays form a compact route inventory that later code iterates
# over to send one request per discovered path through the local port-forward.
# The arrays are rebuilt from scratch on every call, so the verification run is
# based on live cluster state rather than stale Terraform assumptions.
#
# Important limitations:
# - this implementation intentionally reads only the first parentRef, first
#   hostname, first rule match path, and first backendRef from each HTTPRoute
# - routes with more complex fan-out or multiple matches are simplified to that
#   first-entry view because this script is designed as a lightweight
#   verification probe, not a full Gateway API evaluator
#############################################
discover_gateway_routes() {
  local route_namespace=""
  local route_name=""
  local parent_namespace=""
  local parent_name=""
  local route_hostname=""
  local route_path=""
  local backend_namespace=""
  local backend_name=""

  DISCOVERED_ROUTE_NAMES=()
  DISCOVERED_ROUTE_NAMESPACES=()
  DISCOVERED_ROUTE_PATHS=()
  DISCOVERED_ROUTE_BACKEND_NAMESPACES=()
  DISCOVERED_ROUTE_BACKEND_NAMES=()

  # Read the first parentRef, hostname, path, and backendRef from every HTTPRoute.
  while IFS=$'\t' read -r \
    route_namespace \
    route_name \
    parent_namespace \
    parent_name \
    route_hostname \
    route_path \
    backend_namespace \
    backend_name; do
    # Skip the trailing empty row returned when no fields are present.
    if [[ -z "${route_namespace}" ]]; then
      continue
    fi

    # Keep only routes attached to the shared Gateway under verification.
    if [[ "${parent_namespace}" != "${GATEWAY_NAMESPACE}" || "${parent_name}" != "${GATEWAY_NAME}" ]]; then
      continue
    fi

    # Ignore routes that are bound to a different explicit hostname.
    if [[ -n "${route_hostname}" && "${route_hostname}" != "${PUBLIC_HOSTNAME}" ]]; then
      continue
    fi

    # Default backend namespace to the route namespace when omitted by the route.
    if [[ -z "${backend_namespace}" ]]; then
      backend_namespace="${route_namespace}"
    fi

    # Store the matching route details for later verification requests.
    DISCOVERED_ROUTE_NAMES+=("${route_name}")
    DISCOVERED_ROUTE_NAMESPACES+=("${route_namespace}")
    DISCOVERED_ROUTE_PATHS+=("${route_path}")
    DISCOVERED_ROUTE_BACKEND_NAMESPACES+=("${backend_namespace}")
    DISCOVERED_ROUTE_BACKEND_NAMES+=("${backend_name}")
  done < <(
    # Query all HTTPRoutes once and emit tab-delimited fields for the read loop above.
    k get httproute -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.parentRefs[0].namespace}{"\t"}{.spec.parentRefs[0].name}{"\t"}{.spec.hostnames[0]}{"\t"}{.spec.rules[0].matches[0].path.value}{"\t"}{.spec.rules[0].backendRefs[0].namespace}{"\t"}{.spec.rules[0].backendRefs[0].name}{"\n"}{end}'
  )

  # Fail fast when the target Gateway has no matching routes for this hostname.
  if [[ "${#DISCOVERED_ROUTE_NAMES[@]}" -eq 0 ]]; then
    echo "No HTTPRoutes are attached to gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME} for hostname ${PUBLIC_HOSTNAME}." >&2
    exit 1
  fi
}

# Allow redirects for routes that canonicalize under ArgoCD.
get_expected_status_pattern() {
  local backend_name="$1"
  local route_path="$2"

  if [[ "${backend_name}" == "argocd-server" || "${route_path}" == /argocd* ]]; then
    echo '^(2|3)'
    return 0
  fi

  echo '^2'
}

#############################################
# validate_required_route_paths
#
# This function verifies that the shared Gateway has the minimum route set
# expected by this repository for the active hostname under test.
#
# Inputs:
# - DISCOVERED_ROUTE_PATHS: populated by discover_gateway_routes
#
# Outputs:
# - no stdout output on success
#
# Important edge cases:
# - exits with a clear error if any required path is missing
#############################################
validate_required_route_paths() {
  local required_route_path=""
  local discovered_route_path=""
  local is_required_path_found="false"
  local required_route_paths=(
    "/"
    "/argocd"
    "/whoami"
  )

  for required_route_path in "${required_route_paths[@]}"; do
    is_required_path_found="false"

    for discovered_route_path in "${DISCOVERED_ROUTE_PATHS[@]}"; do
      if [[ "${discovered_route_path}" == "${required_route_path}" ]]; then
        is_required_path_found="true"
        break
      fi
    done

    if [[ "${is_required_path_found}" != "true" ]]; then
      echo "Required HTTPRoute path ${required_route_path} was not discovered for hostname ${PUBLIC_HOSTNAME}." >&2
      exit 1
    fi
  done
}


# Verify required CLIs before reading Terraform outputs or port-forwarding.
require_command terraform
require_command kubectl
require_command curl

# Read cluster and gateway settings used by the local verification flow.
KUBECONFIG_PATH="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kubeconfig_path)"
KUBE_CONTEXT="$(terraform -chdir="${CLUSTER_TERRAFORM_DIR}" output -raw kube_context)"
GATEWAY_NAMESPACE="$(terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output -raw gateway_namespace)"
GATEWAY_NAME="$(terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output -raw gateway_name)"
GATEWAY_SERVICE_NAME="$(terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output -raw gateway_service_name)"
GATEWAY_SERVICE_PORT="$(terraform -chdir="${PLATFORM_TERRAFORM_DIR}" output -raw gateway_service_port)"
PUBLIC_HOSTNAME="$(get_gateway_hostname)"

# Ensure the temporary port-forward is cleaned up on exit.
trap cleanup_port_forward EXIT

# Wait for Gateway programming before route discovery and traffic checks.
k -n "${GATEWAY_NAMESPACE}" wait gateway/"${GATEWAY_NAME}" --for=condition=Programmed=True --timeout=300s >/dev/null
# Discover routes dynamically so verification follows live Gateway attachments.
discover_gateway_routes
# Enforce expected route paths for root landing, ArgoCD, and whoami.
validate_required_route_paths

# Forward the controller service locally so routed requests stay inside the cluster path.
k -n "${GATEWAY_NAMESPACE}" port-forward "svc/${GATEWAY_SERVICE_NAME}" \
  "${LOCAL_FORWARD_PORT}:${GATEWAY_SERVICE_PORT}" >"${PORT_FORWARD_LOG_PATH}" 2>&1 &
PORT_FORWARD_PROCESS_ID=$!

# Give the local port-forward time to accept connections before probing routes.
sleep 3

# Print the local verification target before route checks run.
echo "Local forwarded hostname: ${PUBLIC_HOSTNAME}"
echo "Local forwarded port: ${LOCAL_FORWARD_PORT}"

# Check each discovered route through the forwarded Gateway listener.
for route_index in "${!DISCOVERED_ROUTE_NAMES[@]}"; do
  route_name="${DISCOVERED_ROUTE_NAMES[${route_index}]}"
  route_namespace="${DISCOVERED_ROUTE_NAMESPACES[${route_index}]}"
  route_path="${DISCOVERED_ROUTE_PATHS[${route_index}]}"
  backend_namespace="${DISCOVERED_ROUTE_BACKEND_NAMESPACES[${route_index}]}"
  backend_name="${DISCOVERED_ROUTE_BACKEND_NAMES[${route_index}]}"
  expected_status_pattern="$(get_expected_status_pattern "${backend_name}" "${route_path}")"

  # Preserve the configured hostname so Gateway host matching still applies locally.
  route_status_code="$(
    curl -sk -o /dev/null -w '%{http_code}' \
      --resolve "${PUBLIC_HOSTNAME}:${LOCAL_FORWARD_PORT}:127.0.0.1" \
      "https://${PUBLIC_HOSTNAME}:${LOCAL_FORWARD_PORT}${route_path}"
  )"

  # Print the backend mapping and observed status for each discovered route.
  echo "route ${route_namespace}/${route_name} -> ${backend_namespace}/${backend_name} ${route_path} status: ${route_status_code}"

  # Fail when a routed response does not match the backend-specific success class.
  if [[ ! "${route_status_code}" =~ ${expected_status_pattern} ]]; then
    echo "Expected route ${route_namespace}/${route_name} (${route_path}) to return a success status through local port-forward." >&2
    exit 1
  fi
done

echo "Local Gateway verification finished."
