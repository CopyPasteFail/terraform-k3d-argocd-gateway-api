output "cluster_name" {
  description = "Name of the provisioned k3d cluster."
  value       = var.cluster_name
}

output "kube_context" {
  description = "kubectl context name for the provisioned cluster."
  value       = local.kube_context
}

output "kubeconfig_path" {
  description = "Absolute path to the generated kubeconfig file."
  value       = abspath(var.kubeconfig_path)
}

output "ingress_http_url" {
  description = "Local HTTP entrypoint exposed by the k3d load balancer."
  value       = "http://localhost:${var.ingress_http_host_port}"
}

output "ingress_https_url" {
  description = "Local HTTPS entrypoint exposed by the k3d load balancer."
  value       = "https://localhost:${var.ingress_https_host_port}"
}
