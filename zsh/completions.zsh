#compdef kubectl
compdef _kubectl kubectl

# Cache settings
export ZSH_COMPLETION_CACHE_DIR="$HOME/.zsh-completion-cache"
[[ -d $ZSH_COMPLETION_CACHE_DIR ]] || mkdir -p "$ZSH_COMPLETION_CACHE_DIR"

# Function to check if completion file cache is expired
completion_cache_expired() {
  local file="$1"
  local max_age="${2:-604800}"  # Default: 7 days in seconds (configurable)

  if [[ ! -f "$file" ]]; then
    return 0  # Cache expired (file doesn't exist)
  fi

  # Get file modification time
  local file_time=$(stat -f %m "$file")
  local current_time=$(date +%s)
  local file_age=$((current_time - file_time))

  if [[ $file_age -gt $max_age ]]; then
    return 0  # Cache expired
  else
    return 1  # Cache still valid
  fi
}

# -- PHASE 1: Essential completions (foreground) --

# VS Code shell integration (if we're running in VS Code)
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"

# AWS uses its own completer mechanism (critical for AWS workflows)
if [ "$(command -v aws_completer)" ]; then
  complete -C aws_completer aws
fi

# Docker completion - use centralized cache location (most commonly used)
if [ "$(command -v docker)" ]; then
  local docker_completion_file="$ZSH_COMPLETION_CACHE_DIR/_docker"
  if [[ -f "$docker_completion_file" ]]; then
    source "$docker_completion_file"
    compdef _docker docker
  fi
  
  # Update check and download in the background
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if completion_cache_expired "$docker_completion_file" 2592000; then  # 30 days for stable tools
      (curl -sLm 10 https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/zsh/_docker > "${docker_completion_file}.tmp" && 
      mv "${docker_completion_file}.tmp" "$docker_completion_file" || 
      rm -f "${docker_completion_file}.tmp") &!
    fi
  fi
fi

# -- PHASE 2: Lazy-loaded completions with znap function --
# Each completion is loaded only when the command is called or completion is attempted

# OpenShift Install - uses cached file to avoid generating completion on every shell start
if [ "$(command -v openshift-install)" ]; then
  znap function _openshift_install openshift-install "cat /Users/tiger/git/dotfiles/openshift-install-completion-zsh.txt"
  compdef _openshift_install openshift-install
fi

# GitHub CLI completion
if [ "$(command -v gh)" ]; then
  znap function _gh_completion gh 'eval "$(gh completion -s zsh)"'
  compdef _gh_completion gh
fi

# OpenShift Client
if [ "$(command -v oc)" ]; then
  znap function _oc_completion oc 'eval "$(oc completion zsh)"'
  compdef _oc_completion oc
fi

# Podman completion - use centralized cache location
if [ -n "$(command -v podman)" ]; then
  local podman_completion_file="$ZSH_COMPLETION_CACHE_DIR/_podman"
  
  if [[ -f "$podman_completion_file" ]]; then
    source "$podman_completion_file"
    compdef _podman podman
  fi
  
  # Update check and download in the background
  if [[ "$TERM_PROGRAM" != "vscode" ]]; then
    if completion_cache_expired "$podman_completion_file" 2592000; then  # 30 days for stable tools
      (curl -sLm 10 https://raw.githubusercontent.com/containers/podman/main/completions/zsh/_podman > "${podman_completion_file}.tmp" && 
      mv "${podman_completion_file}.tmp" "$podman_completion_file" || 
      rm -f "${podman_completion_file}.tmp") &!
    fi
  fi
fi

# Rosa CLI
if [ "$(command -v rosa)" ]; then
  znap function _rosa_completion rosa 'eval "$(rosa completion zsh)"'
  compdef _rosa_completion rosa
fi

# CCOCTL
if [ "$(command -v ccoctl)" ]; then
  znap function _ccoctl_completion ccoctl 'eval "$(ccoctl completion zsh)"'
  compdef _ccoctl_completion ccoctl
fi

# Velero
if [ "$(command -v velero)" ]; then
  znap function _velero_completion velero 'eval "$(velero completion zsh)"'
  compdef _velero_completion velero
fi

# YQ
if [ "$(command -v yq)" ]; then
  znap function _yq_completion yq 'eval "$(yq completion zsh)"'
  compdef _yq_completion yq
fi

# Kind
if [ "$(command -v kind)" ]; then
  znap function _kind_completion kind 'eval "$(kind completion zsh)"'
  compdef _kind_completion kind
fi

# Google Cloud SDK configuration - loaded on demand
if [ -f '/Users/tiger/google-cloud-sdk/path.zsh.inc' ]; then 
  source '/Users/tiger/google-cloud-sdk/path.zsh.inc'
fi
if [ -f '/Users/tiger/google-cloud-sdk/completion.zsh.inc' ]; then 
  znap function _gcloud_completion gcloud 'source /Users/tiger/google-cloud-sdk/completion.zsh.inc'
  compdef _gcloud_completion gcloud
fi

# Pipenv - Load only when needed
if [ "$(command -v pipenv)" ]; then
  znap function _pipenv_completion pipenv 'eval "$(_PIPENV_COMPLETE=zsh_source pipenv)"'
  compdef _pipenv_completion pipenv
fi

# IBM Cloud completion - if needed
if [[ -f /usr/local/ibmcloud/autocomplete/zsh_autocomplete ]]; then
  znap function _ibmcloud_completion ibmcloud 'source /usr/local/ibmcloud/autocomplete/zsh_autocomplete'
  compdef _ibmcloud_completion ibmcloud
fi

# Help command to view cache status
zsh_completion_cache_status() {
  echo "ZSH completion cache directory: $ZSH_COMPLETION_CACHE_DIR"
  echo "Cache files:"
  for file in $ZSH_COMPLETION_CACHE_DIR/_*; do
    if [[ -f "$file" ]]; then
      local modified=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file")
      local size=$(du -h "$file" | cut -f1)
      local name=$(basename "$file")
      echo "  $name ($size) - Last updated: $modified"
    fi
  done
}

# Command to clear the completion cache
zsh_completion_cache_clear() {
  echo "Clearing ZSH completion cache..."
  rm -f $ZSH_COMPLETION_CACHE_DIR/_*
  echo "Cache cleared. Restart your shell to regenerate completions."
}
