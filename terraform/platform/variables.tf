variable "kubeconfig_path" {
  description = "Path to kubeconfig used by Terraform providers."
  type        = string
  default     = "../../.kube/k3d-platform-local.yaml"
}

variable "kube_context" {
  description = "Kubernetes context name inside the kubeconfig file."
  type        = string
  default     = "k3d-platform-local"
}

variable "gateway_api_controller" {
  description = "Gateway API controller to deploy."
  type        = string
  default     = "traefik"

  validation {
    condition     = contains(["traefik"], var.gateway_api_controller)
    error_message = "Supported controllers: traefik."
  }
}

variable "public_hostname" {
  description = "Single public hostname used for ngrok and Gateway host-based routing."
  type        = string
  default     = "replace-with-your-static-domain.ngrok.app"
}

variable "ngrok_api_key" {
  description = "ngrok API key used by the ngrok Kubernetes Operator."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ngrok_authtoken" {
  description = "ngrok authtoken used by the ngrok Kubernetes Operator."
  type        = string
  sensitive   = true
  default     = ""
}

variable "traefik_chart_version" {
  description = "Pinned Traefik Helm chart version."
  type        = string
  default     = "39.0.4"
}

variable "argocd_chart_version" {
  description = "Pinned Argo CD Helm chart version."
  type        = string
  default     = "9.4.7"
}

variable "cert_manager_chart_version" {
  description = "Pinned cert-manager Helm chart version."
  type        = string
  default     = "v1.19.4"
}

variable "ngrok_operator_chart_version" {
  description = "Pinned ngrok operator Helm chart version."
  type        = string
  default     = "0.22.0"
}

variable "gateway_api_release_version" {
  description = "Pinned Gateway API release represented by Traefik chart CRDs."
  type        = string
  default     = "v1.5.0"
}

variable "git_repository_url" {
  description = "Reachable Git repository URL used by ArgoCD for landing manifests and whoami Helm values."
  type        = string
  default     = ""

  validation {
    condition     = length(trimspace(var.git_repository_url)) > 0
    error_message = "git_repository_url must be a non-empty Git repository URL."
  }
}

variable "git_target_revision" {
  description = "Git revision ArgoCD tracks for landing manifests and whoami Helm values."
  type        = string
  default     = "main"
}
