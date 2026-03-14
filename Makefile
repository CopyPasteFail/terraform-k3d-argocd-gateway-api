.DEFAULT_GOAL := help

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
export PS1 := make

STAGE ?= both
SUPPORTED_STAGES := cluster platform both

# Tools that can be installed directly from Debian-family apt repositories.
# Each entry is "command_name|apt_package[,fallback_apt_package...]".
APT_TOOL_SPECS := bash|bash;base64|coreutils;curl|curl;docker|docker.io;rg|ripgrep;tail|coreutils

# Tools that need a dedicated installer flow because the default distro
# package is not the preferred source for this repository.
SPECIAL_TOOL_NAMES := git k3d kubectl terraform

GIT_PPA_NAME := ppa:git-core/ppa
GIT_PPA_POLICY_LITERAL := ppa.launchpadcontent.net/git-core/ppa
HASHICORP_POLICY_LITERAL := apt.releases.hashicorp.com
HASHICORP_KEYRING_PATH := /usr/share/keyrings/hashicorp-archive-keyring.gpg
HASHICORP_APT_LIST_PATH := /etc/apt/sources.list.d/hashicorp.list
KUBECTL_INSTALL_PATH := /usr/local/bin/kubectl

# TOOL_AUDIT_SCRIPT inspects the current host, validates Debian-family Linux,
# and records missing tools by install strategy. It treats a tool as installed
# when its command already exists on PATH, regardless of how it was installed.
define TOOL_AUDIT_SCRIPT
ensure_supported_operating_system() { \
  if [[ ! -r /etc/os-release ]]; then \
    echo "Unable to detect the operating system. Missing /etc/os-release." >&2; \
    exit 1; \
  fi; \
  . /etc/os-release; \
  if [[ "$${ID:-}" != "debian" && " $${ID_LIKE:-} " != *" debian "* ]]; then \
    echo "Unsupported operating system: '$${ID:-unknown}'." >&2; \
    echo "This repository is supported only on Debian-family Linux distributions." >&2; \
    exit 1; \
  fi; \
}; \
append_unique_item() { \
  local item_to_add="$${1}"; \
  local existing_item=""; \
  for existing_item in "$${@:2}"; do \
    if [[ "$$existing_item" == "$$item_to_add" ]]; then \
      return 0; \
    fi; \
  done; \
  return 1; \
}; \
resolve_apt_package_name() { \
  local package_candidates_csv="$${1}"; \
  local resolved_package_name=""; \
  local package_candidate=""; \
  IFS=',' read -r -a package_candidate_list <<< "$$package_candidates_csv"; \
  for package_candidate in "$${package_candidate_list[@]}"; do \
    if apt-cache show "$$package_candidate" >/dev/null 2>&1; then \
      resolved_package_name="$$package_candidate"; \
      break; \
    fi; \
  done; \
  if [[ -z "$$resolved_package_name" ]]; then \
    resolved_package_name="$${package_candidate_list[0]}"; \
  fi; \
  printf '%s\n' "$$resolved_package_name"; \
}; \
check_docker_access() { \
  local docker_status_output=""; \
  docker_status_output="$$(docker info >/dev/null 2>&1 || docker info 2>&1 || true)"; \
  if [[ -z "$$docker_status_output" ]]; then \
    return 0; \
  fi; \
  if [[ "$$docker_status_output" == *"permission denied"* ]] || [[ "$$docker_status_output" == *"Got permission denied"* ]]; then \
    status_messages+=("docker is installed, but the current user cannot access the Docker daemon. Add the user to the docker group or use a session with Docker access."); \
    return 0; \
  fi; \
  status_messages+=("docker is installed but the Docker daemon is not reachable. Start Docker and retry."); \
}; \
audit_apt_tools() { \
  local tool_spec=""; \
  local tool_name=""; \
  local package_candidates_csv=""; \
  local resolved_package_name=""; \
  IFS=';' read -r -a tool_spec_list <<< '$(APT_TOOL_SPECS)'; \
  for tool_spec in "$${tool_spec_list[@]}"; do \
    IFS='|' read -r tool_name package_candidates_csv <<< "$$tool_spec"; \
    if command -v "$$tool_name" >/dev/null 2>&1; then \
      if [[ "$$tool_name" == "docker" ]]; then \
        check_docker_access; \
      fi; \
      continue; \
    fi; \
    missing_tools+=("$$tool_name"); \
    resolved_package_name="$$(resolve_apt_package_name "$$package_candidates_csv")"; \
    if ! append_unique_item "$$resolved_package_name" "$${missing_apt_packages[@]}"; then \
      missing_apt_packages+=("$$resolved_package_name"); \
    fi; \
  done; \
}; \
audit_special_tools() { \
  local special_tool_name=""; \
  for special_tool_name in $(SPECIAL_TOOL_NAMES); do \
    if command -v "$$special_tool_name" >/dev/null 2>&1; then \
      continue; \
    fi; \
    missing_tools+=("$$special_tool_name"); \
    missing_special_tools+=("$$special_tool_name"); \
  done; \
}; \
ensure_supported_operating_system; \
missing_tools=(); \
missing_apt_packages=(); \
missing_special_tools=(); \
status_messages=(); \
audit_apt_tools; \
audit_special_tools
endef

