#
# Declares an Argo CD Application for the whoami app. In this architecture,
# Argo CD renders a third-party whoami Helm chart while reading the pinned
# values file for that chart from this repository.
#
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: whoami
  namespace: argocd
spec:
  # Uses Argo CD's default project and its policy boundaries.
  project: default
  sources:
  - # Third-party Helm chart source rendered by Argo CD.
    repoURL: https://cowboysysop.github.io/charts/
    chart: whoami
    # Pinned chart version so application updates are explicit and reviewable.
    targetRevision: 6.0.0
    helm:
      # Keep the rendered Kubernetes resource names stable for routes/scripts.
      releaseName: whoami
      valueFiles:
      - $values/manifests/apps/whoami/values.yaml
  - # Repository source that exposes the whoami values file to the Helm source.
    repoURL: ${git_repository_url}
    # Git branch, tag, or commit Argo CD should track for values changes.
    targetRevision: ${git_target_revision}
    ref: values
  destination:
    # Deploys into the in-cluster Kubernetes API server.
    server: https://kubernetes.default.svc
    # Target namespace for the whoami app resources.
    namespace: whoami
  syncPolicy:
    automated:
      # Removes resources that no longer exist in Git.
      prune: true
      # Reconciles drift if cluster state changes outside Git.
      selfHeal: true
    syncOptions:
    # Creates the target namespace if it does not exist yet.
    - CreateNamespace=true
