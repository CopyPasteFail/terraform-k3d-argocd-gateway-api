#
# Declares an Argo CD Application for the landing app. In this architecture,
# Argo CD watches the Git path for the landing manifests and keeps the
# landing namespace in the cluster synced to that desired state.
#
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: landing
  namespace: argocd
spec:
  # Uses Argo CD's default project and its policy boundaries.
  project: default
  source:
    # Git repository that Argo CD reads manifests from.
    repoURL: ${git_repository_url}
    # Git branch, tag, or commit Argo CD should track.
    targetRevision: ${git_target_revision}
    # Repository path that contains the landing app manifests.
    path: manifests/apps/landing
  destination:
    # Deploys into the in-cluster Kubernetes API server.
    server: https://kubernetes.default.svc
    # Target namespace for the landing app resources.
    namespace: landing
  syncPolicy:
    automated:
      # Removes resources that no longer exist in Git.
      prune: true
      # Reconciles drift if cluster state changes outside Git.
      selfHeal: true
    syncOptions:
    # Creates the target namespace if it does not exist yet.
    - CreateNamespace=true