# INSTALL_HELPERS_SCRIPT keeps install logic in named shell functions so the
# install-tools target reads as orchestration instead of one large inline blob.
# It installs apt prerequisites first, then runs per-tool installers for tools
# that need upstream binaries or additional repositories.
define INSTALL_HELPERS_SCRIPT
require_root_user() { \
  if [[ "$${EUID}" -ne 0 ]]; then \
    echo "install-tools requires root privileges." >&2; \
    echo "Run: sudo make install-tools" >&2; \
    exit 1; \
  fi; \
}; \
run_apt_update() { \
  echo "Refreshing apt package metadata..."; \
  apt-get update; \
}; \
run_apt_update_for_tool() { \
  local tool_name="$${1}"; \
  echo "Refreshing apt package metadata for $$tool_name..."; \
  if ! apt-get update; then \
    echo "Failed to refresh apt metadata while preparing $$tool_name installation." >&2; \
    echo "Resolve apt issues on this host and install $$tool_name manually, then rerun the command." >&2; \
    exit 1; \
  fi; \
}; \
install_apt_packages() { \
  if [[ "$${#}" -eq 0 ]]; then \
    return 0; \
  fi; \
  echo "Installing apt packages: $$*"; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$$@"; \
}; \
find_apt_source_with_literal() { \
  local required_literal="$${1}"; \
  local apt_source_path=""; \
  local apt_source_paths=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources); \
  for apt_source_path in "$${apt_source_paths[@]}"; do \
    if [[ ! -e "$$apt_source_path" ]]; then \
      continue; \
    fi; \
    if grep -F -q -- "$$required_literal" "$$apt_source_path"; then \
      return 0; \
    fi; \
  done; \
  return 1; \
}; \
apt_policy_contains_literal_for_package() { \
  local package_name="$${1}"; \
  local required_literal="$${2}"; \
  apt-cache policy "$$package_name" 2>/dev/null | grep -F -q -- "$$required_literal"; \
}; \
ensure_git_ppa_repository() { \
  if apt_policy_contains_literal_for_package git "$(GIT_PPA_POLICY_LITERAL)"; then \
    echo "Git Core PPA already active for git; skipping repository add."; \
    return 1; \
  fi; \
  if find_apt_source_with_literal "$(GIT_PPA_POLICY_LITERAL)"; then \
    echo "Git Core PPA already configured in apt sources; skipping repository add."; \
    return 1; \
  fi; \
  echo "Adding Git Core PPA for latest git packages..."; \
  if ! add-apt-repository -y "$(GIT_PPA_NAME)"; then \
    echo "Failed to configure the Git Core PPA for git." >&2; \
    echo "Install git manually on this host, then rerun the command." >&2; \
    exit 1; \
  fi; \
}; \
ensure_hashicorp_apt_repository() { \
  local distribution_codename="$${1}"; \
  local expected_hashicorp_repo_line=""; \
  local hashicorp_repo_literal=""; \
  if apt_policy_contains_literal_for_package terraform "$(HASHICORP_POLICY_LITERAL)"; then \
    echo "HashiCorp apt repository already active for terraform; skipping repository add."; \
    return 1; \
  fi; \
  expected_hashicorp_repo_line="deb [arch=$$(dpkg --print-architecture) signed-by=$(HASHICORP_KEYRING_PATH)] https://apt.releases.hashicorp.com $$distribution_codename main"; \
  hashicorp_repo_literal="https://apt.releases.hashicorp.com $$distribution_codename main"; \
  if find_apt_source_with_literal "$$hashicorp_repo_literal"; then \
    echo "HashiCorp apt repository already configured in apt sources; skipping repository add."; \
    return 1; \
  fi; \
  echo "Configuring the HashiCorp apt repository for terraform..."; \
  printf '%s\n' "$$expected_hashicorp_repo_line" > "$(HASHICORP_APT_LIST_PATH)"; \
}; \
verify_git_ppa_is_active() { \
  if apt_policy_contains_literal_for_package git "$(GIT_PPA_POLICY_LITERAL)"; then \
    return 0; \
  fi; \
  echo "Failed to activate the preferred git repository on this host." >&2; \
  echo "Install git manually on this host, then rerun the command." >&2; \
  exit 1; \
}; \
verify_hashicorp_repo_is_active_for_terraform() { \
  if apt_policy_contains_literal_for_package terraform "$(HASHICORP_POLICY_LITERAL)"; then \
    return 0; \
  fi; \
  echo "Failed to activate the HashiCorp repository for terraform on this host." >&2; \
  echo "Install terraform manually on this host, then rerun the command." >&2; \
  exit 1; \
}; \
install_git() { \
  . /etc/os-release; \
  if [[ "$${ID:-}" == "ubuntu" || " $${ID_LIKE:-} " == *" ubuntu "* ]]; then \
    install_apt_packages software-properties-common; \
    ensure_git_ppa_repository || true; \
    run_apt_update_for_tool git; \
    verify_git_ppa_is_active; \
    install_apt_packages git; \
    return 0; \
  fi; \
  echo "Installing git from the default apt repository on non-Ubuntu Debian-family hosts."; \
  install_apt_packages git; \
}; \
install_k3d() { \
  echo "Installing k3d with the upstream installer..."; \
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash; \
}; \
install_kubectl() { \
  local kubectl_version=""; \
  local kubectl_arch=""; \
  local kubectl_download_url=""; \
  local kubectl_checksum_url=""; \
  kubectl_version="$$(curl -L -s https://dl.k8s.io/release/stable.txt)"; \
  kubectl_arch="$$(dpkg --print-architecture)"; \
  kubectl_download_url="https://dl.k8s.io/release/$$kubectl_version/bin/linux/$$kubectl_arch/kubectl"; \
  kubectl_checksum_url="https://dl.k8s.io/release/$$kubectl_version/bin/linux/$$kubectl_arch/kubectl.sha256"; \
  echo "Installing kubectl $$kubectl_version for architecture $$kubectl_arch from upstream..."; \
  curl -fsSLo kubectl "$$kubectl_download_url"; \
  curl -fsSLo kubectl.sha256 "$$kubectl_checksum_url"; \
  echo "$$(cat kubectl.sha256)  kubectl" | sha256sum --check; \
  install -o root -g root -m 0755 kubectl "$(KUBECTL_INSTALL_PATH)"; \
  rm -f kubectl kubectl.sha256; \
  kubectl version --client; \
}; \
install_terraform() { \
  local distribution_codename=""; \
  install_apt_packages ca-certificates gnupg lsb-release wget; \
  wget -qO- https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes -o "$(HASHICORP_KEYRING_PATH)"; \
  distribution_codename="$$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || true)"; \
  if [[ -z "$$distribution_codename" ]]; then \
    distribution_codename="$$(lsb_release -cs)"; \
  fi; \
  ensure_hashicorp_apt_repository "$$distribution_codename" || true; \
  run_apt_update_for_tool terraform; \
  verify_hashicorp_repo_is_active_for_terraform; \
  install_apt_packages terraform; \
}; \
install_special_tools() { \
  local special_tool_name=""; \
  for special_tool_name in "$${missing_special_tools[@]}"; do \
    case "$$special_tool_name" in \
      git) install_git ;; \
      k3d) install_k3d ;; \
      kubectl) install_kubectl ;; \
      terraform) install_terraform ;; \
      *) echo "Unsupported special install target: $$special_tool_name" >&2; exit 1 ;; \
    esac; \
  done; \
}
endef

