output "kube_context" {
  description = "Kubernetes context name used for the platform stage."
  value       = var.kube_context
}

output "kubeconfig_path" {
  description = "Kubeconfig path used for the platform stage."
  value       = abspath(var.kubeconfig_path)
}

output "gateway_hostname" {
  description = "Hostname served by Gateway and exposed by ngrok."
  value       = var.public_hostname
}

output "public_base_url" {
  description = "Public HTTPS base URL exposed by ngrok."
  value       = "https://${var.public_hostname}"
}

output "landing_url" {
  description = "Landing page URL served through Gateway API."
  value       = "https://${var.public_hostname}/"
}

output "argocd_url" {
  description = "ArgoCD path URL served through Gateway API."
  value       = "https://${var.public_hostname}/argocd"
}

output "whoami_url" {
  description = "whoami path URL served through Gateway API."
  value       = "https://${var.public_hostname}/whoami"
}

output "gateway_api_release_version" {
  description = "Gateway API release version tracked by the deployed CRDs."
  value       = var.gateway_api_release_version
}

output "ngrok_public_ingress_namespace" {
  description = "Namespace containing the ngrok-managed public Ingress."
  value       = "gateway-system"
}

output "ngrok_public_ingress_name" {
  description = "Name of the Ingress resource used by ngrok for public exposure."
  value       = "platform-public-ingress"
}

output "gateway_controller" {
  description = "Gateway API controller deployed by Terraform."
  value       = var.gateway_api_controller
}

# These outputs give local verification scripts a Terraform-backed source of truth
# for the shared Gateway identity and the controller Service listener they port-forward.
# That avoids duplicating gateway names, namespace names, or Service ports in shell
# scripts, so verification keeps working if the platform wiring changes later.
output "gateway_namespace" {
  description = "Namespace that contains the shared Gateway and controller Service."
  value       = "gateway-system"
}

output "gateway_name" {
  description = "Name of the shared Gateway used for route attachment."
  value       = "shared-gateway"
}

output "gateway_service_name" {
  description = "Controller Service name used for local port-forward verification."
  value       = "traefik"
}

output "gateway_service_port" {
  description = "HTTPS Service port used for local port-forward verification."
  value       = 443
}
