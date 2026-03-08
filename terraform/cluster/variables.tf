variable "cluster_name" {
  description = "Name of the local k3d cluster."
  type        = string
  default     = "platform-local"
}

variable "server_count" {
  description = "Number of k3s server nodes in the k3d cluster."
  type        = number
  default     = 1
}

variable "agent_count" {
  description = "Number of k3s agent nodes in the k3d cluster."
  type        = number
  default     = 2
}

variable "ingress_http_host_port" {
  description = "Host port mapped to the cluster load balancer HTTP port 80."
  type        = number
  default     = 8080
}

variable "ingress_https_host_port" {
  description = "Host port mapped to the cluster load balancer HTTPS port 443."
  type        = number
  default     = 8443
}

variable "kubeconfig_path" {
  description = "Path where Terraform writes the kubeconfig for this k3d cluster."
  type        = string
  default     = "../../.kube/k3d-platform-local.yaml"
}

variable "is_tool_validation_enabled" {
  description = "When true, validates required local commands inside the cluster local-exec provisioner."
  type        = bool
  default     = true
}