.PHONY: help check-tools install-tools up verify verify-local password destroy print-derived-git-source _validate_stage

help:
	@echo "Supported targets:"
	@echo "  make check-tools"
	@echo "  sudo make install-tools"
	@echo "  make up STAGE=cluster|platform|both"
	@echo "  make verify"
	@echo "  make verify-local"
	@echo "  make password"
	@echo "  make destroy"
	@echo "  make print-derived-git-source"

_validate_stage:
	@if [[ " $(SUPPORTED_STAGES) " != *" $(STAGE) "* ]]; then \
	  echo "Unsupported STAGE '$(STAGE)'." >&2; \
	  echo "Expected one of: $(SUPPORTED_STAGES)." >&2; \
	  exit 1; \
	fi

# Verify that every required command is available before running repository
# workflows. For docker, also validate that the current user can reach the
# daemon, because the CLI alone is not sufficient.
check-tools:
	@$(TOOL_AUDIT_SCRIPT); \
	if [[ "$${#missing_tools[@]}" -eq 0 && "$${#status_messages[@]}" -eq 0 ]]; then \
	  echo "All required tools are installed and ready."; \
	  exit 0; \
	fi; \
	if [[ "$${#missing_tools[@]}" -gt 0 ]]; then \
	  echo "Missing required tools:" >&2; \
	  for missing_tool in "$${missing_tools[@]}"; do \
	    echo "  - $$missing_tool" >&2; \
	  done; \
	fi; \
	if [[ "$${#status_messages[@]}" -gt 0 ]]; then \
	  echo "Additional prerequisite issues:" >&2; \
	  for status_message in "$${status_messages[@]}"; do \
	    echo "  - $$status_message" >&2; \
	  done; \
	fi; \
	if [[ "$${#missing_tools[@]}" -gt 0 ]]; then \
	  echo "Install the missing tools with: sudo make install-tools" >&2; \
	fi; \
	exit 1

# Install only the missing tools needed by this repository.
# Simpler utilities use apt directly, while git, k3d, kubectl, and terraform
# follow dedicated install strategies that prefer upstream or repo-backed
# sources over the default distro package.
install-tools:
	@$(TOOL_AUDIT_SCRIPT); \
	$(INSTALL_HELPERS_SCRIPT); \
	if [[ "$${#missing_tools[@]}" -eq 0 ]]; then \
	  echo "No missing tools to install."; \
	  if [[ "$${#status_messages[@]}" -gt 0 ]]; then \
	    echo "Additional prerequisite issues:" >&2; \
	    for status_message in "$${status_messages[@]}"; do \
	      echo "  - $$status_message" >&2; \
	    done; \
	    exit 1; \
	  fi; \
	  exit 0; \
	fi; \
	require_root_user; \
	echo "Installing missing tools: $${missing_tools[*]}"; \
	run_apt_update; \
	install_apt_packages "$${missing_apt_packages[@]}"; \
	install_special_tools; \
	echo "Finished installing missing tools."

up: check-tools _validate_stage
	@./scripts/up.sh --stage "$(STAGE)"

verify: check-tools
	@./scripts/verify.sh

verify-local: check-tools
	@./scripts/verify-local.sh

password: check-tools
	@./scripts/get-argocd-password.sh

destroy: check-tools
	@./scripts/destroy.sh

print-derived-git-source: check-tools
	@./scripts/up.sh --print-derived-git-source
